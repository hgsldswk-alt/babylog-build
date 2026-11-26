import StoreKit
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum SettingsSheet: String, Identifiable {
    case add, rename, presets, importCode
    var id: Self { self }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.requestReview) private var requestReview
    @State private var panel: SettingsSheet?
    @State private var output: ActivityPayload?
    @State private var problem: String?
    var showPaywall: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                if let baby = model.snapshot?.selected {
                    profiles(baby)
                    section("settings.milk") {
                        row(baby.presets.amounts.map { MilkAmount.label($0) }.joined(separator: " · ") + " " + baby.presets.unit.label,
                            id: "settings.presets") { panel = .presets }
                            .accessibilityLabel(L.t("settings.presets"))
                            .accessibilityValue(baby.presets.code)
                        row(L.t("settings.shareCode"), id: "settings.shareCode") {
                            output = ActivityPayload(items: [baby.presets.code])
                        }
                        row(L.t("settings.importCode"), id: "settings.importCode") { panel = .importCode }
                    }
                }
                if !Launch.isFree {
                    section("pay.title") {
                        row(L.t("pay.unlock"), id: "settings.paywall", action: showPaywall)
                        row(L.t("pay.restore"), id: "settings.restore") { Task { await purchases.restore() } }
                            .disabled(purchases.busy)
                        InlineProblem(message: purchases.message)
                    }
                }
                section("settings.recommend") {
                    if let url = Launch.downloadURL {
                        row(L.t("settings.shareApp"), id: "settings.shareApp") { output = ActivityPayload(items: [url]) }
                    }
                    row(L.t("settings.rate"), id: "settings.rate") { if !Launch.testing { requestReview() } }
                }
                InlineProblem(message: problem)
            }
            .padding(20)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(L.t("settings.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .shareActivity($output)
        .sheet(item: $panel) { sheet in
            if let baby = model.snapshot?.selected {
                switch sheet {
                case .add, .rename: ProfileEditor(baby: baby, adding: sheet == .add)
                case .presets: PresetsEditor(baby: baby)
                case .importCode: CodeImporter(baby: baby)
                }
            }
        }
    }

    private func profiles(_ baby: BabyProfile) -> some View {
        section("settings.babies") {
            ForEach(Array((model.snapshot?.babies ?? []).enumerated()), id: \.element.id) { index, profile in
                Button {
                    Task {
                        do { try await model.perform(.select(profile.id)) }
                        catch { self.problem = L.t("error.save") }
                    }
                } label: {
                    HStack {
                        Text(profile.displayName)
                        Spacer()
                        if profile.id == baby.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                    .padding(.horizontal, 5)
                }
                .buttonStyle(KeyStyle(height: 44))
                .accessibilityIdentifier("settings.baby.\(index)")
                .accessibilityAddTraits(profile.id == baby.id ? .isSelected : [])
            }
            row(L.t("settings.rename"), id: "settings.rename") { panel = .rename }
            row(L.t("settings.addBaby"), id: "settings.addBaby") {
                if purchases.canAdd(at: Launch.now) {
                    panel = .add
                } else {
                    showPaywall()
                }
            }
        }
    }

    private func section<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L.t(key)).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { ArrowLabel(text: title) }
            .buttonStyle(KeyStyle(height: 44))
            .accessibilityIdentifier(id)
    }
}

private struct ProfileEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var problem: String?
    let baby: BabyProfile
    let adding: Bool

    init(baby: BabyProfile, adding: Bool) {
        self.baby = baby
        self.adding = adding
        _name = State(initialValue: adding ? "" : baby.name)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SheetHeader(title: L.t(adding ? "settings.addBaby" : "settings.rename"))
                TextField(L.t("profile.name"), text: $name)
                    .padding(11)
                    .frame(minHeight: 44)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityIdentifier("profile.name")
                InlineProblem(message: problem)
                Button(L.t("action.save")) { save() }
                    .buttonStyle(KeyStyle(prominent: true))
                    .accessibilityIdentifier("profile.save")
                    .disabled(model.busy)
            }
            .padding(20)
        }
        .presentationBackground(Palette.surface)
    }

    private func save() {
        Task {
            do {
                let mutation: LogMutation = adding ? .addBaby(name, allowed: purchases.canAdd(at: Launch.now)) : .rename(baby.id, name)
                try await model.perform(mutation)
                dismiss()
            } catch LogProblem.locked {
                self.problem = L.t("pay.expired")
            } catch {
                self.problem = L.t("error.save")
            }
        }
    }
}

private struct PresetsEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var unit: MilkUnit
    @State private var amounts: [String]
    @State private var problem: String?
    let baby: BabyProfile

    init(baby: BabyProfile) {
        self.baby = baby
        _unit = State(initialValue: baby.presets.unit)
        _amounts = State(initialValue: baby.presets.amounts.map { MilkAmount.label($0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SheetHeader(title: L.t("settings.presets"))
                Picker(L.t("settings.unit"), selection: $unit) {
                    ForEach(MilkUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("presets.unit")
                .onChange(of: unit) { _, value in
                    amounts = value == baby.presets.unit ? baby.presets.amounts.map { MilkAmount.label($0) } : value.defaults
                }
                Text(L.t("presets.help")).font(.footnote).foregroundStyle(Palette.muted)
                ForEach(amounts.indices, id: \.self) { index in
                    HStack {
                        Text(L.f("presets.item", Int64(index + 1))).foregroundStyle(Palette.muted)
                        TextField(L.t("editor.amount"), text: $amounts[index])
                            .keyboardType(.decimalPad)
                            .padding(9)
                            .frame(minHeight: 44)
                            .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityIdentifier("presets.amount.\(index)")
                        if index >= 3 {
                            Button {
                                amounts.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(L.f("presets.remove", Int64(index + 1)))
                            .accessibilityIdentifier("presets.remove.\(index)")
                        }
                    }
                }
                if amounts.count < 6 {
                    Button(L.t("presets.append")) { amounts.append("") }
                        .buttonStyle(LinkStyle())
                        .accessibilityIdentifier("presets.append")
                }
                InlineProblem(message: problem)
                Button(L.t("action.save")) { save() }
                    .buttonStyle(KeyStyle(prominent: true))
                    .accessibilityIdentifier("presets.save")
                    .disabled(model.busy)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationBackground(Palette.surface)
    }

    private func save() {
        Task {
            do {
                let checked = try MilkPresets.checked(unit: unit, amounts: amounts)
                try await model.perform(.presets(baby.id, checked))
                dismiss()
            } catch LogProblem.amount {
                self.problem = L.t("error.amount")
            } catch LogProblem.duplicate {
                self.problem = L.t("error.presetsDuplicate")
            } catch {
                self.problem = L.t("error.save")
            }
        }
    }
}

private struct CodeImporter: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    @State private var input = ""
    @State private var preview: MilkPresets?
    @State private var problem: String?
    @State private var picking = false
    let baby: BabyProfile

    init(baby: BabyProfile) {
        self.baby = baby
        let seeded = Launch.testing ? ProcessInfo.processInfo.environment["BABYLOG_UI_CODE"] : nil
        _input = State(initialValue: seeded ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SheetHeader(title: L.t("settings.importCode"))
                Text(L.t("code.input")).font(.subheadline).foregroundStyle(Palette.muted)
                TextEditor(text: $input)
                    .focused($typing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 78)
                    .padding(5)
                    .background(Palette.raised, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel(L.t("code.input"))
                    .accessibilityIdentifier("code.input")
                Button(L.t("code.file")) { picking = true }
                    .buttonStyle(LinkStyle())
                    .accessibilityIdentifier("code.file")
                if let preview {
                    Text(L.f("code.target", baby.displayName)).font(.subheadline)
                    Text(preview.amounts.map { MilkAmount.label($0) }.joined(separator: " · ") + " " + preview.unit.label)
                        .font(.headline)
                        .accessibilityIdentifier("code.previewValues")
                    Button(L.t("code.apply")) { apply(preview) }
                        .buttonStyle(KeyStyle(prominent: true))
                        .accessibilityIdentifier("code.apply")
                        .disabled(model.busy)
                } else {
                    Button(L.t("code.preview")) { parse(input) }
                        .buttonStyle(KeyStyle(prominent: true))
                        .accessibilityIdentifier("code.preview")
                }
                InlineProblem(message: problem)
            }
            .padding(20)
        }
        .presentationBackground(Palette.surface)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: input) { _, _ in preview = nil; problem = nil }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.plainText]) { result in
            Task {
                do {
                    let url = try result.get()
                    let code = try await Task.detached {
                        let granted = url.startAccessingSecurityScopedResource()
                        defer { if granted { url.stopAccessingSecurityScopedResource() } }
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        guard let data = try handle.read(upToCount: 257), data.count <= 256,
                              let text = String(data: data, encoding: .utf8) else { throw LogProblem.importFile }
                        return text
                    }.value
                    input = code
                } catch {
                    self.problem = L.t("error.codeFile")
                }
            }
        }
    }

    private func parse(_ text: String) {
        typing = false
        do {
            preview = try MilkPresets(code: text)
            problem = nil
        } catch {
            self.problem = L.t("error.code")
        }
    }

    private func apply(_ value: MilkPresets) {
        Task {
            do {
                try await model.perform(.presets(baby.id, value))
                dismiss()
            } catch {
                self.problem = L.t("error.save")
            }
        }
    }
}

struct PaywallView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: Purchases

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                SheetHeader(title: L.t("pay.title"))
                    .accessibilityElement(children: .contain)
                Text(L.t("pay.unlock")).font(.largeTitle.bold()).accessibilityIdentifier("paywall.title")
                Text(L.t("pay.description")).foregroundStyle(Palette.muted)
                Text(status).font(.headline).accessibilityIdentifier("paywall.status")
                if purchases.entitlement?.purchasedPro != true {
                    Button {
                        Task { await purchases.buy(purchases.pro) }
                    } label: {
                        Text(buyLabel)
                    }
                    .buttonStyle(KeyStyle(prominent: true))
                    .accessibilityIdentifier("paywall.buy")
                    .disabled(purchases.busy || (purchases.pro == nil && !Launch.testing))
                    if purchases.entitlement?.trialClaimedAt == nil && purchases.canAdd(at: Launch.now) {
                        Button(L.t("pay.trial")) { Task { await purchases.buy(purchases.trial) } }
                            .buttonStyle(KeyStyle())
                            .accessibilityIdentifier("paywall.trial")
                            .disabled(purchases.busy || (purchases.trial == nil && !Launch.testing))
                    }
                }
                Button(L.t("pay.restore")) { Task { await purchases.restore() } }
                    .buttonStyle(LinkStyle())
                    .accessibilityIdentifier("paywall.restore")
                    .disabled(purchases.busy)
                InlineProblem(message: purchases.message)
                if (purchases.pro == nil || purchases.trial == nil) && purchases.message != nil && !Launch.testing {
                    Button(L.t("action.retry")) { Task { await purchases.load() } }
                        .buttonStyle(LinkStyle())
                        .accessibilityIdentifier("paywall.retry")
                }
            }
            .padding(20)
        }
        .presentationBackground(Palette.surface)
        .task { await purchases.load() }
    }

    private var buyLabel: String {
        if let price = purchases.pro?.displayPrice { return L.f("pay.price", price) }
        if Launch.arguments.contains("-paywall") { return L.f("pay.price", "US$3.99") }
        return L.t("pay.buy")
    }

    private var status: String {
        guard let entitlement = purchases.entitlement else { return L.t("status.loading") }
        if entitlement.purchasedPro { return L.t("pay.purchased") }
        let now = max(model.now, Launch.now)
        guard entitlement.hasPro(at: now, free: false) else { return L.t("pay.expired") }
        let days = max(1, Int64(ceil(entitlement.trialEnd.timeIntervalSince(now) / 86_400)))
        return L.f("pay.days", days)
    }
}

