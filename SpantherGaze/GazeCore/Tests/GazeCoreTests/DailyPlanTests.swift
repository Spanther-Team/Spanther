import XCTest
@testable import GazeCore

final class DailyPlanTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Almaty")!
        return c
    }()

    func date(_ day: Int, _ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 12, day: day, hour: hour))!
    }

    func testEveryDayAlternatesAndFitsTenMinutes() {
        var previous: [PlanMode] = []
        for n in 1...DailyPlan.length {
            let d = DailyPlan.day(n, history: PlanState())
            XCTAssertEqual(d.number, n)
            XCTAssertGreaterThanOrEqual(d.minutes, 6, "day \(n)")
            XCTAssertLessThanOrEqual(d.minutes, 10, "day \(n)")
            let modes = d.blocks.filter { !$0.control }.map(\.mode)
            XCTAssertEqual(Set(modes).count, modes.count, "no mode twice in a day")
            XCTAssertNotEqual(modes, previous, "day \(n) is not the day before")
            previous = modes
        }
    }

    func testControlDaysAreTheSameEveryWeek() {
        let checks = (1...30).filter { DailyPlan.day($0, history: PlanState()).isControl }
        XCTAssertEqual(checks, [1, 8, 15, 22, 29])
        let one = DailyPlan.day(1, history: PlanState()).blocks.filter(\.control)
        let four = DailyPlan.day(22, history: PlanState()).blocks.filter(\.control)
        XCTAssertEqual(one, four)
        XCTAssertEqual(one.map(\.mode), [.moles, .fishing])
        XCTAssertTrue(one.allSatisfy { $0.level == 3 && $0.seconds == 60 })
    }

    func testDensityGrowsAndHoldsAfterAPoorPlay() {
        XCTAssertEqual(DailyPlan.level(.moles, day: 1, history: PlanState()), 1)
        XCTAssertEqual(DailyPlan.level(.moles, day: 4, history: PlanState()), 2)
        XCTAssertEqual(DailyPlan.level(.moles, day: 30, history: PlanState()), 10)
        let poor = PlanState(days: [PlanDayRecord(number: 9, date: date(9, 9),
                                                  blocks: [PlanBlockResult(mode: .moles, level: 3, control: false, accuracy: 0.5)])])
        XCTAssertEqual(DailyPlan.level(.moles, day: 13, history: poor), 3, "held at 3 instead of 5")
        let bad = PlanState(days: [PlanDayRecord(number: 9, date: date(9, 9),
                                                 blocks: [PlanBlockResult(mode: .moles, level: 3, control: false, accuracy: 0.3)])])
        XCTAssertEqual(DailyPlan.level(.moles, day: 13, history: bad), 2)
        // The control check does not move the level.
        let check = PlanState(days: [PlanDayRecord(number: 8, date: date(8, 9),
                                                   blocks: [PlanBlockResult(mode: .moles, level: 3, control: true, accuracy: 0.1)])])
        XCTAssertEqual(DailyPlan.level(.moles, day: 13, history: check), 5)
        XCTAssertEqual(DailyPlan.level(.circles, day: 10, history: PlanState()), 1)
        XCTAssertEqual(DailyPlan.level(.circles, day: 20, history: PlanState()), 2)
    }

    func testOneDayPerCalendarDay() {
        var s = PlanState()
        XCTAssertEqual(DailyPlan.today(s, now: date(1, 9), calendar: cal).number, 1)
        s.days.append(PlanDayRecord(number: 1, date: date(1, 9), blocks: []))
        let same = DailyPlan.today(s, now: date(1, 20), calendar: cal)
        XCTAssertEqual(same.number, 1)
        XCTAssertTrue(same.doneToday)
        let next = DailyPlan.today(s, now: date(3, 8), calendar: cal)
        XCTAssertEqual(next.number, 2, "a missed day does not skip the plan")
        XCTAssertFalse(next.doneToday)
    }

    func testControlChecksReadBack() {
        let s = PlanState(days: [
            PlanDayRecord(number: 1, date: date(1, 9), blocks: [
                PlanBlockResult(mode: .moles, level: 3, control: true, accuracy: 0.6, reactionSec: 1.1),
                PlanBlockResult(mode: .fishing, level: 3, control: true, accuracy: 0.8, reactionSec: 0.9),
                PlanBlockResult(mode: .meteors, level: 1, control: false, accuracy: 1)]),
            PlanDayRecord(number: 2, date: date(2, 9), blocks: [PlanBlockResult(mode: .moles, level: 1, control: false, accuracy: 1)]),
        ])
        let c = DailyPlan.controls(s)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].focus, 70)
        XCTAssertEqual(c[0].molesReactionSec ?? 0, 1.1, accuracy: 1e-9)
        XCTAssertEqual(PlanState.from(json: s.json()), s)
        XCTAssertEqual(PlanState.from(json: "nonsense"), PlanState())
    }

    func testFocusByTimeWaitsForTwoWeeks() {
        var e: [FocusEntry] = []
        for d in 1...10 { e.append(FocusEntry(date: date(d, 9), mode: .moles, focus: 80)) }
        for d in 1...10 { e.append(FocusEntry(date: date(d, 19), mode: .moles, focus: 60)) }
        let f = FocusByTime(e, calendar: cal)
        XCTAssertFalse(f.ready)
        XCTAssertEqual(f.daysLeft, 4)
        XCTAssertNil(f.best)
    }

    func testFocusByTimeFindsTheMorning() {
        var e: [FocusEntry] = []
        for d in 1...15 {
            // Mornings on moles, evenings on the harder fishing: the mode's own mean is what each play is held to.
            e.append(FocusEntry(date: date(d, 9), mode: .moles, focus: 85))
            e.append(FocusEntry(date: date(d, 19), mode: .moles, focus: 70))
            e.append(FocusEntry(date: date(d, 19), mode: .fishing, focus: 40))
        }
        let f = FocusByTime(e, calendar: cal)
        XCTAssertTrue(f.ready)
        XCTAssertEqual(f.spanDays, 15)
        XCTAssertEqual(f.best, .morning)
        XCTAssertNil(f.bands.first { $0.band == .day }?.focus)
        XCTAssertGreaterThan(f.bands[0].focus ?? 0, f.bands[2].focus ?? 100)
    }

    func testFocusByTimeEvenDaySaysNoBest() {
        var e: [FocusEntry] = []
        for d in 1...15 {
            e.append(FocusEntry(date: date(d, 9), mode: .moles, focus: 72))
            e.append(FocusEntry(date: date(d, 14), mode: .moles, focus: 70))
        }
        let f = FocusByTime(e, calendar: cal)
        XCTAssertTrue(f.ready)
        XCTAssertNil(f.best)
    }

    func testSoftLimitAfterTwentyMinutesThenEveryFive() {
        var g = PlayTimeGuard(day: "2026-12-01")
        g.add(19 * 60, day: "2026-12-01")
        XCTAssertFalse(g.due)
        g.add(60, day: "2026-12-01")
        XCTAssertTrue(g.due)
        g.reminded()
        XCTAssertFalse(g.due)
        g.add(299, day: "2026-12-01")
        XCTAssertFalse(g.due)
        g.add(1, day: "2026-12-01")
        XCTAssertTrue(g.due)
        g.add(10, day: "2026-12-02")
        XCTAssertFalse(g.due, "a new day starts from zero")
        XCTAssertEqual(g.playedSec, 10)
        XCTAssertEqual(PlayTimeGuard.dayKey(date(5, 23), calendar: cal), "2026-12-05")
    }

    func testMeteorsStartOnThePlansLevel() throws {
        let c = try BalanceTests.config()
        let m = GameModel(config: c, screen: Vec2(844, 390), marginPt: 30, startLevel: 4, seed: 1)
        XCTAssertEqual(m.level, 4)
        XCTAssertEqual(m.d, c.difficulty(level: 4), accuracy: 1e-9)
        XCTAssertEqual(GameModel(config: c, screen: Vec2(844, 390), marginPt: 30, startLevel: 99, seed: 1).level, c.levelCount)
    }
}
