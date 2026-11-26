import StoreKit
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: LogSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var undo: (id: UUID, babyID: UUID)?
    @Published private(set) var now = Launch.now
    @Published private(set) var zone = Launch.zone
    @Published var startProblem = false

    private var store: LogStore?
    private var opening = false
    private var undoTimer: Task<Void, Never>?
    private var lastQuickSave: (key: String, at: TimeInterval)?
    private var failNextRecord = Launch.arguments.contains("-fail-save")
    private var slowNextRecord = Launch.arguments.contains("-slow-save")

    func start() async {
        guard snapshot == nil, !opening else { return }
        opening = true
        startProblem = false
        defer { opening = false }
        do {
            let url = try await Task.detached { try Self.testURL() }.value
            let store = try await LogStore.open(at: url)
            snapshot = try await store.bootstrap(seedDemo: Launch.demo, twoBabies: Launch.arguments.contains("-two-babies"),
                                                 milestone: Launch.arguments.contains("-milestone"))
            self.store = store
        } catch {
            startProblem = true
        }
    }

    nonisolated private static func testURL() throws -> URL? {
        guard Launch.testing else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BabyLogUITests", isDirectory: true)
        if Launch.arguments.contains("-reset"), FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("test.store")
    }

    func tick() {
        now = Launch.now
        zone = Launch.zone
    }

    func perform(_ mutation: LogMutation, quickKey: String? = nil) async throws {
        guard let store, !busy else { throw LogProblem.duplicate }
        if let quickKey, let lastQuickSave, lastQuickSave.key == quickKey,
           ProcessInfo.processInfo.systemUptime - lastQuickSave.at < 0.65 { return }
        busy = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "BabyLog write", expirationHandler: nil)
        defer {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            busy = false
        }

        if case .record = mutation {
            if failNextRecord {
                failNextRecord = false
                throw LogProblem.write
            }
            if slowNextRecord {
                slowNextRecord = false
                try await Task.sleep(for: .milliseconds(700))
            }
        }

        let result = try await store.apply(mutation)
        snapshot = result.snapshot
        tick()

        if let quickKey { lastQuickSave = (quickKey, ProcessInfo.processInfo.systemUptime) }
        if case let .record(_, babyID, _, _) = mutation, let id = result.inserted {
            showUndo(id: id, babyID: babyID)
            CoreReview.shared.record()
        }
    }

    func undoLast() async throws {
        guard let undo else { return }
        try await perform(.delete(id: undo.id, babyID: undo.babyID))
        if self.undo?.id == undo.id {
            self.undo = nil
            lastQuickSave = nil
        }
    }

    private func showUndo(id: UUID, babyID: UUID) {
        undo = (id, babyID)
        undoTimer?.cancel()
        undoTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) }
            catch { return }
            if self?.undo?.id == id { self?.undo = nil }
        }
    }
}

@main
struct BabyLogApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

private enum Page: Hashable { case history, settings }

enum LogSheet: Identifiable {
    case diaper, mom, amount, add(Date?), edit(LogRecord), handoff(String?), paywall

    var id: String {
        switch self {
        case .diaper: return "diaper"
        case .mom: return "mom"
        case .amount: return "amount"
        case .add: return "add"
        case .edit(let entry): return entry.id.uuidString
        case .handoff(let day): return "handoff-\(day ?? "recent")"
        case .paywall: return "paywall"
        }
    }
}

@MainActor
private struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var purchases = Purchases()
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    @State private var path: [Page] = []
    @State private var sheet: LogSheet?
    @State private var problem: String?
    @State private var retry: (() -> Void)?
    @State private var reviewCheckedAt: Date?
    @State private var reviewOffered = false
    @State private var launchedPaywall = false
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let snapshot = model.snapshot, let baby = snapshot.selected {
                    HomeView(snapshot: snapshot, baby: baby, showSheet: { sheet = $0 }, showHistory: { path.append(.history) },
                             showSettings: { path.append(.settings) }, save: saveQuick, switchBaby: switchBaby)
                        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
                } else if model.startProblem {
                    VStack(spacing: 12) {
                        InlineProblem(message: L.t("error.open"))
                        Button(L.t("action.retry")) { Task { await model.start() } }
                            .buttonStyle(KeyStyle(prominent: true))
                            .accessibilityIdentifier("app.retry")
                    }
                    .padding(20)
                } else {
                    ProgressView().tint(Palette.link).accessibilityLabel(L.t("status.loading"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .history: HistoryView(showSheet: { sheet = $0 })
                case .settings: SettingsView(showPaywall: { sheet = .paywall })
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.link)
        .sheet(item: $sheet, onDismiss: { reviewCheckedAt = .now }) { panel in
            switch panel {
            case .diaper:
                DiaperSheet().presentationDetents([.height(292), .large])
            case .mom:
                MomSheet().presentationDetents([.medium, .large])
            case .amount, .add, .edit:
                if let baby = model.snapshot?.selected { EditorSheet(panel: panel, baby: baby) }
            case .handoff(let day): HandoffView(day: day)
            case .paywall: PaywallView()
            }
        }
        .environmentObject(model)
        .environmentObject(purchases)
        .preferredColorScheme(Launch.arguments.contains("-dark") ? .dark : nil)
        .dynamicTypeSize(typeRange)
        .task {
            Task.detached(priority: .utility) { ShareFiles.removeStale() }
            async let records: Void = model.start()
            async let rights: Void = purchases.start()
            _ = await (records, rights)
            if !launchedPaywall && Launch.arguments.contains("-paywall") && !Launch.isFree {
                launchedPaywall = true
                sheet = .paywall
            }
        }
        .reviewAfterCoreAction(when: path.isEmpty && sheet == nil && model.snapshot != nil && !model.busy && !purchases.busy && model.undo == nil && problem == nil && !model.startProblem) { requestReview() }
        .onReceive(clock) { _ in
            guard phase == .active else { return }
            model.tick()
            offerReview()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            model.tick()
        }
        .onChange(of: phase) { _, value in
            guard value == .active else { return }
            model.tick()
            reviewCheckedAt = .now
            Task { await purchases.start() }
        }
        .onChange(of: path) { _, _ in
            problem = nil
            retry = nil
            reviewCheckedAt = .now
        }
    }

    private var typeRange: ClosedRange<DynamicTypeSize> {
        Launch.arguments.contains("-large-text") ? (.accessibility2 ... .accessibility2) : (.xSmall ... .accessibility5)
    }

    private var footer: some View {
        VStack(spacing: 7) {
            if let problem {
                HStack {
                    InlineProblem(message: problem)
                    if let retry {
                        Button(L.t("action.retry"), action: retry)
                            .buttonStyle(LinkStyle())
                            .accessibilityIdentifier("home.retry")
                    }
                }
            } else if let undo = model.undo, undo.babyID == model.snapshot?.selectedID {
                HStack {
                    Text(L.t("status.saved")).font(.footnote)
                        .accessibilityIdentifier("home.saved")
                    Spacer()
                    Button(L.t("action.undo")) {
                        Task {
                            do { try await model.undoLast() }
                            catch { self.problem = L.t("error.save") }
                        }
                    }
                    .buttonStyle(LinkStyle())
                    .accessibilityIdentifier("home.undo")
                    .disabled(model.busy)
                }
            }
            Button {
                sheet = .handoff(nil)
            } label: {
                ArrowLabel(text: L.t("home.handoff"))
            }
            .buttonStyle(KeyStyle(prominent: true))
            .accessibilityIdentifier("home.handoff")
        }
        .padding(.horizontal, 20)
        .padding(.top, 5)
        .padding(.bottom, 4)
        .background(Palette.background)
    }

    private func saveQuick(_ kind: LogKind, amount: String?, baby: BabyProfile) {
        guard !model.busy else { return }
        problem = nil
        retry = nil
        reviewCheckedAt = .now
        let moment = Launch.now
        var draft = LogDraft(kind: kind, date: moment, zone: Launch.zone, unit: baby.presets.unit)
        draft.amount = amount ?? ""
        let quickKey = "\(baby.id)-\(kind.rawValue)-\(amount ?? "")"
        persistQuick(draft, babyID: baby.id, key: quickKey)
    }

    private func persistQuick(_ draft: LogDraft, babyID: UUID, key: String) {
        problem = nil
        retry = nil
        Task {
            do {
                try await model.perform(.record(draft, babyID: babyID, editing: nil, now: Launch.now), quickKey: key)
            } catch LogProblem.duplicate {
                return
            } catch {
                self.problem = L.t("error.save")
                self.retry = { persistQuick(draft, babyID: babyID, key: key) }
            }
        }
    }

    private func switchBaby(_ id: UUID) {
        problem = nil
        retry = nil
        Task {
            do { try await model.perform(.select(id)) }
            catch { self.problem = L.t("error.save") }
        }
    }

    private func offerReview() {
        guard !reviewOffered, path.isEmpty, sheet == nil, !model.busy, model.undo == nil, problem == nil,
              reviewCheckedAt.map({ Date.now.timeIntervalSince($0) >= 2 }) ?? true,
              model.snapshot?.shouldAskForReview(at: model.now, zone: model.zone) == true else { return }
        guard CoreReview.shared.attempt({ requestReview() }) else { return }
        reviewOffered = true
        Task { try? await model.perform(.requestReview) }
    }
}

