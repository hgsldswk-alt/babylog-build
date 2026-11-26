import Foundation

enum MilkUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case ml, oz

    var label: String { L.t(self == .ml ? "unit.ml" : "unit.oz") }
    var defaults: [String] { self == .ml ? ["60", "90", "120"] : ["2", "3", "4"] }

    static func preferred(locale: Locale = .current) -> Self {
        let metricRegions = ["CN", "TW", "HK", "MO"]
        if let region = locale.region?.identifier, metricRegions.contains(region) { return .ml }
        return locale.measurementSystem == .us ? .oz : .ml
    }
}

enum Diaper: String, Codable, CaseIterable, Hashable, Sendable {
    case wet, dirty, both
    var label: String { L.t("diaper.\(rawValue)") }
}

enum Side: String, Codable, CaseIterable, Hashable, Sendable {
    case left, right
    var label: String { L.t("side.\(rawValue)") }
}

enum LogKind: String, Codable, CaseIterable, Hashable, Sendable {
    case bottle, nursing, diaper, mom
    var label: String { L.t("kind.\(rawValue)") }
    var isFeeding: Bool { self == .bottle || self == .nursing }
}

enum LogProblem: Error {
    case amount, code, future, missing, duplicate, locked, range, importFile, write, export, medName
}

enum MomMed {
    static let nameLimit = 30
    static let noteLimit = 20

    static func validated(name: String, note: String) throws -> (String, String?) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= nameLimit, m.count <= noteLimit else { throw LogProblem.medName }
        return (n, m.isEmpty ? nil : m)
    }

    static func recent(_ entries: [LogRecord], limit: Int = 4) -> [String] {
        var seen = Set<String>(), names: [String] = []
        for entry in entries.sorted(by: LogRecord.newest) where entry.kind == .mom {
            guard let name = entry.medName, !seen.contains(name) else { continue }
            seen.insert(name); names.append(name)
            if names.count == limit { break }
        }
        return names
    }
}

enum MilkAmount {
    private static let canonicalLocale = Locale(identifier: "en_US_POSIX")

    static func validated(_ input: String, locale: Locale = .current) throws -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = locale.decimalSeparator, separator != "." {
            text = text.replacingOccurrences(of: separator, with: ".")
        }
        guard text.range(of: #"^[0-9]{1,4}(\.[0-9]{1,3})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: canonicalLocale),
              value > 0, value <= 9_999 else { throw LogProblem.amount }
        return NSDecimalNumber(decimal: value).stringValue
    }

    static func label(_ value: String, locale: Locale = .current) -> String {
        value.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}

struct MilkPresets: Codable, Equatable, Sendable {
    var unit: MilkUnit
    var amounts: [String]

    init(unit: MilkUnit = .preferred(), amounts: [String]? = nil) {
        self.unit = unit
        self.amounts = amounts ?? unit.defaults
    }

    static func checked(unit: MilkUnit, amounts: [String], locale: Locale = .current) throws -> Self {
        guard (3...6).contains(amounts.count) else { throw LogProblem.code }
        let canonical = try amounts.map { try MilkAmount.validated($0, locale: locale) }
        guard Set(canonical).count == canonical.count else { throw LogProblem.duplicate }
        return Self(unit: unit, amounts: canonical)
    }

    var code: String { "BABY1/\(unit.rawValue.uppercased())/\(amounts.joined(separator: "-"))" }

    init(code: String) throws {
        guard code.utf8.count <= 256 else { throw LogProblem.code }
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "BABY1", let unit = MilkUnit(rawValue: parts[1].lowercased()) else {
            throw LogProblem.code
        }
        self = try Self.checked(unit: unit, amounts: parts[2].components(separatedBy: "-"), locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct BabyProfile: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var order = 0
    var presets: MilkPresets

    var displayName: String {
        if !name.isEmpty { return name }
        return order == 0 ? L.t("profile.default") : L.f("profile.indexed", Int64(order + 1))
    }
}

struct LogRecord: Identifiable, Equatable, Sendable {
    var id = UUID()
    var babyID: UUID
    var kind: LogKind
    var date: Date
    var zoneID: String
    var day: String
    var createdAt: Date
    var modifiedAt: Date
    var amount: String?
    var unit: MilkUnit?
    var diaper: Diaper?
    var side: Side?
    var medName: String? = nil
    var medNote: String? = nil

    var zone: TimeZone { TimeZone(identifier: zoneID) ?? TimeZone(secondsFromGMT: 0)! }
    var detail: String {
        if kind == .mom, let medName { return [medName, medNote].compactMap { $0 }.joined(separator: " · ") }
        if let amount, let unit { return "\(MilkAmount.label(amount)) \(unit.label)" }
        return diaper?.label ?? ""
    }
    var summary: String { detail.isEmpty ? kind.label : detail }

    static func newest(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

struct LogDraft: Sendable {
    var kind: LogKind
    var date: Date
    var zone: TimeZone
    var amount = ""
    var unit: MilkUnit = .preferred()
    var diaper = Diaper.wet
    var side: Side?
    var medName = ""
    var medNote = ""

    init(kind: LogKind, date: Date, zone: TimeZone, unit: MilkUnit = .preferred()) {
        self.kind = kind
        self.date = date
        self.zone = zone
        self.unit = unit
    }

    init(record: LogRecord) {
        self.init(kind: record.kind, date: record.date, zone: record.zone, unit: record.unit ?? .preferred())
        amount = record.amount.map { MilkAmount.label($0) } ?? ""
        diaper = record.diaper ?? .wet
        side = record.side
        medName = record.medName ?? ""
        medNote = record.medNote ?? ""
    }

    func record(babyID: UUID, now: Date, previous: LogRecord? = nil) throws -> LogRecord {
        guard date <= now else { throw LogProblem.future }
        let milk: String? = kind == .bottle ? try MilkAmount.validated(amount) : nil
        let med: (String, String?)? = kind == .mom ? try MomMed.validated(name: medName, note: medNote) : nil
        return LogRecord(id: previous?.id ?? UUID(), babyID: babyID, kind: kind, date: date,
                         zoneID: zone.identifier, day: LogTime.day(date, zone: zone),
                         createdAt: previous?.createdAt ?? now, modifiedAt: now,
                         amount: milk, unit: kind == .bottle ? unit : nil,
                         diaper: kind == .diaper ? diaper : nil, side: kind == .nursing ? side : nil,
                         medName: med?.0, medNote: med?.1)
    }
}

enum LogTime {
    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func day(_ date: Date, zone: TimeZone) -> String {
        let parts = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func dayDate(_ key: String, zone: TimeZone) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar(zone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
              day(date, zone: zone) == key else { return nil }
        return date
    }

    static func header(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("MMMMdEEEE")
        return formatter.string(from: date)
    }

    static func wallTimes(_ date: Date, in zone: TimeZone) -> [Date] {
        let parts = calendar(zone).dateComponents([.hour, .minute, .second], from: date)
        return resolveWallTime(on: date, hour: parts.hour ?? 0, minute: parts.minute ?? 0, second: parts.second ?? 0, in: zone)
    }

    static func resolveWallTime(on date: Date, hour: Int, minute: Int, second: Int = 0, in zone: TimeZone) -> [Date] {
        let calendar = calendar(zone)
        let parts = DateComponents(hour: hour, minute: minute, second: second)
        let start = calendar.startOfDay(for: date)
        return [Calendar.RepeatedTimePolicy.first, .last].compactMap { policy in
            calendar.nextDate(after: start.addingTimeInterval(-1), matching: parts,
                              matchingPolicy: .strict, repeatedTimePolicy: policy)
        }.filter { calendar.isDate($0, inSameDayAs: date) }
    }

    static func sameZone(_ a: TimeZone, _ b: TimeZone, at date: Date) -> Bool {
        a.identifier == b.identifier || (a.secondsFromGMT(for: date) == b.secondsFromGMT(for: date)
            && a.abbreviation(for: date) == b.abbreviation(for: date))
    }

    static func stamp(_ record: LogRecord, now: Date, zone: TimeZone, absolute: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = record.zone
        let matchingZone = sameZone(record.zone, zone, at: record.date)
        if !absolute && matchingZone {
            formatter.timeStyle = .short
            let today = day(now, zone: zone)
            let yesterday = calendar(zone).date(byAdding: .day, value: -1, to: now).map { day($0, zone: zone) }
            if record.day == today { return L.f("date.today", formatter.string(from: record.date)) }
            if record.day == yesterday { return L.f("date.yesterday", formatter.string(from: record.date)) }
        }
        return absoluteStamp(record.date, zone: record.zone, withZone: !matchingZone)
    }

    static func absoluteStamp(_ date: Date, zone: TimeZone, withZone: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let text = formatter.string(from: date)
        guard withZone else { return text }
        return "\(text) \(zone.abbreviation(for: date) ?? zone.identifier)"
    }
}

enum Handoff {
    static func recent(_ entries: [LogRecord], now: Date) -> [LogRecord] {
        entries.filter { now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) <= 12 * 3600 }
            .sorted(by: LogRecord.newest)
    }

    static func initial(_ entries: [LogRecord], balance: Bool) -> Set<UUID> {
        let sorted = entries.sorted(by: LogRecord.newest)
        var selection = Set<UUID>()
        if balance {
            if let feeding = sorted.first(where: { $0.kind.isFeeding }) { selection.insert(feeding.id) }
            if let diaper = sorted.first(where: { $0.kind == .diaper }) { selection.insert(diaper.id) }
            if let mom = sorted.first(where: { $0.kind == .mom }) { selection.insert(mom.id) }
        }
        for entry in sorted where selection.count < 4 { selection.insert(entry.id) }
        return selection
    }

    static func text(_ entries: [LogRecord], now: Date, zone: TimeZone) -> String {
        let header = L.f("share.textHeader", LogTime.absoluteStamp(now, zone: zone))
        let rows = entries.map { entry in
            [LogTime.stamp(entry, now: now, zone: zone, absolute: true), entry.kind.label, entry.detail]
                .filter { !$0.isEmpty }.joined(separator: "  ")
        }
        return ([header] + rows).joined(separator: "\n")
    }
}

enum LogCSV {
    static func encode(_ entries: [LogRecord], from start: String, through end: String,
                       label: (String) -> String = L.t) throws -> Data {
        guard start <= end else { throw LogProblem.range }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        let header = ["csv.date", "csv.time", "csv.zone", "csv.kind", "csv.diaper", "csv.amount", "csv.unit",
                      "csv.med", "csv.medNote"].map(label)
        let rows = entries.filter { start <= $0.day && $0.day <= end }.sorted(by: LogRecord.newest).map { entry in
            formatter.timeZone = entry.zone
            return [entry.day, formatter.string(from: entry.date), entry.zoneID, label("kind.\(entry.kind.rawValue)"),
                    entry.diaper.map { label("diaper.\($0.rawValue)") } ?? "", entry.amount ?? "",
                    entry.unit.map { label("unit.\($0.rawValue)") } ?? "", entry.medName ?? "", entry.medNote ?? ""]
        }
        let lines = ([header] + rows).map { row in
            row.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }
        return Data(("\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

