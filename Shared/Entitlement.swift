import Foundation

struct Entitlement: Codable, Equatable, Sendable {
    var firstOpen: Date
    var trialClaimedAt: Date?
    var purchasedPro = false
    var proStartedAt: Date?

    var trialStart: Date {
        let localStart = proStartedAt ?? firstOpen
        return min(localStart, trialClaimedAt ?? localStart)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }

    func hasPro(at now: Date, free: Bool) -> Bool {
        free || purchasedPro || (now >= trialStart && now < trialEnd)
    }

    mutating func applyProReceipt(_ verifiedOwnership: Bool?) {
        if let verifiedOwnership { purchasedPro = verifiedOwnership }
    }

    mutating func applyTrialReceipt(_ purchasedOn: Date, revoked: Bool) {
        if revoked {
            if trialClaimedAt == purchasedOn { trialClaimedAt = nil }
        } else {
            trialClaimedAt = min(trialClaimedAt ?? purchasedOn, purchasedOn)
        }
    }
}

