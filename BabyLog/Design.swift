import SwiftUI
import UIKit

enum Palette {
    static let background = adaptive(0xF3F8F4, 0x14211E)
    static let surface = adaptive(0xFFFFFF, 0x1E302A)
    static let raised = adaptive(0xE8F1EB, 0x253B33)
    static let line = adaptive(0xCCD9D0, 0x40554C)
    static let ink = adaptive(0x1F3128, 0xF0F6F2)
    static let muted = adaptive(0x52675D, 0xA9BEB5)
    static let link = adaptive(0x236048, 0xAEE4CC)
    static let accent = Color(uiColor: rgb(0xAEE4CC))
    static let onAccent = Color(uiColor: rgb(0x142F25))
    static let paper = Color(uiColor: rgb(0xF3F8F4))
    static let paperInk = Color(uiColor: rgb(0x1F3128))
    static let paperMuted = Color(uiColor: rgb(0x52675D))
    static let paperLine = Color(uiColor: rgb(0xCCD9D0))

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { rgb($0.userInterfaceStyle == .dark ? dark : light) })
    }

    private static func rgb(_ value: UInt32) -> UIColor {
        UIColor(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                blue: Double(value & 255) / 255, alpha: 1)
    }
}

struct KeyStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 54
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Palette.onAccent : Palette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(prominent ? Palette.accent : Palette.raised, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(prominent ? .clear : Palette.line))
            .contentShape(RoundedRectangle(cornerRadius: 13))
            .opacity(isEnabled ? (configuration.isPressed ? 0.73 : 1) : 0.45)
    }
}

struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.link)
            .padding(.horizontal, 4)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct ArrowLabel: View {
    var text: String

    var body: some View {
        HStack {
            Text(text)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 5)
    }
}

struct SheetHeader: View {
    var title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .center) {
            Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 6)
            Button(L.t("action.done")) { dismiss() }
                .buttonStyle(LinkStyle())
                .accessibilityIdentifier("sheet.done")
        }
    }
}

struct RecordRow: View {
    var entry: LogRecord
    var now: Date
    var zone: TimeZone

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                stamp
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                kindAndDetail
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 3) {
                stamp
                kindAndDetail
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var stamp: some View {
        Text(LogTime.stamp(entry, now: now, zone: zone))
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.muted)
    }

    private var kindAndDetail: some View {
        HStack(spacing: 8) {
            Text(entry.kind.label)
            if !entry.detail.isEmpty { Text(entry.detail).fontWeight(.semibold) }
        }
        .font(.subheadline)
        .foregroundStyle(Palette.ink)
    }
}

struct InlineProblem: View {
    var message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("feedback.error")
        }
    }
}

