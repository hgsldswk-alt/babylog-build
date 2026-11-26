import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedDay = LogTime.day(Launch.now, zone: Launch.zone)
    @State private var milestone = false
    @State private var exporting = false
    var showSheet: (LogSheet) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker(L.t("history.date"), selection: dateSelection, in: ...model.now, displayedComponents: .date)
                    .environment(\.timeZone, model.zone)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("history.date")
                HStack {
                    Button(L.t("history.previous")) { move(-1) }
                        .buttonStyle(LinkStyle())
                        .accessibilityIdentifier("history.previous")
                    Spacer()
                    Button(L.t("history.next")) { move(1) }
                        .buttonStyle(LinkStyle())
                        .disabled(key >= today)
                        .accessibilityIdentifier("history.next")
                }
                Button(L.t("editor.add")) { showSheet(.add(day)) }
                    .buttonStyle(KeyStyle())
                    .accessibilityIdentifier("history.backfill")
                if model.snapshot?.earnedMilestone == true && model.snapshot?.milestoneSeen == false {
                    Button(L.t("history.milestone")) { milestone = true }
                        .buttonStyle(KeyStyle())
                        .accessibilityIdentifier("history.milestone")
                }
                if entries.isEmpty {
                    Text(L.t("status.empty"))
                        .foregroundStyle(Palette.muted)
                        .padding(.vertical, 14)
                        .accessibilityIdentifier("history.empty")
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        showSheet(.edit(entry))
                    } label: {
                        RecordRow(entry: entry, now: model.now, zone: model.zone)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history.record.\(index)")
                    Divider()
                }
                Button(L.t("home.handoff")) { showSheet(.handoff(key)) }
                    .buttonStyle(KeyStyle(prominent: true))
                    .accessibilityIdentifier("history.handoff")
                Button(L.t("history.csv")) { exporting = true }
                    .buttonStyle(KeyStyle())
                    .accessibilityIdentifier("history.csv")
            }
            .padding(20)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(L.t("history.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(isPresented: $milestone) { MilestoneView() }
        .sheet(isPresented: $exporting) { CSVExportView(day: day) }
    }

    private var day: Date {
        let localDay = LogTime.dayDate(key, zone: model.zone) ?? model.now
        return LogTime.calendar(model.zone).startOfDay(for: localDay)
    }
    private var key: String { min(selectedDay, today) }
    private var today: String { LogTime.day(model.now, zone: model.zone) }
    private var entries: [LogRecord] { model.snapshot?.entries.filter { $0.day == key } ?? [] }
    private var dateSelection: Binding<Date> {
        Binding(get: { day }, set: { selectedDay = LogTime.day($0, zone: model.zone) })
    }

    private func move(_ amount: Int) {
        if let date = LogTime.calendar(model.zone).date(byAdding: .day, value: amount, to: day),
           LogTime.day(date, zone: model.zone) <= today {
            selectedDay = LogTime.day(date, zone: model.zone)
        }
    }
}

private struct CSVExportView: View {
    @EnvironmentObject private var model: AppModel
    @State private var start: Date
    @State private var end: Date
    @State private var output: ActivityPayload?
    @State private var problem: String?
    @State private var busy = false

    init(day: Date) {
        _start = State(initialValue: day)
        _end = State(initialValue: day)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SheetHeader(title: L.t("history.csv"))
                if let selected = model.snapshot?.selected { Text(selected.displayName).foregroundStyle(Palette.muted) }
                DatePicker(L.t("history.start"), selection: $start, in: ...model.now, displayedComponents: .date)
                    .accessibilityIdentifier("csv.start")
                DatePicker(L.t("history.end"), selection: $end, in: ...model.now, displayedComponents: .date)
                    .accessibilityIdentifier("csv.end")
                InlineProblem(message: problem)
                Button(L.t("history.csv")) { export() }
                    .buttonStyle(KeyStyle(prominent: true))
                    .accessibilityIdentifier("csv.export")
                    .disabled(busy)
            }
            .padding(20)
        }
        .environment(\.timeZone, model.zone)
        .presentationBackground(Palette.surface)
        .shareActivity($output)
    }

    private func export() {
        guard !busy, let snapshot = model.snapshot else { return }
        busy = true
        problem = nil
        let zone = model.zone
        let from = LogTime.day(start, zone: zone)
        let through = LogTime.day(end, zone: zone)
        Task {
            defer { busy = false }
            do {
                let url = try await Task.detached {
                    let data = try LogCSV.encode(snapshot.entries, from: from, through: through)
                    return try ShareFiles.write(data, suffix: "csv")
                }.value
                output = ActivityPayload.file(url)
            } catch LogProblem.range {
                self.problem = L.t("error.range")
            } catch {
                self.problem = L.t("error.export")
            }
        }
    }
}

