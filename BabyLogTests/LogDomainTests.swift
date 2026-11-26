import CoreImage
import Foundation
import XCTest
@testable import BabyLog

final class LogDomainTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let baby = UUID()

    func testMilkPresetsAndStrictDecimalValidation() throws {
        XCTAssertEqual(MilkUnit.preferred(locale: Locale(identifier: "zh_TW")), .ml)
        XCTAssertEqual(MilkUnit.preferred(locale: Locale(identifier: "en_US")), .oz)
        XCTAssertEqual(MilkUnit.ml.defaults, ["60", "90", "120"])
        XCTAssertEqual(MilkUnit.oz.defaults, ["2", "3", "4"])
        XCTAssertEqual(try MilkAmount.validated(" 90.250 "), "90.25")
        XCTAssertEqual(try MilkAmount.validated("2,5", locale: Locale(identifier: "fr_FR")), "2.5")
        for invalid in ["", "0", "-90", "42abc", "2.0001", "1e2", "0,000", "10000", "NaN"] {
            XCTAssertThrowsError(try MilkAmount.validated(invalid, locale: Locale(identifier: "en_US_POSIX")), invalid)
        }
        XCTAssertThrowsError(try MilkPresets.checked(unit: .ml, amounts: ["60", "60.0", "120"]))
    }

    func testCodesRoundTripAndRejectMissingOrExtraFields() throws {
        let expanded = try MilkPresets(code: "\nBABY1/OZ/1.5-2-3-4-5-6\n")
        XCTAssertEqual(expanded.code, "BABY1/OZ/1.5-2-3-4-5-6")
        XCTAssertEqual(try MilkPresets(code: "BABY1/ML/60-90-120").unit, .ml)
        for code in ["BABY2/ML/60-90-120", "BABY1/L/1-2-3", "BABY1/ML/90-120",
                     "BABY1/ML/1-2-3-4-5-6-7", "BABY1/OZ/1-2-3/NAME", "BABY1/ML/60--90-120"] {
            XCTAssertThrowsError(try MilkPresets(code: code), code)
        }
    }

    func testRecordKindsPreserveOnlyApplicableFields() throws {
        let now = timestamp("2026-11-19T02:18:00Z")
        var draft = LogDraft(kind: .bottle, date: now, zone: utc, unit: .oz)
        draft.amount = "2.25"
        draft.side = .left
        let bottle = try draft.record(babyID: baby, now: now)
        XCTAssertEqual(bottle.amount, "2.25")
        XCTAssertEqual(bottle.unit, .oz)
        XCTAssertNil(bottle.side)

        draft.kind = .nursing
        let nursing = try draft.record(babyID: baby, now: now, previous: bottle)
        XCTAssertEqual(nursing.id, bottle.id)
        XCTAssertEqual(nursing.createdAt, bottle.createdAt)
        XCTAssertNil(nursing.amount)
        XCTAssertNil(nursing.unit)
        XCTAssertEqual(nursing.side, .left)

        draft.kind = .diaper
        for type in Diaper.allCases {
            draft.diaper = type
            let record = try draft.record(babyID: baby, now: now)
            XCTAssertEqual(record.diaper, type)
            XCTAssertNil(record.side)
            XCTAssertNil(record.amount)
        }
        draft.date = now.addingTimeInterval(1)
        XCTAssertThrowsError(try draft.record(babyID: baby, now: now))
    }

    func testMidnightAndChangingZonesKeepOriginalEventDay() throws {
        let now = timestamp("2026-11-19T08:18:00Z")
        let first = timestamp("2026-11-19T00:35:00Z")
        let second = timestamp("2026-11-18T23:46:00Z")
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(LogTime.day(first, zone: utc), "2026-11-19")
        XCTAssertEqual(LogTime.day(second, zone: utc), "2026-11-18")
        let entry = try make(.nursing, date: first, now: now)
        XCTAssertEqual(entry.day, "2026-11-19")
        XCTAssertEqual(LogTime.day(entry.date, zone: zone), "2026-11-18")
        var edited = LogDraft(record: entry)
        edited.zone = zone
        XCTAssertEqual(try edited.record(babyID: baby, now: now, previous: entry).day, "2026-11-18")
    }

    func testDaylightSavingGapAndRepeatedHour() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let beforeGap = timestamp("2026-03-08T06:59:00Z")
        let day = LogTime.calendar(zone).startOfDay(for: beforeGap)
        XCTAssertTrue(LogTime.resolveWallTime(on: day, hour: 2, minute: 30, in: zone).isEmpty)
        let first = timestamp("2026-11-01T05:30:00Z")
        let choices = Array(Set(LogTime.wallTimes(first, in: zone))).sorted()
        XCTAssertEqual(choices, [first, first.addingTimeInterval(3600)])
        XCTAssertTrue(choices.allSatisfy { LogTime.day($0, zone: zone) == "2026-11-01" })
    }

    func testHandoffUsesElapsedTwelveHoursAndBalancesBothCategories() throws {
        let now = timestamp("2026-11-19T02:18:00Z")
        let recentFeeds = try (1...5).map { try make(.nursing, date: now.addingTimeInterval(Double(-$0) * 60), now: now) }
        let diaper = try make(.diaper, date: now.addingTimeInterval(-12 * 3600), now: now)
        let older = try make(.diaper, date: diaper.date.addingTimeInterval(-1), now: now)
        let candidates = Handoff.recent([older, diaper] + Array(recentFeeds.reversed()), now: now)
        XCTAssertEqual(candidates.map(\.id), recentFeeds.map(\.id) + [diaper.id])
        XCTAssertEqual(Handoff.initial(candidates, balance: true), Set(recentFeeds.prefix(3).map(\.id) + [diaper.id]))
        XCTAssertEqual(Handoff.initial(candidates, balance: false), Set(recentFeeds.prefix(4).map(\.id)))
        XCTAssertEqual(Handoff.initial([], balance: true), [])
        let privateText = Handoff.text([diaper], now: now, zone: utc)
        XCTAssertEqual(privateText.components(separatedBy: "\n").count, 2)
        XCTAssertFalse(privateText.contains(diaper.babyID.uuidString))
        XCTAssertFalse(privateText.contains(older.id.uuidString))
    }

    func testSortBreaksTiesByCreationAndID() throws {
        let date = timestamp("2026-11-18T18:00:00Z")
        var first = try make(.nursing, date: date, now: date)
        var second = try make(.diaper, date: date, now: date.addingTimeInterval(1))
        XCTAssertEqual([first, second].sorted(by: LogRecord.newest).first?.id, second.id)
        second.createdAt = first.createdAt
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual([first, second].sorted(by: LogRecord.newest).first?.id, second.id)
    }

    func testCSVIncludesBothBoundariesAndEscapesThreeLanguages() throws {
        let now = timestamp("2026-11-19T02:18:00Z")
        let today = try make(.nursing, date: now, now: now)
        let yesterday = try make(.diaper, date: now.addingTimeInterval(-5 * 3600), now: now)
        let outside = try make(.diaper, date: now.addingTimeInterval(-48 * 3600), now: now)
        for title in ["时间", "時間", "Time, recorded"] {
            let data = try LogCSV.encode([outside, today, yesterday], from: yesterday.day, through: today.day) {
                $0 == "csv.time" ? title : $0
            }
            let csv = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(csv.contains("\"" + title + "\""))
            XCTAssertTrue(csv.contains("2026-11-18"))
            XCTAssertTrue(csv.contains("2026-11-19"))
            XCTAssertFalse(csv.contains("2026-11-17"))
            XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 4)
            XCTAssertFalse(csv.contains(baby.uuidString))
        }
        XCTAssertThrowsError(try LogCSV.encode([], from: "2026-11-19", through: "2026-11-18"))
    }

    func testDownloadCodeRoundTripWithCIDetector() throws {
        let link = try XCTUnwrap(URL(string: "https://apps.apple.com/app/id1234567890"))
        let qr = try XCTUnwrap(QRCode.make(link))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: qr)).compactMap { $0 as? CIQRCodeFeature }
        XCTAssertEqual(features.first?.messageString, link.absoluteString)
    }

    func testMomMedRecordStorageRecentHandoffAndCSV() throws {
        let now = timestamp("2026-11-19T02:18:00Z")
        var draft = LogDraft(kind: .mom, date: now.addingTimeInterval(-3600), zone: utc)
        draft.medName = " Ibuprofen "
        draft.medNote = "1 tablet"
        draft.side = .left
        let mom = try draft.record(babyID: baby, now: now)
        XCTAssertEqual(mom.medName, "Ibuprofen")
        XCTAssertEqual(mom.medNote, "1 tablet")
        XCTAssertNil(mom.amount)
        XCTAssertNil(mom.side)
        XCTAssertEqual(mom.detail, "Ibuprofen · 1 tablet")
        XCTAssertFalse(LogKind.mom.isFeeding)
        XCTAssertTrue(LogKind.nursing.isFeeding)

        XCTAssertEqual(LogSchemaV1.LogEntry(mom).value, mom)
        var milk = LogDraft(kind: .bottle, date: now, zone: utc)
        milk.amount = "90"
        let bottle = try milk.record(babyID: baby, now: now)
        XCTAssertEqual(LogSchemaV1.LogEntry(bottle).value, bottle)

        for (name, note) in [("", ""), ("   ", "x"), (String(repeating: "a", count: 31), ""), ("Iron", String(repeating: "b", count: 21))] {
            var bad = LogDraft(kind: .mom, date: now, zone: utc)
            bad.medName = name
            bad.medNote = note
            XCTAssertThrowsError(try bad.record(babyID: baby, now: now)) { XCTAssertEqual($0 as? LogProblem, .medName) }
        }

        var second = LogDraft(kind: .mom, date: now.addingTimeInterval(-60), zone: utc)
        second.medName = "Iron"
        let iron = try second.record(babyID: baby, now: now)
        var older = LogDraft(kind: .mom, date: now.addingTimeInterval(-7200), zone: utc)
        older.medName = "Iron"
        let ironOld = try older.record(babyID: baby, now: now)
        XCTAssertEqual(MomMed.recent([mom, ironOld, bottle, iron]), ["Iron", "Ibuprofen"])
        XCTAssertEqual(MomMed.recent([mom, iron], limit: 1), ["Iron"])

        let diaper = try make(.diaper, date: now.addingTimeInterval(-30), now: now)
        let feeds = try (1...4).map { try make(.nursing, date: now.addingTimeInterval(Double(-10 * $0)), now: now) }
        let picked = Handoff.initial(feeds + [diaper, mom], balance: true)
        XCTAssertTrue(picked.contains(mom.id))
        XCTAssertTrue(picked.contains(diaper.id))
        XCTAssertTrue(picked.contains(feeds[0].id))

        let csv = try XCTUnwrap(String(data: try LogCSV.encode([mom], from: mom.day, through: mom.day) { $0 }, encoding: .utf8))
        XCTAssertTrue(csv.contains("\"csv.med\",\"csv.medNote\""))
        XCTAssertTrue(csv.contains("\"Ibuprofen\",\"1 tablet\""))
    }

    private func make(_ type: LogKind, date: Date, now: Date) throws -> LogRecord {
        try LogDraft(kind: type, date: date, zone: utc).record(babyID: baby, now: now)
    }

    private func timestamp(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }
}

