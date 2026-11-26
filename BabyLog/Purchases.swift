import Foundation
import Security
import StoreKit
import SwiftUI

actor EntitlementStorage {
    private let query: [String: String] = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "com.hgsldswk.babylog.entitlement",
        kSecAttrAccount as String: "purchase-state"
    ]
    private var value: Entitlement?

    func start(at now: Date, free: Bool) throws -> Entitlement {
        var saved = try read() ?? Entitlement(firstOpen: now)
        if !free && saved.proStartedAt == nil { saved.proStartedAt = now }
        try write(saved)
        return saved
    }

    func apply(pro: Bool? = nil, trial: Date? = nil, trialRevoked: Bool = false) throws -> Entitlement {
        guard var saved = value else { throw LogProblem.missing }
        saved.applyProReceipt(pro)
        if let trial { saved.applyTrialReceipt(trial, revoked: trialRevoked) }
        if saved != value { try write(saved) }
        return saved
    }

    private func read() throws -> Entitlement? {
        if let value { return value }
        var request: [String: Any] = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw LogProblem.missing }
        return try JSONDecoder().decode(Entitlement.self, from: bytes)
    }

    private func write(_ entitlement: Entitlement) throws {
        let bytes = try JSONEncoder().encode(entitlement)
        let changes = [kSecValueData as String: bytes]
        var status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var attributes: [String: Any] = query
            attributes[kSecValueData as String] = bytes
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LogProblem.missing }
        value = entitlement
    }
}

@MainActor
final class Purchases: ObservableObject {
    static let proID = "com.hgsldswk.babylog.pro"
    static let trialID = "com.hgsldswk.babylog.trial"

    @Published private(set) var entitlement: Entitlement?
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published var message: String?
    private let storage = EntitlementStorage()
    private var listener: Task<Void, Never>?
    private var starting = false
    private var loading = false

    var pro: Product? { products.first { $0.id == Self.proID } }
    var trial: Product? { products.first { $0.id == Self.trialID } }

    func canAdd(at now: Date) -> Bool { Launch.isFree || entitlement?.hasPro(at: now, free: false) == true }

    func start() async {
        guard entitlement == nil, !starting else { return }
        starting = true
        defer { starting = false }
        let now = Launch.now
        if Launch.testing {
            let age: TimeInterval = Launch.arguments.contains("-expired") ? 31 : Launch.arguments.contains("-near-expiry") ? 29 : 0
            let began = now.addingTimeInterval(-age * 86_400)
            entitlement = Entitlement(firstOpen: began, purchasedPro: Launch.arguments.contains("-purchased"), proStartedAt: began)
            return
        }
        do {
            entitlement = try await storage.start(at: now, free: Launch.isFree)
            guard !Launch.isFree else { return }
            if listener == nil {
                listener = Task { [weak self] in
                    for await update in StoreKit.Transaction.updates {
                        if Task.isCancelled { return }
                        guard case .verified(let transaction) = update else { continue }
                        await self?.accept(transaction)
                    }
                }
            }
            await refresh()
        } catch {
            message = L.t("pay.unavailable")
        }
    }

    func load() async {
        guard !Launch.isFree, !Launch.testing, !loading, pro == nil || trial == nil else { return }
        loading = true
        defer { loading = false }
        if entitlement == nil { await start() }
        do {
            message = nil
            products = try await Product.products(for: [Self.proID, Self.trialID])
            if pro == nil || trial == nil { message = L.t("pay.unavailable") }
        } catch {
            message = L.t("pay.unavailable")
        }
    }

    func buy(_ product: Product?) async {
        guard !busy, !Launch.isFree, !Launch.testing, let product else { return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await accept(transaction)
            case .success(.unverified):
                message = L.t("pay.verify")
            case .pending:
                message = L.t("pay.pending")
            case .userCancelled:
                break
            @unknown default:
                message = L.t("pay.unavailable")
            }
        } catch {
            message = L.t("pay.failed")
        }
    }

    func restore() async {
        guard !busy, !Launch.isFree else { return }
        if Launch.testing { message = L.t("pay.restoreDone"); return }
        busy = true
        defer { busy = false }
        do {
            try await AppStore.sync()
            if await refresh(authoritative: true) { message = L.t("pay.restoreDone") }
        } catch {
            message = L.t("pay.restoreFailed")
        }
    }

    private func accept(_ transaction: StoreKit.Transaction) async {
        do {
            switch transaction.productID {
            case Self.proID:
                entitlement = try await storage.apply(pro: transaction.revocationDate == nil)
            case Self.trialID:
                entitlement = try await storage.apply(trial: transaction.originalPurchaseDate,
                                                      trialRevoked: transaction.revocationDate != nil)
            default:
                return
            }
            await transaction.finish()
        } catch {
            message = L.t("pay.verify")
        }
    }

    @discardableResult
    private func refresh(authoritative: Bool = false) async -> Bool {
        let latestPro = await StoreKit.Transaction.latest(for: Self.proID)
        let latestTrial = await StoreKit.Transaction.latest(for: Self.trialID)
        var verifiedPro: Bool? = authoritative && latestPro == nil ? false : nil
        if case let .verified(transaction)? = latestPro { verifiedPro = transaction.revocationDate == nil }
        var trialDate: Date?
        var trialRevoked = false
        if case let .verified(transaction)? = latestTrial {
            trialDate = transaction.originalPurchaseDate
            trialRevoked = transaction.revocationDate != nil
        }
        do {
            entitlement = try await storage.apply(pro: verifiedPro, trial: trialDate, trialRevoked: trialRevoked)
            return true
        } catch {
            message = L.t("pay.verify")
            return false
        }
    }
}

