import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .largeTitle) private var headline: CGFloat = 34
    var snapshot: LogSnapshot
    var baby: BabyProfile
    var showSheet: (LogSheet) -> Void
    var showHistory: () -> Void
    var showSettings: () -> Void
    var save: (LogKind, String?, BabyProfile) -> Void
    var switchBaby: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                header
                summaries
                quickActions
                recent
            }
            .padding(.horizontal, 20)
            .padding(.top, 7)
            .padding(.bottom, 8)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.scroll")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LogTime.header(model.now, zone: model.zone))
                .font(.caption)
                .foregroundStyle(Palette.muted)
            HStack {
                Text(L.t("app.name"))
                    .font(.system(size: headline, weight: .bold))
                    .tracking(-1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                Button(L.t("settings.title"), action: showSettings)
                    .buttonStyle(LinkStyle())
                    .accessibilityIdentifier("home.settings")
            }
            if snapshot.babies.count > 1 {
                Menu {
                    ForEach(snapshot.babies) { option in
                        Button(option.displayName) { switchBaby(option.id) }
                    }
                } label: {
                    Label(baby.displayName, systemImage: "chevron.down")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(LinkStyle())
                .accessibilityIdentifier("home.switchBaby")
                .disabled(model.busy)
            }
        }
    }

    private var summaries: some View {
        VStack(spacing: 0) {
            summary(L.t("home.lastFeed"), entry: snapshot.entries.first { $0.kind.isFeeding })
            Rectangle().fill(Palette.line).frame(height: 1).accessibilityHidden(true)
            summary(L.t("home.lastDiaper"), entry: snapshot.entries.first { $0.kind == .diaper })
            if let mom = snapshot.entries.first(where: { $0.kind == .mom }) {
                Rectangle().fill(Palette.line).frame(height: 1).accessibilityHidden(true)
                summary(L.t("home.lastMom"), entry: mom).accessibilityIdentifier("home.lastMom")
            }
        }
        .padding(.horizontal, 14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Palette.line))
    }

    private func summary(_ label: String, entry: LogRecord?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(label).fixedSize()
                Spacer(minLength: 3)
                summaryValue(entry, horizontal: true).fixedSize()
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(label)
                summaryValue(entry, horizontal: false)
            }
        }
        .font(.caption)
        .foregroundStyle(Palette.muted)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func summaryValue(_ entry: LogRecord?, horizontal: Bool) -> some View {
        if let entry {
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            layout {
                Text(entry.summary)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
                Text(LogTime.stamp(entry, now: model.now, zone: model.zone)).monospacedDigit()
            }
        } else {
            Text(L.t("status.empty"))
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("home.feed")).font(.headline).accessibilityAddTraits(.isHeader)
            let columns = dynamicType.isAccessibilitySize ? 1 : 3
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: columns), spacing: 8) {
                ForEach(Array(baby.presets.amounts.enumerated()), id: \.offset) { index, amount in
                    Button {
                        save(.bottle, amount, baby)
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                amountText(amount)
                                Text(baby.presets.unit.label).font(.caption2)
                            }
                            VStack(spacing: 1) {
                                amountText(amount)
                                Text(baby.presets.unit.label).font(.caption2)
                            }
                        }
                    }
                    .buttonStyle(KeyStyle(prominent: true, height: 59))
                    .accessibilityLabel("\(MilkAmount.label(amount)) \(baby.presets.unit.label)")
                    .accessibilityIdentifier("home.preset.\(index)")
                }
            }

            let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Button(L.t("kind.nursing")) { save(.nursing, nil, baby) }
                    .accessibilityIdentifier("home.nursing")
                Button(L.t("home.other")) { showSheet(.amount) }
                    .accessibilityIdentifier("home.other")
            }
            .buttonStyle(KeyStyle(height: 45))
            layout {
                Button {
                    showSheet(.diaper)
                } label: {
                    ArrowLabel(text: L.t("home.diaper"))
                }
                .accessibilityIdentifier("home.diaper")
                Button {
                    showSheet(.mom)
                } label: {
                    ArrowLabel(text: L.t("kind.mom"))
                }
                .accessibilityIdentifier("home.mom")
            }
            .buttonStyle(KeyStyle())
        }
        .disabled(model.busy)
    }

    private func amountText(_ amount: String) -> some View {
        Text(MilkAmount.label(amount))
            .font(.title2.bold().monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var recent: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    recentTitle.fixedSize()
                    Spacer(minLength: 4)
                    recentLinks.fixedSize()
                }
                VStack(alignment: .leading, spacing: 1) {
                    recentTitle
                    recentLinks
                }
            }
            rule
            if snapshot.entries.isEmpty {
                Text(L.t("status.empty"))
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .accessibilityIdentifier("home.empty")
            }
            ForEach(Array(snapshot.entries.prefix(4).enumerated()), id: \.element.id) { index, entry in
                Button {
                    showSheet(.edit(entry))
                } label: {
                    RecordRow(entry: entry, now: model.now, zone: model.zone)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.record.\(index)")
                rule
            }
        }
    }

    private var recentTitle: some View { Text(L.t("home.recent")).font(.headline).accessibilityAddTraits(.isHeader) }

    private var recentLinks: some View {
        HStack(spacing: 2) {
            Button(L.t("history.title"), action: showHistory).accessibilityIdentifier("home.history")
            Button(L.t("editor.add")) { showSheet(.add(nil)) }.accessibilityIdentifier("home.backfill")
        }
        .buttonStyle(LinkStyle())
    }

    private var rule: some View { Rectangle().fill(Palette.line).frame(height: 1).accessibilityHidden(true) }
}

