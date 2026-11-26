import Foundation
import XCTest
@testable import BabyLog

final class StoreAndEntitlementTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let zone = TimeZone(secondsFromGMT: 0)!

    func testTrialStartsWhenPaidVersionFirstOpensAndEndsAtBoundary() {
        let firstOpen = Date(timeIntervalSince1970: 1_700_000_000)
        let paidStart = firstOpen.addingTimeInterval(120 * day)
        var entitlement = Entitlement(firstOpen: firstOpen, proStartedAt: paidStart)
        XCTAssertEqual(entitlement.trialStart, paidStart)
        XCTAssertTrue(entitlement.hasPro(at: paidStart, free: false))
        XCTAssertTrue(entitlement.hasPro(at: paidStart.addingTimeInterval(30 * day - 1), free: false))
        XCTAssertFalse(entitlement.hasPro(at: paidStart.addingTimeInterval(30 * day), free: false))
        XCTAssertTrue(entitlement.hasPro(at: paidStart.addingTimeInterval(90 * day), free: true))

        entitlement.applyTrialReceipt(paidStart.addingTimeInterval(10 * day), revoked: false)
        XCTAssertEqual(entitlement.trialStart, paidStart)
        let originalReceipt = paidStart.addingTimeInterval(-7 * day)
        entitlement.applyTrialReceipt(originalReceipt, revoked: false)
        XCTAssertEqual(entitlement.trialStart, originalReceipt)
        entitlement.applyTrialReceipt(originalReceipt, revoked: true)
        XCTAssertEqual(entitlement.trialStart, paidStart)
    }

    func testVerifiedPurchaseRetainsOfflineAccessAndRefundRemovesIt() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(31 * day)
        var entitlement = Entitlement(firstOpen: start)
        XCTAssertFalse(entitlement.hasPro(at: now, free: false))
        entitlement.applyProReceipt(true)
        entitlement.applyProReceipt(nil)
        XCTAssertTrue(entitlement.hasPro(at: now, free: false))
        entitlement.applyProReceipt(false)
        XCTAssertFalse(entitlement.hasPro(at: now, free: false))
    }

    func testStoreBootstrapRollbackUndoUnitAndLockedProfile() async throws {
        let store = try await LogStore.open(isolated: true)
        let first = try await store.bootstrap()
        let second = try await store.bootstrap()
        XCTAssertEqual(first.babies.count, 1)
        XCTAssertEqual(first.selectedID, second.selectedID)
        let other = try await store.apply(.addBaby("Kai", allowed: true)).snapshot.selectedID
        do {
            _ = try await store.apply(.addBaby("Locked", allowed: false))
            XCTFail("An expired trial must restrict new profiles.")
        } catch LogProblem.locked {}

        let _ = try await store.apply(.select(first.selectedID))
        let now = Date.now
        var invalid = LogDraft(kind: .bottle, date: now, zone: zone, unit: .ml)
        invalid.amount = "bad"
        do {
            _ = try await store.apply(.record(invalid, babyID: first.selectedID, editing: nil, now: now))
            XCTFail("Invalid input must fail.")
        } catch LogProblem.amount {}
        invalid.amount = "90"
        let write = try await store.apply(.record(invalid, babyID: first.selectedID, editing: nil, now: now))
        let id = try XCTUnwrap(write.inserted)
        XCTAssertEqual(write.snapshot.entries.count, 1)
        let changed = try await store.apply(.presets(first.selectedID, MilkPresets(unit: .oz)))
        XCTAssertEqual(changed.snapshot.selected?.presets.unit, .oz)
        XCTAssertEqual(changed.snapshot.entries.first?.unit, .ml)

        let switched = try await store.apply(.select(other))
        XCTAssertTrue(switched.snapshot.entries.isEmpty)
        let record = LogDraft(kind: .nursing, date: now, zone: zone)
        let secondWrite = try await store.apply(.record(record, babyID: other, editing: nil, now: now))
        let removed = try await store.apply(.delete(id: id, babyID: first.selectedID))
        XCTAssertEqual(removed.snapshot.entries.map(\.id), [try XCTUnwrap(secondWrite.inserted)])
        XCTAssertTrue(removed.snapshot.entriesByBaby[first.selectedID]?.isEmpty ?? true)
        XCTAssertEqual(removed.snapshot.babies.count, 2)
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testSevenDistinctDaysAcrossProfilesAndDaytimeReview() async throws {
        let store = try await LogStore.open(isolated: true)
        let initial = try await store.bootstrap()
        let second = try await store.apply(.addBaby("", allowed: true)).snapshot.selectedID
        let noon = Date(timeIntervalSince1970: 1_728_648_000)
        for offset in 0...5 {
            let date = noon.addingTimeInterval(-Double(offset) * day)
            let record = LogDraft(kind: .nursing, date: date, zone: zone)
            _ = try await store.apply(.record(record, babyID: initial.selectedID, editing: nil, now: noon))
        }
        let sameDay = LogDraft(kind: .diaper, date: noon, zone: zone)
        let six = try await store.apply(.record(sameDay, babyID: second, editing: nil, now: noon)).snapshot
        XCTAssertEqual(six.allDays.count, 6)
        XCTAssertFalse(six.earnedMilestone)

        let earlier = LogDraft(kind: .diaper, date: noon.addingTimeInterval(-6 * day), zone: zone)
        let seven = try await store.apply(.record(earlier, babyID: second, editing: nil, now: noon))
        XCTAssertTrue(seven.snapshot.earnedMilestone)
        let calendar = LogTime.calendar(zone)
        let start = calendar.startOfDay(for: noon)
        XCTAssertFalse(seven.snapshot.shouldAskForReview(at: start.addingTimeInterval(12 * 3600), zone: zone))
        let shared = try await store.apply(.shareHandoff).snapshot
        XCTAssertFalse(shared.shouldAskForReview(at: start.addingTimeInterval(2 * 3600), zone: zone))
        XCTAssertTrue(shared.shouldAskForReview(at: start.addingTimeInterval(12 * 3600), zone: zone))
        let rated = try await store.apply(.requestReview).snapshot
        XCTAssertFalse(rated.shouldAskForReview(at: start.addingTimeInterval(12 * 3600), zone: zone))
        let seen = try await store.apply(.seeMilestone).snapshot
        XCTAssertTrue(seen.milestoneSeen)
        let deleted = try await store.apply(.delete(id: try XCTUnwrap(seven.inserted), babyID: second))
        XCTAssertTrue(deleted.snapshot.earnedMilestone)
    }
}

