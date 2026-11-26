import Foundation

enum Launch {
    static let freePeriod = false

    static var arguments: [String] {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-ui-testing") ? args : []
        #else
        return []
        #endif
    }

    static var testing: Bool { arguments.contains("-ui-testing") }
    static var isFree: Bool {
        let forced = ["-paid-mode", "-paywall", "-expired", "-purchased", "-near-expiry"]
        return (freePeriod || arguments.contains("-free-mode")) && !forced.contains(where: arguments.contains)
    }
    static var demo: Bool { arguments.contains("-demo") }
    static var zone: TimeZone { demo ? TimeZone(secondsFromGMT: 8 * 3600)! : .current }
    static var now: Date {
        demo ? ISO8601DateFormatter().date(from: "2026-11-19T02:18:00+08:00")! : .now
    }
    static var productID: String? {
        if arguments.contains("-test-store-id") { return "0000000000" }
        guard let value = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return value
    }
    static var downloadURL: URL? {
        productID.flatMap { URL(string: "https://apps.apple.com/app/id\($0)") }
    }
}

enum L {
    static func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }
    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: args)
    }
}

