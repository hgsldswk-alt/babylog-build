import SwiftUI
import UserNotifications

struct DiaperSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                SheetHeader(title: L.t("home.diaper"))
                ForEach(Diaper.allCases, id: \.self) { diaper in
                    Button { save(diaper) } label: { ArrowLabel(text: diaper.label) }
                        .buttonStyle(KeyStyle())
                        .accessibilityIdentifier("diaper.\(diaper.rawValue)")
                        .disabled(model.busy)
                }
                InlineProblem(message: problem)
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.surface)
        .interactiveDismissDisabled(model.busy)
    }

    private func save(_ diaper: Diaper) {
        guard let baby = model.snapshot?.selected else { return }
        let now = Launch.now
        var draft = LogDraft(kind: .diaper, date: now, zone: Launch.zone)
        draft.diaper = diaper
        Task {
            do {
                try await model.perform(.record(draft, babyID: baby.id, editing: nil, now: now),
                                        quickKey: "\(baby.id)-diaper-\(diaper.rawValue)")
                dismiss()
            } catch LogProblem.duplicate {
                return
            } catch {
                self.problem = L.t("error.save")
            }
        }
    }
}

struct EditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var amountFocused: Bool
    @State private var draft: LogDraft
    @State private var problem: String?
    @State private var confirmingDelete = false
    @State private var quickDate: Date?

    let panel: LogSheet
    let baby: BabyProfile

    init(panel: LogSheet, baby: BabyProfile) {
        self.panel = panel
        self.baby = baby
        let initial: LogDraft
        if case .edit(let record) = panel {
            initial = LogDraft(record: record)
        } else if case .add(let day) = panel, let day {
            initial = LogDraft(kind: .bottle, date: min(day, Launch.now), zone: Launch.zone, unit: baby.presets.unit)
        } else {
            initial = LogDraft(kind: .bottle, date: Launch.now, zone: Launch.zone, unit: baby.presets.unit)
        }
        _draft = State(initialValue: initial)
    }

    var editing: LogRecord? {
        if case .edit(let entry) = panel { return entry }
        return nil
    }

    var isQuick: Bool { if case .amount = panel { return true }; return false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SheetHeader(title: L.t(isQuick ? "home.other" : editing == nil ? "editor.add" : "editor.edit"))
                if !isQuick { typeButtons }
                details
                if !isQuick { dates }
                InlineProblem(message: problem)
                Button(L.t("action.save")) { save() }
                    .buttonStyle(KeyStyle(prominent: true))
                    .accessibilityIdentifier("editor.save")
                    .disabled(model.busy)
                if editing != nil {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Text(L.t("action.delete")).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("editor.delete")
                    .disabled(model.busy)
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationBackground(Palette.surface)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.busy)
        .task { if isQuick && !Launch.testing { amountFocused = true } }
        .confirmationDialog(L.t("editor.confirmDelete"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(L.t("action.delete"), role: .destructive) { delete() }
            Button(L.t("action.cancel"), role: .cancel) {}
        }
    }

    private var typeButtons: some View {
        let content = ForEach(LogKind.allCases, id: \.self) { kind in
            Button(kind.label) {
                if draft.kind != .bottle && kind == .bottle && draft.amount.isEmpty { draft.unit = baby.presets.unit }
                draft.kind = kind
            }
            .buttonStyle(KeyStyle(prominent: draft.kind == kind, height: 44))
            .accessibilityAddTraits(draft.kind == kind ? .isSelected : [])
            .accessibilityIdentifier("editor.kind.\(kind.rawValue)")
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content }
            VStack(spacing: 6) { content }
        }
    }

    @ViewBuilder
    private var details: some View {
        switch draft.kind {
        case .bottle:
            HStack(spacing: 8) {
                TextField(L.t("editor.amount"), text: $draft.amount)
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)
                    .padding(11)
                    .frame(minHeight: 46)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityIdentifier("editor.amount")
                if isQuick {
                    Text(draft.unit.label).foregroundStyle(Palette.muted)
                } else {
                    Picker(L.t("settings.unit"), selection: $draft.unit) {
                        ForEach(MilkUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("editor.unit")
                }
            }
        case .nursing:
            if editing != nil {
                Picker(L.t("editor.side"), selection: $draft.side) {
                    Text(L.t("action.none")).tag(Side?.none)
                    ForEach(Side.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .accessibilityIdentifier("editor.side")
            }
        case .mom:
            VStack(spacing: 8) {
                TextField(L.t("mom.name"), text: $draft.medName)
                    .padding(11).frame(minHeight: 46)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityIdentifier("editor.medName")
                TextField(L.t("mom.note"), text: $draft.medNote)
                    .padding(11).frame(minHeight: 46)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityIdentifier("editor.medNote")
            }
        case .diaper:
            Picker(L.t("home.diaper"), selection: $draft.diaper) {
                ForEach(Diaper.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("editor.diaper")
        }
    }

    private var dates: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker(L.t("editor.time"), selection: $draft.date, in: ...model.now,
                       displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, draft.zone)
                .frame(minHeight: 44)
                .accessibilityIdentifier("editor.time")
            if let entry = editing, !LogTime.sameZone(entry.zone, model.zone, at: entry.date) {
                Picker(L.t("csv.zone"), selection: $draft.zone) {
                    Text(entry.zone.identifier).tag(entry.zone)
                    Text(model.zone.identifier).tag(model.zone)
                }
                .accessibilityIdentifier("editor.zone")
            }
            let times = Array(Set(LogTime.wallTimes(draft.date, in: draft.zone))).sorted()
            if times.count > 1 {
                Picker(L.t("editor.offset"), selection: Binding(
                    get: { draft.zone.secondsFromGMT(for: draft.date) },
                    set: { offset in
                        if let date = times.first(where: { draft.zone.secondsFromGMT(for: $0) == offset && $0 <= Launch.now }) {
                            draft.date = date
                        }
                    }
                )) {
                    ForEach(times.filter { $0 <= model.now }, id: \.self) { time in
                        let offset = draft.zone.secondsFromGMT(for: time)
                        Text(draft.zone.abbreviation(for: time) ?? draft.zone.identifier).tag(offset)
                    }
                }
                .accessibilityIdentifier("editor.offset")
            }
        }
    }

    private func save() {
        amountFocused = false
        self.problem = nil
        let now = Launch.now
        var value = draft
        if isQuick {
            let date = quickDate ?? now
            quickDate = date
            value.date = date
        }
        Task {
            do {
                try await model.perform(.record(value, babyID: baby.id, editing: editing?.id, now: now))
                dismiss()
            } catch LogProblem.amount {
                self.problem = L.t("error.amount")
            } catch LogProblem.future {
                self.problem = L.t("error.future")
            } catch LogProblem.medName {
                self.problem = L.t("error.medName")
            } catch {
                self.problem = L.t("error.save")
            }
        }
    }

    private func delete() {
        guard let editing else { return }
        Task {
            do {
                try await model.perform(.delete(id: editing.id, babyID: editing.babyID))
                dismiss()
            } catch {
                self.problem = L.t("error.save")
            }
        }
    }
}

struct MomSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mom.remind") private var remind = false
    @AppStorage("mom.hours") private var hours = 4
    @State private var name = ""
    @State private var note = ""
    @State private var problem: String?
    @FocusState private var nameFocused: Bool

    private var recent: [String] {
        guard let snapshot = model.snapshot, let baby = snapshot.selected else { return [] }
        return MomMed.recent(snapshot.entriesByBaby[baby.id] ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SheetHeader(title: L.t("kind.mom"))
                if !recent.isEmpty {
                    Text(L.t("mom.recent")).font(.subheadline).foregroundStyle(Palette.muted)
                    LazyVGrid(columns: [GridItem(.flexible(minimum: 0), spacing: 8), GridItem(.flexible(minimum: 0), spacing: 8)], spacing: 8) {
                        ForEach(Array(recent.enumerated()), id: \.offset) { index, med in
                            Button { save(name: med, note: "") } label: {
                                Text(med).lineLimit(2).minimumScaleFactor(0.7)
                            }
                            .buttonStyle(KeyStyle(prominent: true, height: 52))
                            .accessibilityIdentifier("mom.recent.\(index)")
                            .disabled(model.busy)
                        }
                    }
                }
                Text(L.t("mom.other")).font(.subheadline).foregroundStyle(Palette.muted)
                field(L.t("mom.name"), text: $name, id: "mom.name").focused($nameFocused)
                field(L.t("mom.note"), text: $note, id: "mom.note")
                Button(L.t("mom.save")) { save(name: name, note: note) }
                    .buttonStyle(KeyStyle(prominent: recent.isEmpty, height: 48))
                    .accessibilityIdentifier("mom.save")
                    .disabled(model.busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                Toggle(L.t("mom.remind"), isOn: Binding(get: { remind }, set: { setRemind($0) }))
                    .tint(Palette.link)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("mom.remind")
                if remind {
                    Picker(L.t("mom.remind"), selection: $hours) {
                        ForEach([2, 4, 6, 8], id: \.self) { Text(L.f("mom.hours", Int64($0))).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("mom.hours")
                }
                InlineProblem(message: problem)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.surface)
        .interactiveDismissDisabled(model.busy)
        .task { if recent.isEmpty && !Launch.testing { nameFocused = true } }
    }

    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        TextField(title, text: text)
            .submitLabel(.done)
            .padding(11)
            .frame(minHeight: 46)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityIdentifier(id)
    }

    private func setRemind(_ on: Bool) {
        guard on else { remind = false; MomReminder.cancel(); return }
        remind = true
        problem = nil
        if Launch.testing { return }
        Task {
            if !(await MomReminder.authorize()) {
                remind = false
                problem = L.t("mom.denied")
            }
        }
    }

    private func save(name: String, note: String) {
        guard let baby = model.snapshot?.selected else { return }
        problem = nil
        let now = Launch.now
        var draft = LogDraft(kind: .mom, date: now, zone: Launch.zone)
        draft.medName = name
        draft.medNote = note
        Task {
            do {
                try await model.perform(.record(draft, babyID: baby.id, editing: nil, now: now),
                                        quickKey: "\(baby.id)-mom-\(name)")
                if remind && !Launch.testing { MomReminder.schedule(after: hours) }
                dismiss()
            } catch LogProblem.duplicate {
                return
            } catch LogProblem.medName {
                self.problem = L.t("error.medName")
            } catch {
                self.problem = L.t("error.save")
            }
        }
    }
}

enum MomReminder {
    static let id = "mom.next"

    static func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    static func schedule(after hours: Int) {
        let content = UNMutableNotificationContent()
        content.title = L.t("kind.mom")
        content.body = L.t("mom.notify")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(1, hours) * 3600), repeats: false)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
