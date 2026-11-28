import Foundation

/// Today's plan day while it is played: its blocks, which one is next, how the played ones went.
struct PlanRun: Equatable {
    var day: PlanDay
    var index = 0
    var results: [PlanBlockResult] = []
    /// Whose day it is: another player's run does not go on under someone else.
    var owner: UUID?
    var finished: Bool { index >= day.blocks.count }
}

// The 30-day plan and the soft daily limit (Aziz, 2026-11-28). The rules are in GazeCore (`DailyPlan`,
// `FocusByTime`, `PlayTimeGuard`); this wires them to the modes. A clinic child and the CI bots are left out: the
// plan is for players.
extension AppModel {
    private static let planKey = "plan.v1"
    private var playTimeKey: String { "playtime.v1.\(profiles.active?.id.uuidString ?? "phone")" }

    /// The plan counts for this play: a player (or the phone's one player), not a clinic child or a bot.
    var planCounts: Bool { clinic.playingID == nil && autoplay == nil }

    /// The block to play now, if a day is under way for this player.
    var planBlock: PlanBlock? {
        guard let r = planRun, r.owner == profiles.active?.id, !r.finished else { return nil }
        return r.day.blocks[r.index]
    }

    /// The meteors' starting level when the plan opened them.
    var planMeteorLevel: Int? {
        guard planBlockOpen, let b = planBlock, b.mode == .meteors else { return nil }
        return b.level
    }

    /// Today's plan day: its number, and whether it was already played today.
    var planToday: (number: Int, doneToday: Bool) { DailyPlan.today(plan, now: Date()) }

    /// The plan is over: all 30 days played.
    var planComplete: Bool { (plan.days.last?.number ?? 0) >= DailyPlan.length }

    /// The day to show: the one being played, else today's.
    var planDayShown: PlanDay {
        if let r = planRun, r.owner == profiles.active?.id { return r.day }
        return DailyPlan.day(planToday.number, history: plan)
    }

    func reloadPlan() {
        #if DEBUG
        if demoReport == "plan" {
            plan = Self.demoPlan()
            return
        }
        #endif
        let raw = profiles.active != nil ? profiles.progress(Self.planKey) : UserDefaults.standard.string(forKey: Self.planKey)
        plan = PlanState.from(json: raw)
        if planRun?.owner != profiles.active?.id { planRun = nil }
        playTime = (UserDefaults.standard.string(forKey: playTimeKey)?.data(using: .utf8))
            .flatMap { try? JSONDecoder().decode(PlayTimeGuard.self, from: $0) } ?? PlayTimeGuard(day: "")
    }

    private func savePlan() {
        #if DEBUG
        if demoReport != nil { return }
        #endif
        guard let j = plan.json() else { return }
        if profiles.active != nil { profiles.setProgress(Self.planKey, j) } else { UserDefaults.standard.set(j, forKey: Self.planKey) }
    }

    func openPlan() { route = .plan }

    /// «Начать» on the plan: today's day starts (or goes on) with its next block, by eye where the phone tracks
    /// faces. Each mode calibrates first when the session has no calibration yet.
    func playPlanBlock() {
        if planBlock == nil {
            let t = planToday
            guard !t.doneToday, !planComplete else { return }
            planRun = PlanRun(day: DailyPlan.day(t.number, history: plan), owner: profiles.active?.id)
        }
        guard let b = planBlock else { return }
        planBlockOpen = true
        let byEye = eyeTrackingSupported
        switch b.mode {
        case .moles: openArcade(.moles, byEye: byEye)
        case .fishing: openArcade(.fishing, byEye: byEye)
        case .circles: openWinkBeat(byEye: byEye)
        case .meteors:
            if byEye {
                playMeteorsByEye()
            } else {
                mode = .touch
                route = .game
            }
        }
    }

    /// A meteor level ended (GameScene): for the plan, the focus by time of day and the rest reminder.
    func meteorLevelEnded(_ level: Int, ratio: Double) {
        // After the level's celebration (3.4 s).
        playEnded(.meteors, accuracy: ratio, reactionSec: nil, after: 3.6)
    }

    /// A round, a song or a meteor level ended. Its focus goes into the log for the time of day; when it was the
    /// plan's block, the plan takes its result and, after `delay` (the results or the celebration), comes back.
    func playEnded(_ m: PlanMode, accuracy: Double, reactionSec: Double?, after delay: Double) {
        guard planCounts else { return }
        let result = PlanBlockResult(mode: m, level: 0, control: false, accuracy: accuracy, reactionSec: reactionSec)
        plan.add(FocusEntry(date: Date(), mode: m, focus: result.focus))
        if planBlockOpen, var r = planRun, let b = planBlock, b.mode == m {
            planBlockOpen = false
            r.results.append(PlanBlockResult(mode: m, level: b.level, control: b.control, accuracy: accuracy,
                                             reactionSec: reactionSec))
            r.index += 1
            if r.finished { plan.days.append(PlanDayRecord(number: r.day.number, date: Date(), blocks: r.results)) }
            planRun = r
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.closePlayForPlan() }
        } else {
            restCheck()
        }
        savePlan()
    }

    // MARK: The soft daily limit

    /// Counts the seconds of play once a second.
    func startPlayClock() {
        guard autoplay == nil, playClock == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.playClockTick() }
        RunLoop.main.add(t, forMode: .common)
        playClock = t
    }

    /// Whether something is being played on screen now.
    private var playing: Bool {
        guard active else { return false }
        switch route {
        case .game: return !gamePaused
        case .arcade: return arcade.map { ($0.phase == .playing || $0.phase == .countdown) && !$0.paused } ?? false
        case .winkBeat: return winkBeat.map { $0.phase == .ready || $0.phase == .playing } ?? false
        case .rhythm, .pursuit: return true
        default: return false
        }
    }

    private func playClockTick() {
        guard playing, !restReminder else { return }
        playTime.add(1, day: PlayTimeGuard.dayKey(Date()))
        playClockTicks += 1
        if playClockTicks % 10 == 0, let d = try? JSONEncoder().encode(playTime) {
            UserDefaults.standard.set(String(data: d, encoding: .utf8), forKey: playTimeKey)
        }
        // A reminder waits for a break (a round's end, the menu); three minutes of play past it, it comes anyway.
        if playTime.due, playTime.playedSec - playTime.nextSec > 180 { restCheck(pausing: true) }
    }

    /// Shows «Пора отдохнуть» when it is due. `pausing`: over a round, which waits on its pause plate behind it.
    func restCheck(pausing: Bool = false) {
        guard planCounts, playTime.due, !restReminder else { return }
        if pausing {
            if case .arcade = route { arcade?.setPaused(true) }
            if route == .winkBeat { return }
        }
        restReminder = true
    }

    /// «Отдохнуть»: the play closes and the menu comes back. The next reminder is 5 minutes of play later.
    func restNow() {
        dismissRest()
        switch route {
        case .arcade: leaveArcade()
        case .winkBeat: leaveWinkBeat()
        case .game, .rhythm, .pursuit: route = .menu
        default: break
        }
    }

    /// «Ещё 5 минут»: the play goes on.
    func dismissRest() {
        restReminder = false
        playTime.reminded()
        if let d = try? JSONEncoder().encode(playTime) {
            UserDefaults.standard.set(String(data: d, encoding: .utf8), forKey: playTimeKey)
        }
    }

    /// Minutes played today, for the plan screen.
    var playedTodayMinutes: Int {
        playTime.day == PlayTimeGuard.dayKey(Date()) ? playTime.playedMinutes : 0
    }

    #if DEBUG
    /// The CI shot of the plan (`-SpantherDemoReport plan`): 16 days played, three weekly checks, mornings ahead.
    static func demoPlan() -> PlanState {
        var s = PlanState()
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -16, to: cal.startOfDay(for: Date()))!
        for n in 1...16 {
            let day = DailyPlan.day(n, history: s)
            let hour = n % 3 == 0 ? 19 : n % 3 == 1 ? 9 : 14
            let date = cal.date(byAdding: .hour, value: 24 * (n - 1) + hour, to: start)!
            let growth = Double(n) * 0.012
            let results = day.blocks.enumerated().map { i, b in
                PlanBlockResult(mode: b.mode, level: b.level, control: b.control,
                                accuracy: min(0.97, 0.62 + growth + (hour == 9 ? 0.08 : 0) - Double(i) * 0.02),
                                reactionSec: b.mode == .moles ? 1.25 - growth : b.mode == .fishing ? 1.0 - growth / 2 : nil)
            }
            for r in results { s.add(FocusEntry(date: date, mode: r.mode, focus: r.focus)) }
            s.days.append(PlanDayRecord(number: n, date: date, blocks: results))
        }
        return s
    }
    #endif
}
