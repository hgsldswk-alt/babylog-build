import Foundation
import SwiftData

enum LogSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [Baby.self, LogEntry.self, Preferences.self] }

    @Model
    final class Baby {
        @Attribute(.unique) var id: UUID
        var name: String
        var order: Int
        var unit: String
        var amounts: [String]

        init(_ profile: BabyProfile) {
            id = profile.id
            name = profile.name
            order = profile.order
            unit = profile.presets.unit.rawValue
            amounts = profile.presets.amounts
        }

        var value: BabyProfile {
            BabyProfile(id: id, name: name, order: order,
                        presets: MilkPresets(unit: MilkUnit(rawValue: unit) ?? .ml, amounts: amounts))
        }
    }

    @Model
    final class LogEntry {
        @Attribute(.unique) var id: UUID
        var babyID: UUID
        var kind: String
        var date: Date
        var zoneID: String
        var day: String
        var createdAt: Date
        var modifiedAt: Date
        var amount: String?
        var unit: String?
        var diaper: String?
        var side: String?

        init(_ record: LogRecord) {
            id = record.id
            babyID = record.babyID
            kind = record.kind.rawValue
            date = record.date
            zoneID = record.zoneID
            day = record.day
            createdAt = record.createdAt
            modifiedAt = record.modifiedAt
            amount = record.kind == .mom ? record.medName : record.amount
            unit = record.unit?.rawValue
            diaper = record.diaper?.rawValue
            side = record.kind == .mom ? record.medNote : record.side?.rawValue
        }

        func update(_ record: LogRecord) {
            kind = record.kind.rawValue
            date = record.date
            zoneID = record.zoneID
            day = record.day
            modifiedAt = record.modifiedAt
            amount = record.kind == .mom ? record.medName : record.amount
            unit = record.unit?.rawValue
            diaper = record.diaper?.rawValue
            side = record.kind == .mom ? record.medNote : record.side?.rawValue
        }

        var value: LogRecord? {
            guard let kind = LogKind(rawValue: kind) else { return nil }
            if kind == .mom {
                return LogRecord(id: id, babyID: babyID, kind: kind, date: date, zoneID: zoneID,
                                 day: day, createdAt: createdAt, modifiedAt: modifiedAt,
                                 medName: amount, medNote: side)
            }
            return LogRecord(id: id, babyID: babyID, kind: kind, date: date, zoneID: zoneID,
                             day: day, createdAt: createdAt, modifiedAt: modifiedAt, amount: amount,
                             unit: unit.flatMap(MilkUnit.init(rawValue:)),
                             diaper: diaper.flatMap(Diaper.init(rawValue:)), side: side.flatMap(Side.init(rawValue:)))
        }
    }

    @Model
    final class Preferences {
        @Attribute(.unique) var key: String
        var selectedID: UUID
        var milestoneSeen = false
        var sevenDaysReached = false
        var handoffShared = false
        var reviewRequested = false

        init(selectedID: UUID) {
            key = "main"
            self.selectedID = selectedID
        }
    }
}

enum LogMigration: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LogSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

struct LogSnapshot: Sendable {
    var babies: [BabyProfile]
    var entriesByBaby: [UUID: [LogRecord]]
    var allDays: Set<String>
    var selectedID: UUID
    var milestoneSeen: Bool
    var sevenDaysReached: Bool
    var handoffShared: Bool
    var reviewRequested: Bool

    var selected: BabyProfile? { babies.first { $0.id == selectedID } }
    var entries: [LogRecord] { entriesByBaby[selectedID] ?? [] }
    var earnedMilestone: Bool { sevenDaysReached || allDays.count >= 7 }

    func shouldAskForReview(at now: Date, zone: TimeZone) -> Bool {
        earnedMilestone && handoffShared && !reviewRequested && (9...20).contains(LogTime.calendar(zone).component(.hour, from: now))
    }
}

enum LogMutation: Sendable {
    case record(LogDraft, babyID: UUID, editing: UUID?, now: Date)
    case delete(id: UUID, babyID: UUID)
    case select(UUID)
    case addBaby(String, allowed: Bool)
    case rename(UUID, String)
    case presets(UUID, MilkPresets)
    case seeMilestone, shareHandoff, requestReview
}

struct LogUpdate: Sendable {
    var snapshot: LogSnapshot
    var inserted: UUID?
}

@ModelActor
actor LogStore {
    private typealias Baby = LogSchemaV1.Baby
    private typealias LogEntry = LogSchemaV1.LogEntry
    private typealias Preferences = LogSchemaV1.Preferences

    static func open(at url: URL? = nil, isolated: Bool = false) async throws -> LogStore {
        try await Task.detached(priority: .userInitiated) {
            let schema = Schema(versionedSchema: LogSchemaV1.self)
            let config: ModelConfiguration
            if isolated && url == nil {
                config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            } else {
                let manager = FileManager.default
                let database: URL
                if let url {
                    database = url
                } else {
                    let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
                    var folder = support.appendingPathComponent("BabyLog", isDirectory: true)
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                    try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: folder.path)
                    var resources = URLResourceValues()
                    resources.isExcludedFromBackup = true
                    try folder.setResourceValues(resources)
                    database = folder.appendingPathComponent("BabyLog.store")
                }
                config = ModelConfiguration(schema: schema, url: database, cloudKitDatabase: .none)
            }
            let container = try ModelContainer(for: schema, migrationPlan: LogMigration.self, configurations: [config])
            return LogStore(modelContainer: container)
        }.value
    }

    func bootstrap(seedDemo: Bool = false, twoBabies: Bool = false, milestone: Bool = false) throws -> LogSnapshot {
        modelContext.autosaveEnabled = false
        do {
            var babies = try modelContext.fetch(FetchDescriptor<Baby>())
            if babies.isEmpty {
                let first = Baby(BabyProfile(name: twoBabies ? "Lin" : "", presets: MilkPresets(unit: seedDemo ? .ml : .preferred())))
                babies.append(first)
                modelContext.insert(first)
                if twoBabies {
                    let second = Baby(BabyProfile(name: "Kai", order: 1, presets: MilkPresets(unit: .ml)))
                    babies.append(second)
                    modelContext.insert(second)
                }
                if seedDemo || milestone {
                    try seed(first.id, includeSevenDays: milestone)
                }
            }

            let preferences: Preferences
            if let existing = try modelContext.fetch(FetchDescriptor<Preferences>()).first {
                preferences = existing
                if !babies.contains(where: { $0.id == preferences.selectedID }) {
                    preferences.selectedID = babies.min(by: { $0.order < $1.order })!.id
                }
            } else {
                preferences = Preferences(selectedID: babies.min(by: { $0.order < $1.order })!.id)
                modelContext.insert(preferences)
            }
            let snapshot = try snapshot(preferences)
            try modelContext.save()
            return snapshot
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func apply(_ mutation: LogMutation) throws -> LogUpdate {
        do {
            guard let preferences = try modelContext.fetch(FetchDescriptor<Preferences>()).first else { throw LogProblem.missing }
            var inserted: UUID?
            var deleted: UUID?
            switch mutation {
            case let .record(draft, babyID, editing, now):
                _ = try baby(babyID)
                if let editing {
                    let stored = try entry(editing, babyID: babyID)
                    guard let previous = stored.value else { throw LogProblem.missing }
                    stored.update(try draft.record(babyID: babyID, now: now, previous: previous))
                } else {
                    let value = try draft.record(babyID: babyID, now: now)
                    modelContext.insert(LogEntry(value))
                    inserted = value.id
                }
            case let .delete(id, babyID):
                modelContext.delete(try entry(id, babyID: babyID))
                deleted = id
            case .select(let id):
                _ = try baby(id)
                preferences.selectedID = id
            case let .addBaby(name, allowed):
                guard allowed else { throw LogProblem.locked }
                let babies = try modelContext.fetch(FetchDescriptor<Baby>())
                let profile = BabyProfile(name: cleanName(name), order: (babies.map(\.order).max() ?? -1) + 1, presets: MilkPresets())
                modelContext.insert(Baby(profile))
                preferences.selectedID = profile.id
            case let .rename(id, name):
                let profile = try baby(id)
                profile.name = cleanName(name)
            case let .presets(id, presets):
                let checked = try MilkPresets.checked(unit: presets.unit, amounts: presets.amounts, locale: Locale(identifier: "en_US_POSIX"))
                let selected = try baby(id)
                selected.unit = checked.unit.rawValue
                selected.amounts = checked.amounts
            case .seeMilestone: preferences.milestoneSeen = true
            case .shareHandoff: preferences.handoffShared = true
            case .requestReview: preferences.reviewRequested = true
            }

            let snapshot = try snapshot(preferences, excluding: deleted)
            try modelContext.save()
            return LogUpdate(snapshot: snapshot, inserted: inserted)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func cleanName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    private func baby(_ id: UUID) throws -> Baby {
        var descriptor = FetchDescriptor<Baby>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let result = try modelContext.fetch(descriptor).first else { throw LogProblem.missing }
        return result
    }

    private func entry(_ id: UUID, babyID: UUID) throws -> LogEntry {
        var descriptor = FetchDescriptor<LogEntry>(predicate: #Predicate { $0.id == id && $0.babyID == babyID })
        descriptor.fetchLimit = 1
        guard let result = try modelContext.fetch(descriptor).first else { throw LogProblem.missing }
        return result
    }

    private func snapshot(_ preferences: Preferences, excluding deleted: UUID? = nil) throws -> LogSnapshot {
        let babies = try modelContext.fetch(FetchDescriptor<Baby>(sortBy: [SortDescriptor(\.order)])).map(\.value)
        let entries = try modelContext.fetch(FetchDescriptor<LogEntry>())
            .filter { $0.id != deleted }.compactMap(\.value).sorted(by: LogRecord.newest)
        let days = Set(entries.map(\.day))
        if days.count >= 7 { preferences.sevenDaysReached = true }
        return LogSnapshot(babies: babies, entriesByBaby: Dictionary(grouping: entries, by: \.babyID), allDays: days,
                           selectedID: preferences.selectedID, milestoneSeen: preferences.milestoneSeen,
                           sevenDaysReached: preferences.sevenDaysReached, handoffShared: preferences.handoffShared,
                           reviewRequested: preferences.reviewRequested)
    }

    private func seed(_ id: UUID, includeSevenDays: Bool) throws {
        let now = Launch.demo ? Launch.now : Date.now
        let zone = Launch.zone
        let data: [(LogKind, TimeInterval, Diaper)] = [
            (.bottle, 43 * 60, .wet), (.diaper, 152 * 60, .wet), (.nursing, 248 * 60, .wet),
            (.diaper, 280 * 60, .both), (.bottle, 340 * 60, .wet)
        ]
        for (kind, offset, diaper) in data {
            var draft = LogDraft(kind: kind, date: now.addingTimeInterval(-offset), zone: zone, unit: .ml)
            draft.amount = "90"
            draft.diaper = diaper
            modelContext.insert(LogEntry(try draft.record(babyID: id, now: now)))
        }
        if includeSevenDays {
            for offset in 1...7 {
                guard let day = LogTime.calendar(zone).date(byAdding: .day, value: -offset, to: now) else { continue }
                let draft = LogDraft(kind: .nursing, date: day, zone: zone)
                modelContext.insert(LogEntry(try draft.record(babyID: id, now: now)))
            }
        }
    }
}

