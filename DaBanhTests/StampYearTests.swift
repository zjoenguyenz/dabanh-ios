import XCTest
@testable import DaBanh

/// H1 (AUDIT.md): the year rule for playlist "DD/MM HH:MM" stamps.
/// The five rows are the audit's ported cases; before this fix rows
/// 1, 2, 4 and 5 failed.
final class StampYearTests: XCTestCase {

    private static let ict: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    private func ict(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        Self.ict.date(from: DateComponents(year: y, month: mo, day: d,
                                           hour: h, minute: mi, second: 0))!
    }

    // Row 1: a New Year's Eve match read just after midnight stays live.
    func testNewYearsEveKickoffReadAfterMidnight() {
        let now = ict(2027, 1, 1, 0, 30)
        let title = "23:00 31/12 ⚽ A vs B"
        XCTAssertEqual(KickoffParser.parse(from: title, now: now), ict(2026, 12, 31, 23, 0))
        let channel = Channel(title: title, logo: "", group: "", url: "https://x/1.m3u8",
                              kickoff: KickoffParser.parse(from: title, now: now),
                              leagueRank: 1)
        XCTAssertEqual(LeagueClassifier.bucket(of: channel, now: now), 0)
    }

    // Row 2: a New Year fixture listed in a leap-year December.
    func testNewYearFixtureListedInLeapYearDecember() {
        XCTAssertEqual(KickoffParser.parse(from: "20:00 02/01 ⚽ A vs B",
                                           now: ict(2028, 12, 30, 12, 0)),
                       ict(2029, 1, 2, 20, 0))
    }

    // Row 3: the same in a non-leap December (already correct before).
    func testNewYearFixtureListedInNonLeapDecember() {
        XCTAssertEqual(KickoffParser.parse(from: "20:00 02/01 ⚽ A vs B",
                                           now: ict(2026, 12, 30, 12, 0)),
                       ict(2027, 1, 2, 20, 0))
    }

    // Row 4: an Updated stamp 40 days old reads as old (stale), not future.
    func testUpdatedStampFortyDaysOldIsInThePast() {
        let now = ict(2026, 11, 23, 12, 0)
        let stamp = UpdatedStamp.parse("#EXTM3U\n#EXTINF:-1, Updated 14/10 06:36", now: now)
        XCTAssertEqual(stamp, ict(2026, 10, 14, 6, 36))
        XCTAssertGreaterThan(now.timeIntervalSince(stamp!), 45 * 60)
    }

    // Row 5: a 31/12 stamp read just after midnight is 20 minutes old.
    func testUpdatedStampAcrossNewYear() {
        let now = ict(2027, 1, 1, 0, 10)
        let stamp = UpdatedStamp.parse("#EXTM3U\n#EXTINF:-1, Updated 31/12 23:50", now: now)
        XCTAssertEqual(stamp, ict(2026, 12, 31, 23, 50))
        XCTAssertEqual(now.timeIntervalSince(stamp!), 20 * 60, accuracy: 0.5)
    }
}
