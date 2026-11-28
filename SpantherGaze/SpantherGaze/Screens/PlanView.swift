import SwiftUI

/// The 30-day plan (Aziz, 2026-11-28): today's training of three blocks with its button, the 30 days, the weekly
/// control checks in numbers, and the focus by time of day once two weeks are played. The words stay with attention
/// training: the screen measures caught targets, never health.
struct PlanView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 16) {
                PlanTodayPlate()
                    .frame(maxWidth: .infinity)
                    .kineticEntrance(order: 1)
                VStack(spacing: 14) {
                    PlanDaysStrip()
                    PlanControlPlate()
                    PlanTimeOfDayPlate()
                }
                .frame(maxWidth: .infinity)
                .kineticEntrance(order: 2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { app.route = .menu } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(Atlas.ink)
                    .frame(width: 44, height: 44)
                    .atlasChip()
            }
            .accessibilityLabel(L("В меню"))
            VStack(alignment: .leading, spacing: 2) {
                Text(L("План на 30 дней")).font(Atlas.display(24)).foregroundStyle(Atlas.ink)
                Text(L("Каждый день от 7 до 10 минут: режимы сменяют друг друга, целей понемногу больше."))
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.inkSoft)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "timer")
                Text(L("Сегодня в игре: {0} мин", app.playedTodayMinutes))
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Atlas.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .atlasChip()
            .fixedSize()
        }
    }
}

/// The names and pictures of the plan's modes.
enum PlanLook {
    static func name(_ m: PlanMode) -> String {
        switch m {
        case .moles: return L("Кроты")
        case .fishing: return L("Рыбалка")
        case .meteors: return L("Метеориты")
        case .circles: return "Wink Beat"
        }
    }

    static func icon(_ m: PlanMode) -> String {
        switch m {
        case .moles: return "hammer.fill"
        case .fishing: return "fish.fill"
        case .meteors: return "flame.fill"
        case .circles: return "music.note"
        }
    }

    static func tint(_ m: PlanMode) -> Color {
        switch m {
        case .moles: return Atlas.energy
        case .fishing: return Atlas.sky
        case .meteors: return Atlas.gold
        case .circles: return Atlas.emerald
        }
    }

    static func level(_ b: PlanBlock) -> String {
        if b.mode == .circles { return b.level >= 2 ? L("Средний") : L("Лёгкий") }
        return L("Уровень {0}", b.level)
    }

    static func band(_ b: DayBand) -> String {
        switch b {
        case .morning: return L("Утро")
        case .day: return L("День")
        case .evening: return L("Вечер")
        }
    }
}

/// Today: the day's number, its blocks with what each gave, and the one button.
private struct PlanTodayPlate: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        let day = app.planDayShown
        let run = app.planRun.flatMap { $0.owner == app.profiles.active?.id ? $0 : nil }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("День {0}", day.number)).font(Atlas.display(30)).foregroundStyle(Atlas.ink)
                Text(L("из {0}", DailyPlan.length)).font(Atlas.title).foregroundStyle(Atlas.inkSoft)
                Spacer(minLength: 4)
                if day.isControl {
                    Text(L("Замер недели"))
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(Atlas.cream)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Slant(lean: 6).fill(Atlas.vermilion))
                }
            }
            ForEach(Array(day.blocks.enumerated()), id: \.offset) { i, b in
                row(b, result: run.flatMap { i < $0.results.count ? $0.results[i] : nil },
                    current: run.map { $0.index == i } ?? (i == 0 && !app.planToday.doneToday))
            }
            Spacer(minLength: 0)
            footer(day: day, run: run)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .atlasPlate(padding: 14, accent: Atlas.emerald)
    }

    private func row(_ b: PlanBlock, result: PlanBlockResult?, current: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: PlanLook.icon(b.mode))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Atlas.ink)
                .frame(width: 34, height: 34)
                .background(Circle().fill(PlanLook.tint(b.mode)))
                .overlay(Circle().strokeBorder(Atlas.ink, lineWidth: Atlas.line))
            VStack(alignment: .leading, spacing: 1) {
                Text(b.control ? L("{0}: замер", PlanLook.name(b.mode)) : PlanLook.name(b.mode))
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(Atlas.ink)
                Text(L("{0} · {1} мин", PlanLook.level(b), max(1, Int((b.seconds / 60).rounded()))))
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.inkSoft)
            }
            Spacer(minLength: 4)
            if let r = result {
                Label(L("Фокус {0}", r.focus), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Atlas.emerald)
            } else if current {
                Image(systemName: "arrowtriangle.left.fill")
                    .foregroundStyle(Atlas.energy)
                    .accessibilityLabel(L("Сейчас"))
            }
        }
        .padding(.vertical, 2)
        .opacity(result == nil && !current ? 0.75 : 1)
    }

    @ViewBuilder private func footer(day: PlanDay, run: PlanRun?) -> some View {
        if let r = run, r.finished {
            let rec = PlanDayRecord(number: r.day.number, date: Date(), blocks: r.results)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("День {0} готов! Фокус дня: {1}", r.day.number, rec.focus))
                    .font(Atlas.title)
                    .foregroundStyle(Atlas.ink)
                if let first = DailyPlan.controls(app.plan).first, r.day.isControl,
                   let now = DailyPlan.controls(app.plan).last, now.day != first.day {
                    Text(L("Замер: {0}, на первом было {1}", now.focus, first.focus))
                        .font(Atlas.body.weight(.semibold))
                        .foregroundStyle(now.focus >= first.focus ? Atlas.emerald : Atlas.inkSoft)
                }
                Text(L("Следующий день откроется завтра.")).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
            }
        } else if app.planComplete {
            Text(L("Все 30 дней пройдены! Сравни замеры справа.")).font(Atlas.title).foregroundStyle(Atlas.ink)
        } else if run == nil, app.planToday.doneToday {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("На сегодня всё. Отличная работа!")).font(Atlas.title).foregroundStyle(Atlas.ink)
                Text(L("Следующий день откроется завтра.")).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
            }
        } else {
            let next = run.map { $0.day.blocks[$0.index] } ?? day.blocks.first
            Button { app.playPlanBlock() } label: {
                Text(run == nil || run?.index == 0
                     ? L("Начать день {0}", day.number)
                     : L("Дальше: {0}", next.map { PlanLook.name($0.mode) } ?? ""))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(AtlasPrimaryButton())
        }
    }
}

/// The 30 days in three rows: played ones filled, the weekly checks marked, today outlined.
private struct PlanDaysStrip: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        let done = Set(app.plan.days.map(\.number))
        let today = app.planDayShown.number
        let cols = Array(repeating: GridItem(.flexible(), spacing: 5), count: 10)
        LazyVGrid(columns: cols, spacing: 5) {
            ForEach(1...DailyPlan.length, id: \.self) { n in
                let control = DailyPlan.controlDays.contains(n)
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(done.contains(n) ? (control ? Atlas.vermilion : Atlas.emerald) : Atlas.paperShade)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Atlas.ink, lineWidth: n == today ? 2.5 : 1)
                    Text("\(n)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(done.contains(n) ? Atlas.cream : Atlas.ink)
                }
                .frame(height: 22)
                .accessibilityLabel(L("День {0}", n))
            }
        }
    }
}

/// The weekly control checks as bars with their numbers, and how far the last is from the first.
private struct PlanControlPlate: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        let checks = DailyPlan.controls(app.plan)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Замеры раз в неделю")).font(.system(size: 16, weight: .heavy, design: .rounded))
                Spacer()
                if let f = checks.first, let l = checks.last, checks.count >= 2 {
                    let d = l.focus - f.focus
                    Text(d >= 0 ? L("+{0} с первого замера", d) : L("{0} с первого замера", d))
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(d >= 0 ? Atlas.emerald : Atlas.inkSoft)
                }
            }
            .foregroundStyle(Atlas.ink)
            if checks.isEmpty {
                Text(L("Первый замер в день 1: кроты и рыбалка по минуте, каждую неделю одинаково."))
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.inkSoft)
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { i, c in
                        VStack(spacing: 3) {
                            Text("\(c.focus)").font(.system(size: 13, weight: .heavy, design: .rounded)).monospacedDigit()
                            RoundedRectangle(cornerRadius: 3)
                                .fill(i == checks.count - 1 ? Atlas.vermilion : Atlas.gold)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Atlas.ink, lineWidth: 1.5))
                                .frame(width: 26, height: max(6, CGFloat(c.focus) * 0.5))
                            Text(L("Нед. {0}", i + 1)).font(.system(size: 11)).foregroundStyle(Atlas.inkSoft)
                        }
                    }
                    Spacer(minLength: 0)
                    if let f = checks.first?.molesReactionSec, let l = checks.last?.molesReactionSec, checks.count >= 2 {
                        Text(L("Реакция на кротов: {0} с → {1} с", String(format: "%.2f", f), String(format: "%.2f", l)))
                            .font(Atlas.caption)
                            .foregroundStyle(Atlas.inkSoft)
                            .frame(maxWidth: 150, alignment: .trailing)
                    }
                }
                .foregroundStyle(Atlas.ink)
            }
        }
        .atlasPlate(padding: 10, accent: Atlas.gold)
    }
}

/// When the focus is higher: three bars once two weeks are played, else how much is left.
private struct PlanTimeOfDayPlate: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        let f = FocusByTime(app.plan.entries)
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Когда фокус выше")).font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(Atlas.ink)
            if f.ready {
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach(f.bands, id: \.band) { b in
                        VStack(spacing: 3) {
                            Text(b.focus.map { "\($0)" } ?? "-")
                                .font(.system(size: 13, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                            RoundedRectangle(cornerRadius: 3)
                                .fill(b.band == f.best ? Atlas.emerald : Atlas.sky.opacity(b.focus == nil ? 0.25 : 1))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Atlas.ink, lineWidth: 1.5))
                                .frame(width: 34, height: max(6, CGFloat(b.focus ?? 0) * 0.45))
                            Text(PlanLook.band(b.band)).font(.system(size: 11)).foregroundStyle(Atlas.inkSoft)
                        }
                    }
                    Text(verdict(f))
                        .font(Atlas.caption.weight(.semibold))
                        .foregroundStyle(Atlas.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Atlas.ink)
            } else {
                Text(f.daysLeft > 0
                     ? L("Ещё дней до вывода: {0}. Играй в разное время: утром, днём и вечером.", f.daysLeft)
                     : L("Нужно по три дня игры хотя бы в два времени суток: утром, днём или вечером."))
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("Это подсказка для тренировок, а не оценка здоровья."))
                .font(.system(size: 11))
                .foregroundStyle(Atlas.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .atlasPlate(padding: 10, accent: Atlas.sky)
    }

    private func verdict(_ f: FocusByTime) -> String {
        switch f.best {
        case .morning: return L("Утром фокус выше. Ставь тренировку на утро.")
        case .day: return L("Днём фокус выше. Ставь тренировку на день.")
        case .evening: return L("Вечером фокус выше. Ставь тренировку на вечер.")
        case nil: return L("Фокус ровный в течение дня: играй, когда удобно.")
        }
    }
}

/// The soft daily limit's card: after 20 minutes of play, then every 5, a rest is suggested. Play can go on.
struct RestReminderCard: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Atlas.emerald)
                    Text(L("Пора отдохнуть")).font(Atlas.display(26)).foregroundStyle(Atlas.ink)
                }
                Text(L("Сегодня ты играешь уже {0} мин. Посмотри вдаль, в окно, и разомнись пару минут.", app.playedTodayMinutes))
                    .font(Atlas.body)
                    .foregroundStyle(Atlas.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button { app.restNow() } label: { Text(L("Отдохнуть")) }
                        .buttonStyle(AtlasPrimaryButton())
                    Button { app.dismissRest() } label: { Text(L("Ещё 5 минут")) }
                        .buttonStyle(AtlasSecondaryButton())
                }
            }
            .frame(maxWidth: 420)
            .atlasPlate(padding: 20, accent: Atlas.emerald)
            .kineticEntrance()
        }
    }
}
