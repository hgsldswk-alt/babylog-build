import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

enum QRCode {
    static func make(_ url: URL, scale: Int = 8) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let pixels = filter.outputImage else { return nil }
        let background = CIImage(color: .white).cropped(to: pixels.extent.insetBy(dx: -4, dy: -4))
        let image = pixels.composited(over: background)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return CIContext().createCGImage(image, from: image.extent)
    }
}

enum ShareFiles {
    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BabyLogShares", isDirectory: true)
    }

    static func write(_ data: Data, suffix: String) throws -> URL {
        let manager = FileManager.default
        let path = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: path, withIntermediateDirectories: true)
        let url = path.appendingPathComponent("BabyLog.\(suffix)")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        } catch {
            try? manager.removeItem(at: path)
            throw error
        }
    }

    static func remove(_ file: URL) {
        let parent = file.deletingLastPathComponent()
        guard parent.deletingLastPathComponent() == folder else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    static func removeStale() {
        let manager = FileManager.default
        let paths = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for path in paths {
            if let created = try? path.resourceValues(forKeys: [.creationDateKey]).creationDate,
               Date.now.timeIntervalSince(created) > 86_400 {
                try? manager.removeItem(at: path)
            }
        }
    }
}

struct ActivityPayload: Identifiable {
    let id = UUID()
    var items: [Any]
    var file: URL?
    var complete: (Bool) -> Void = { _ in }

    static func file(_ url: URL, complete: @escaping (Bool) -> Void = { _ in }) -> Self {
        Self(items: [url], file: url, complete: complete)
    }
}

private struct SystemActivity: UIViewControllerRepresentable {
    let payload: ActivityPayload
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activity = UIActivityViewController(activityItems: payload.items, applicationActivities: nil)
        let completed = payload.complete
        let close = dismiss
        activity.completionWithItemsHandler = { _, success, _, _ in
            DispatchQueue.main.async { completed(success); close() }
        }
        return activity
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ActivityPresentation: ViewModifier {
    @Binding var item: ActivityPayload?
    @State private var cleanup: URL?

    func body(content: Content) -> some View {
        content.sheet(item: $item, onDismiss: {
            if let cleanup {
                Task.detached { ShareFiles.remove(cleanup) }
                self.cleanup = nil
            }
        }) { payload in
            SystemActivity(payload: payload)
                .onAppear { cleanup = payload.file }
        }
    }
}

extension View {
    func shareActivity(_ item: Binding<ActivityPayload?>) -> some View {
        modifier(ActivityPresentation(item: item))
    }
}

struct HandoffView: View {
    @EnvironmentObject private var model: AppModel
    @State private var candidates: [LogRecord] = []
    @State private var selected = Set<UUID>()
    @State private var generated = Launch.now
    @State private var zone = Launch.zone
    @State private var initialized = false
    @State private var showRecords = false
    @State private var showOptions = false
    @State private var addQR = false
    @State private var qr: CGImage?
    @State private var copied = false
    @State private var output: ActivityPayload?
    @State private var busy = false
    @State private var problem: String?
    let day: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SheetHeader(title: L.t("share.preview"))
                Text(L.t("share.private"))
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("share.privacy")
                preview
                optionsRow
                if showRecords { records }
                if showOptions { options }
                InlineProblem(message: problem)
                actions
            }
            .padding(20)
        }
        .presentationBackground(Palette.surface)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy)
        .shareActivity($output)
        .task {
            guard !initialized else { return }
            initialized = true
            generated = Launch.now
            zone = model.zone
            let entries = model.snapshot?.entries ?? []
            candidates = day.map { key in entries.filter { $0.day == key } } ?? Handoff.recent(entries, now: generated)
            selected = Handoff.initial(candidates, balance: day == nil)
        }
        .task(id: addQR) {
            guard addQR, qr == nil, let url = Launch.downloadURL else { return }
            let image = await Task.detached { QRCode.make(url) }.value
            guard !Task.isCancelled else { return }
            if let image {
                qr = image
            } else {
                addQR = false
                problem = L.t("error.export")
            }
        }
    }

    private var chosen: [LogRecord] { candidates.filter { selected.contains($0.id) } }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeading(title: L.t("share.title"), subtitle: L.f("share.generated", LogTime.absoluteStamp(generated, zone: zone)))
            if chosen.isEmpty {
                Text(L.t("share.empty"))
                    .font(.footnote)
                    .foregroundStyle(Palette.paperMuted)
                    .padding(.top, 9)
                    .accessibilityIdentifier("share.empty")
            } else {
                ForEach(chosen) { entry in
                    CardRow(entry: entry, generated: generated, zone: zone)
                }
            }
            if addQR, let qr {
                DownloadBadge(qr: qr)
                    .padding(.top, 9)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("share.qr")
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
    }

    private var optionsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack { selectButton.fixedSize(); Spacer(minLength: 4); optionsButton.fixedSize() }
            VStack(alignment: .leading, spacing: 0) { selectButton; optionsButton }
        }
    }

    private var selectButton: some View {
        Button {
            showRecords.toggle()
            if showRecords { showOptions = false }
        } label: {
            Text(L.f("share.select", Int64(selected.count)))
        }
        .buttonStyle(LinkStyle())
        .accessibilityIdentifier("share.select")
    }

    private var optionsButton: some View {
        Button(L.t("share.options")) {
            showOptions.toggle()
            if showOptions { showRecords = false }
        }
        .buttonStyle(LinkStyle())
        .accessibilityIdentifier("share.options")
    }

    private var records: some View {
        VStack(spacing: 1) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, entry in
                Button {
                    if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
                } label: {
                    HStack {
                        RecordRow(entry: entry, now: generated, zone: zone)
                        Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Palette.link)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(entry.id) ? .isSelected : [])
                .accessibilityIdentifier("share.record.\(index)")
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(L.t("share.addQR"), isOn: $addQR)
                .disabled(Launch.downloadURL == nil)
                .frame(minHeight: 44)
                .accessibilityIdentifier("share.addQR")
            if Launch.downloadURL == nil {
                Text(L.t("share.qrPending")).font(.footnote).foregroundStyle(Palette.muted)
            }
            Button(L.t(copied ? "status.copied" : "share.copyTags")) {
                UIPasteboard.general.string = L.t("share.tags")
                copied = true
            }
            .buttonStyle(LinkStyle())
            .accessibilityIdentifier("share.copyTags")
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { textButton.fixedSize(horizontal: false, vertical: true); imageButton.fixedSize(horizontal: false, vertical: true) }
            VStack(spacing: 8) { textButton; imageButton }
        }
        .disabled(chosen.isEmpty || busy)
    }

    private var textButton: some View {
        Button(L.t("share.text")) {
            output = ActivityPayload(items: [Handoff.text(chosen, now: generated, zone: zone)], complete: didShare)
        }
        .buttonStyle(KeyStyle())
        .accessibilityIdentifier("share.text")
    }

    private var imageButton: some View {
        Button(L.t("share.image")) { render() }
            .buttonStyle(KeyStyle(prominent: true))
            .disabled(addQR && qr == nil)
            .accessibilityIdentifier("share.image")
    }

    private func didShare(_ complete: Bool) {
        guard complete, model.snapshot?.handoffShared == false else { return }
        Task {
            do { try await model.perform(.shareHandoff) }
            catch { self.problem = L.t("error.save") }
        }
    }

    private func render() {
        guard !busy else { return }
        let entries = chosen
        let stamp = generated
        let zone = self.zone
        let qr = addQR ? self.qr : nil
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                let data = try ShareImage.png {
                    ExportHandoffCard(entries: entries, generated: stamp, zone: zone, qr: qr)
                }
                let url = try await Task.detached { try ShareFiles.write(data, suffix: "png") }.value
                output = .file(url, complete: didShare)
            } catch {
                self.problem = L.t("error.export")
            }
        }
    }
}

struct MilestoneView: View {
    @EnvironmentObject private var model: AppModel
    @State private var qr: CGImage?
    @State private var copied = false
    @State private var output: ActivityPayload?
    @State private var busy = false
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SheetHeader(title: L.t("milestone.title"))
                card.padding(20).background(Palette.paper, in: RoundedRectangle(cornerRadius: 16))
                if Launch.downloadURL == nil {
                    Text(L.t("share.qrPending")).font(.footnote).foregroundStyle(Palette.muted)
                }
                InlineProblem(message: problem)
                Button(L.t("share.image")) { render() }
                    .buttonStyle(KeyStyle(prominent: true))
                    .accessibilityIdentifier("milestone.share")
                    .disabled(busy || (Launch.downloadURL != nil && qr == nil))
                Button(L.t(copied ? "status.copied" : "share.copyTags")) {
                    UIPasteboard.general.string = L.t("share.tags")
                    copied = true
                }
                .buttonStyle(LinkStyle())
                .accessibilityIdentifier("milestone.copyTags")
            }
            .padding(20)
        }
        .presentationBackground(Palette.surface)
        .shareActivity($output)
        .task {
            if let url = Launch.downloadURL {
                qr = await Task.detached { QRCode.make(url) }.value
            }
        }
        .onAppear {
            Task {
                do { try await model.perform(.seeMilestone) }
                catch { self.problem = L.t("error.save") }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.t("milestone.line")).font(.largeTitle.bold()).foregroundStyle(Palette.paperInk)
            DownloadBadge(qr: qr)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func render() {
        guard !busy else { return }
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            do {
                let data = try ShareImage.png { card.padding(28) }
                let url = try await Task.detached { try ShareFiles.write(data, suffix: "png") }.value
                output = .file(url)
            } catch {
                self.problem = L.t("error.export")
            }
        }
    }
}

private struct DownloadBadge: View {
    var qr: CGImage?

    var body: some View {
        HStack {
            Text(L.t("app.name")).font(.footnote.weight(.semibold)).foregroundStyle(Palette.paperInk)
            Spacer(minLength: 6)
            if let qr {
                Image(decorative: qr, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 70, height: 70)
                    .accessibilityHidden(false)
                    .accessibilityLabel(L.t("share.download"))
            }
        }
    }
}

private struct CardHeading: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title2.bold()).foregroundStyle(Palette.paperInk)
            Text(subtitle).font(.caption).foregroundStyle(Palette.paperMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

private struct CardRow: View {
    var entry: LogRecord
    var generated: Date
    var zone: TimeZone

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.paperLine).frame(height: 1).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    stamp.fixedSize()
                    Spacer(minLength: 3)
                    value.fixedSize()
                }
                VStack(alignment: .leading, spacing: 3) { stamp; value }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    private var stamp: some View {
        Text(LogTime.stamp(entry, now: generated, zone: zone, absolute: true))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Palette.paperMuted)
    }

    private var value: some View {
        HStack(spacing: 6) {
            Text(entry.kind.label)
            if !entry.detail.isEmpty { Text(entry.detail).fontWeight(.semibold) }
        }
        .font(.caption)
        .foregroundStyle(Palette.paperInk)
    }
}

private struct ExportHandoffCard: View {
    var entries: [LogRecord]
    var generated: Date
    var zone: TimeZone
    var qr: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeading(title: L.t("share.title"), subtitle: L.f("share.generated", LogTime.absoluteStamp(generated, zone: zone)))
            ForEach(entries) { entry in CardRow(entry: entry, generated: generated, zone: zone) }
            if let qr { DownloadBadge(qr: qr).padding(.top, 12) }
        }
        .padding(28)
    }
}

@MainActor
private enum ShareImage {
    static func png<Content: View>(@ViewBuilder content: () -> Content) throws -> Data {
        let renderer = ImageRenderer(content: content()
            .frame(width: 432)
            .background(Palette.paper)
            .environment(\.dynamicTypeSize, .large))
        renderer.isOpaque = true
        renderer.scale = 2.5
        guard let image = renderer.uiImage, let data = image.pngData() else { throw LogProblem.export }
        return data
    }
}

