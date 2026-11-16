import SwiftUI

// The report for the specialist and the parent: the summary after a play (meteors, rhythm or the warm-up), and the
// child's history with the table the Share button sends. Game results only, said as such on the screen: no
// diagnosis, no health claims.

/// What the menu's report sheet opens on.
enum ReportPage: Identifiable {
    case history
    case summary(SessionSummary)

    var id: String {
        switch self {
        case .history: return "history"
        case .summary(let s): return s.id
        }
    }
}

struct ReportSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var page: ReportPage

    var body: some View {
        Group {
            switch page {
            case .summary(let s):
                PlaySummaryView(summary: s, onHistory: { page = .history }, onDone: { dismiss() })
            case .history:
                HistoryView(onDone: { dismiss() })
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Atlas.paper.ignoresSafeArea())
        .environment(\.colorScheme, .light)
    }
}

// MARK: - After a play

/// The summary of one play, of any game: the four numbers of the report in the same order, the game's own results
/// under them, and at the bottom the table of this play for the Share button.
private struct PlaySummaryView: View {
    @EnvironmentObject var app: AppModel
    let summary: SessionSummary
    let onHistory: () -> Void
    let onDone: () -> Void
    @State private var exportURL: URL? = nil

    var body: some View {
        let s = summary
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("Итог игры")).font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                if !s.childCode.isEmpty {
                    Text(s.childCode).font(Atlas.title).foregroundStyle(Atlas.vermilion)
                }
                Text(ReportText.setup(s)).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ForEach(Array(ReportText.numbers(s).enumerated()), id: \.element) { k, n in
                            ReportTile(big: n.big, small: n.small, label: n.label)
                                .kineticEntrance(order: k)
                        }
                    }
                    Text(ReportText.results(s, numbers: false, calibration: false))
                        .font(Atlas.metric(15, weight: .regular))
                        .foregroundStyle(Atlas.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(ReportText.notes(s, decoyDwellSec: app.balance.decoys?.errorDwellSec ?? 0.25), id: \.self) {
                            Text($0)
                        }
                        Text(L("Это результаты игры, а не медицинские показатели."))
                    }
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                if let url = exportURL {
                    ShareLink(item: url) { Label(L("Таблица CSV"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(AtlasSecondaryButton())
                        .accessibilityLabel(L("Поделиться таблицей CSV этой игры"))
                }
                Button(action: onHistory) { Text(L("Все занятия")) }
                    .buttonStyle(AtlasSecondaryButton())
                Button(action: onDone) { Text(L("Готово")) }
                    .buttonStyle(AtlasPrimaryButton())
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { exportURL = SessionStore.exportCSV(play: s) }
    }
}

private struct ReportTile: View {
    let big: String
    let small: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(big).font(Atlas.display(28)).monospacedDigit().foregroundStyle(Atlas.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(small).font(Atlas.caption).foregroundStyle(Atlas.ink).lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(Atlas.caption).foregroundStyle(Atlas.inkSoft).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .atlasPlate(padding: 10, accent: Atlas.sky)
    }
}

// MARK: - History

private struct HistoryView: View {
    @EnvironmentObject var app: AppModel
    let onDone: () -> Void
    @State private var exportURL: URL? = nil
    @State private var confirmDelete = false
    @FocusState private var editingCode: Bool

    private var plays: [SessionSummary] { SessionHistory.plays(of: app.childCode, in: app.sessions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Занятия")).font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                    Text(L("Результаты игры, а не медицинские показатели."))
                        .font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                }
                Spacer()
                if let url = exportURL, !app.sessions.isEmpty {
                    ShareLink(item: url) { Label(L("Таблица"), systemImage: "square.and.arrow.up") }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Atlas.ink)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel(L("Поделиться таблицей всех занятий для Excel"))
                }
                Button(action: onDone) { Text(L("Готово")) }
                    .buttonStyle(AtlasPrimaryButton())
                    .frame(width: 130)
            }
            HStack(alignment: .top, spacing: 24) {
                child
                    .frame(width: 270, alignment: .leading)
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear { exportURL = SessionStore.exportCSV(app.sessions) }
        .onChange(of: app.sessions) { exportURL = SessionStore.exportCSV($0) }
    }

    /// The code field, what changed since the first play, and deleting.
    private var child: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Код ребёнка"))
                    .font(Atlas.caption.weight(.semibold))
                    .foregroundStyle(Atlas.inkSoft)
                    .textCase(.uppercase)
                TextField(L("Например, К-07"), text: $app.childCode)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(Atlas.ink)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($editingCode)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(InkSlab(shape: CutPlate(cut: 10), fill: editingCode ? Atlas.cream : Atlas.paperShade,
                                        depth: editingCode ? 4 : 2))
                Text(L("Новые игры сохраняются под этим кодом. Без имени: кто под каким кодом, знает только центр."))
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                trends
                if !plays.isEmpty {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text(app.currentChildCode.isEmpty ? L("Удалить все занятия") : L("Удалить занятия {0}", app.currentChildCode))
                    }
                    .font(Atlas.caption.weight(.semibold))
                    .foregroundStyle(Atlas.vermilion)
                    .frame(minHeight: 44)
                }
            }
        }
        .confirmationDialog(deleteQuestion, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Удалить"), role: .destructive) { app.deleteSessions(of: app.childCode) }
            Button(L("Отмена"), role: .cancel) {}
        }
    }

    /// The first and the newest of the plays that compare, per game: «сбито 58% → 78%».
    @ViewBuilder private var trends: some View {
        let list = ReportText.trends(plays)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Первая и последняя игра"))
                    .font(Atlas.caption.weight(.semibold))
                    .foregroundStyle(Atlas.inkSoft)
                    .textCase(.uppercase)
                ForEach(list, id: \.self) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(Atlas.caption.weight(.semibold)).foregroundStyle(Atlas.ink)
                        ForEach(t.rows, id: \.self) { r in
                            HStack(spacing: 8) {
                                Text(r.label).foregroundStyle(Atlas.inkSoft)
                                Spacer(minLength: 4)
                                Text("\(r.first) → \(r.last)").foregroundStyle(Atlas.ink).monospacedDigit()
                            }
                            .font(Atlas.caption)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private var deleteQuestion: String {
        app.currentChildCode.isEmpty ? L("Удалить все занятия с телефона?") : L("Удалить занятия {0} с телефона?", app.currentChildCode)
    }

    @ViewBuilder private var list: some View {
        if plays.isEmpty {
            Text(app.currentChildCode.isEmpty
                 ? L("Здесь появятся сыгранные игры: метеориты, когда игра закрыта, ритм, когда трек доигран, разминка, когда прошла её минута.")
                 : L("Под кодом {0} игр пока нет. Они появятся здесь, когда ребёнок сыграет.", app.currentChildCode))
                .font(Atlas.body)
                .foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(plays.reversed())) { s in row(s) }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func row(_ s: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(ReportText.when(s.start)).font(Atlas.caption.weight(.semibold)).foregroundStyle(Atlas.ink)
                Text(ReportText.setup(s, calibration: false)).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if app.currentChildCode.isEmpty, !s.childCode.isEmpty {
                    Text(s.childCode).font(Atlas.caption.weight(.semibold)).foregroundStyle(Atlas.vermilion)
                }
            }
            Text(ReportText.results(s))
                .font(Atlas.metric(15, weight: .regular))
                .foregroundStyle(Atlas.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .atlasPlate(padding: 10)
    }
}

// MARK: - Words

/// The report's numbers in words, the Russian way: decimal commas, minutes and seconds, plural forms, and no-break
/// spaces that keep a number with its unit and its label on one line.
enum ReportText {
    static let nb = "\u{00A0}"

    static func percent(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }

    static func seconds(_ v: Double?) -> String { v.map { SessionHistory.number($0, 1) + nb + L("с") } ?? "–" }

    static func duration(_ sec: Double) -> String {
        let total = Int(sec.rounded()), m = total / 60, s = total % 60
        if m == 0 { return L("{0}\u{00A0}с", s) }
        return s == 0 ? L("{0}\u{00A0}мин", m) : L("{0}\u{00A0}мин {1}\u{00A0}с", m, s)
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Loc.locale
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: d)
    }

    private static func level(_ s: SessionSummary) -> String {
        Atlas.levelName(RhythmLevel(rawValue: s.rhythmLevel ?? "") ?? .normal).lowercased()
    }

    private static func calibration(_ s: SessionSummary) -> String? {
        s.calibrationErrorCm.map { L("промах калибровки\u{00A0}{0}\u{00A0}см", SessionHistory.number($0, 1)) }
    }

    /// The game, how it was played, for how long, with which targets, and (with `calibration`) the calibration
    /// error before it.
    static func setup(_ s: SessionSummary, calibration withCalibration: Bool = true) -> String {
        var parts = [L(SessionHistory.gameName(s.game)), s.byEye ? L("взглядом") : L("пальцем"), duration(s.durationSec)]
        if s.targetScale != nil { parts.append(L("мелкие цели")) }
        if withCalibration, let c = calibration(s) { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    /// One of the four numbers of the report.
    struct Number: Hashable {
        /// For a tile: the number, the line under it, and what it is.
        let big: String
        let small: String
        let label: String
        /// For a list: what it is, and the number with its unit.
        let rowLabel: String
        let rowValue: String
    }

    /// The four numbers of the report, in the same order after every game: holding the gaze, the timing in the
    /// rhythm, the looks at red signs, and each eye's winks. A game that does not measure one shows a dash and
    /// says which game does.
    static func numbers(_ s: SessionSummary) -> [Number] {
        let dash = "–"

        let holdLabel = s.byEye ? L("удержание взгляда") : L("удержание пальца")
        let holdSmall: String
        switch s.game {
        case .meteors: holdSmall = s.holdShare == nil ? L("нет данных") : L("без срыва")
        case .rhythm: holdSmall = s.byEye ? L("взгляд на ноте") : L("только взглядом")
        case .pursuit: holdSmall = L("рядом с точкой")
        }
        let holdValue = percent(s.holdShare)
        let hold = Number(big: holdValue, small: holdSmall, label: holdLabel, rowLabel: holdLabel, rowValue: holdValue)

        var timingValue = dash
        if let ms = s.timingDeviationMs { timingValue = SessionHistory.number(ms, 0) + nb + L("мс") }
        let timingSmall = s.game == .rhythm ? L("в среднем") : L("только в ритме")
        let timing = Number(big: timingValue, small: timingSmall, label: L("отклонение от ритма"),
                            rowLabel: L("отклонение от ритма"), rowValue: timingValue)

        var signsBig = dash, signsRow = dash
        var signsSmall = s.game == .meteors ? L("знаков не было") : L("только в метеоритах")
        if s.game == .meteors, let all = s.decoys, let errors = s.decoyErrors {
            signsBig = String(errors)
            signsSmall = L("из") + nb + String(all)
            signsRow = L("{0}\u{00A0}из\u{00A0}{1}", errors, all)
        }
        let signs = Number(big: signsBig, small: signsSmall, label: L("ошибки на красных"),
                           rowLabel: L("ошибки на красных"), rowValue: signsRow)

        var winksBig = dash, winksRow = dash
        var winksSmall = s.game == .rhythm ? L("только взглядом") : L("только в ритме")
        if s.game == .rhythm, s.byEye, s.winkLeft != nil || s.winkRight != nil {
            let left: String = s.winkLeft.map { String(Int(($0 * 100).rounded())) } ?? dash
            let right: String = s.winkRight.map { String(Int(($0 * 100).rounded())) } ?? dash
            winksBig = left + " · " + right
            winksSmall = L("левый · правый, %")
            winksRow = percent(s.winkLeft) + " · " + percent(s.winkRight)
        }
        let winks = Number(big: winksBig, small: winksSmall, label: L("подмигивания"),
                           rowLabel: L("подмигивания, левый · правый"), rowValue: winksRow)

        return [hold, timing, signs, winks]
    }

    /// What the numbers of this game mean, a sentence each. `decoyDwellSec`: how long a look at a red sign must
    /// last to count (balance.json).
    static func notes(_ s: SessionSummary, decoyDwellSec: Double) -> [String] {
        var out: [String] = []
        switch s.game {
        case .meteors:
            out.append(s.byEye
                       ? L("Удержание: метеориты, сожжённые одним взглядом, без срыва, из тех, на которые ребёнок посмотрел.")
                       : L("Удержание: метеориты, сожжённые одним касанием, без срыва, из тех, которых ребёнок коснулся."))
            if s.decoys != nil {
                let dwell = SessionHistory.number(decoyDwellSec, 2) + nb + L("с")
                out.append(s.byEye
                           ? L("Ошибка на красном: взгляд задержался на красном знаке дольше {0}.", dwell)
                           : L("Ошибка на красном: палец задержался на красном знаке дольше {0}.", dwell))
            }
        case .rhythm:
            if s.byEye {
                out.append(L("Удержание: подмигивания, при которых взгляд остался на ноте, из всех попавших в такт."))
            }
            out.append(L("Отклонение от ритма: насколько в среднем ноты сыграны раньше или позже своего обычного опоздания."))
            if s.byEye {
                out.append(L("Подмигивания: какая доля подмигиваний каждым глазом сыграла ноту."))
            }
        case .pursuit:
            out.append(s.byEye
                       ? L("Удержание: доля минуты, когда взгляд шёл рядом с точкой. Секунда у каждой смены траектории не считается.")
                       : L("Удержание: доля минуты, когда палец шёл рядом с точкой. Секунда у каждой смены траектории не считается."))
        }
        return out
    }

    /// One play's results in a line. `numbers`: with those of the report's four numbers the game measures (the
    /// summary shows them as tiles and leaves them out here). `calibration`: ending with the calibration error.
    static func results(_ s: SessionSummary, numbers: Bool = true, calibration withCalibration: Bool = true) -> String {
        var parts: [String] = []
        let hold: String? = s.holdShare == nil ? nil : L("удержание") + nb + percent(s.holdShare)
        switch s.game {
        case .meteors:
            parts.append(L("сбито {0}\u{00A0}из\u{00A0}{1}\u{00A0}({2})", s.burned ?? 0, s.meteors ?? 0, percent(s.burnedShare)))
            if numbers {
                if let hold { parts.append(hold) }
                if let all = s.decoys, let errors = s.decoyErrors {
                    parts.append(L("ошибок на красных\u{00A0}{0}\u{00A0}из\u{00A0}{1}", errors, all))
                }
            }
            if let v = s.meanFirstLookSec { parts.append((s.byEye ? L("первый взгляд") : L("первое касание")) + nb + seconds(v)) }
            if let v = s.slipsPerMeteor { parts.append(L("срывов на метеорит") + nb + SessionHistory.number(v, 1)) }
            if let l = s.maxLevel { parts.append(L("уровень") + nb + String(l)) }
        case .rhythm:
            parts.append(L("«{0}», {1}", L(s.track ?? ""), level(s)))
            parts.append(L("точность") + nb + percent(s.accuracy))
            parts.append(L("сыграно {0}\u{00A0}из\u{00A0}{1}", s.hits ?? 0, s.notes ?? 0))
            if numbers {
                if let hold { parts.append(hold) }
                if let ms = s.timingDeviationMs {
                    parts.append(L("отклонение от ритма") + nb + SessionHistory.number(ms, 0) + nb + L("мс"))
                }
                if s.winkLeft != nil || s.winkRight != nil {
                    parts.append(L("подмигивания: левый") + nb + percent(s.winkLeft) + L(", правый") + nb + percent(s.winkRight))
                }
            }
            parts.append(L("лучшая серия") + nb + String(s.maxCombo ?? 0))
            if let w = s.extraWinks { parts.append(L("лишних подмигиваний") + nb + String(w)) }
        case .pursuit:
            if numbers, let hold { parts.append(hold) }
            if s.pursuitHorizontal != nil { parts.append(L("горизонталь") + nb + percent(s.pursuitHorizontal)) }
            if s.pursuitVertical != nil { parts.append(L("вертикаль") + nb + percent(s.pursuitVertical)) }
            if s.pursuitEight != nil { parts.append(L("восьмёрка") + nb + percent(s.pursuitEight)) }
            if let cm = s.pursuitMeanCm { parts.append(L("до точки в среднем") + nb + SessionHistory.number(cm, 1) + nb + L("см")) }
            if s.pursuitLostShare != nil {
                parts.append((s.byEye ? L("без взгляда") : L("без касания")) + nb + percent(s.pursuitLostShare))
            }
        }
        if withCalibration, let c = calibration(s) { parts.append(c) }
        // The line starts with a capital, whichever part came first.
        if let first = parts.first, !first.hasPrefix("«") {
            parts[0] = first.prefix(1).uppercased() + String(first.dropFirst())
        }
        return parts.joined(separator: " · ")
    }

    struct Trend: Hashable {
        struct Row: Hashable {
            let label: String
            let first: String
            let last: String
        }
        let title: String
        let rows: [Row]
    }

    private static func milliseconds(_ v: Double?) -> String {
        v.map { SessionHistory.number($0, 0) + nb + L("мс") } ?? "–"
    }

    /// The first and the newest of the plays that compare (SessionHistory.progress), per game.
    static func trends(_ plays: [SessionSummary]) -> [Trend] {
        var out: [Trend] = []
        let m = SessionHistory.progress(plays, game: .meteors)
        if let a = m.first, let b = m.last {
            var rows = [Trend.Row(label: L("сбито"), first: percent(a.burnedShare), last: percent(b.burnedShare))]
            if a.holdShare != nil, b.holdShare != nil {
                rows.append(Trend.Row(label: L("удержание"), first: percent(a.holdShare), last: percent(b.holdShare)))
            }
            if a.decoyErrorShare != nil, b.decoyErrorShare != nil {
                rows.append(Trend.Row(label: L("ошибки на красных"), first: percent(a.decoyErrorShare),
                                      last: percent(b.decoyErrorShare)))
            }
            if a.meanFirstLookSec != nil, b.meanFirstLookSec != nil {
                rows.append(Trend.Row(label: b.byEye ? L("первый взгляд") : L("первое касание"),
                                      first: seconds(a.meanFirstLookSec), last: seconds(b.meanFirstLookSec)))
            }
            if let x = a.slipsPerMeteor, let y = b.slipsPerMeteor {
                rows.append(Trend.Row(label: L("срывов на метеорит"), first: SessionHistory.number(x, 1),
                                      last: SessionHistory.number(y, 1)))
            }
            let games = plural(m.count, L("игра"), L("игры"), L("игр")), how = b.byEye ? L("взглядом") : L("пальцем")
            let size = b.targetScale == nil ? "" : L(", мелкие цели")
            out.append(Trend(title: L("Метеориты {0}{1}, {2} {3}", how, size, m.count, games), rows: rows))
        }
        let r = SessionHistory.progress(plays, game: .rhythm)
        if let a = r.first, let b = r.last {
            var rows = [Trend.Row(label: L("точность"), first: percent(a.accuracy), last: percent(b.accuracy))]
            if a.timingDeviationMs != nil, b.timingDeviationMs != nil {
                rows.append(Trend.Row(label: L("отклонение от ритма"), first: milliseconds(a.timingDeviationMs),
                                      last: milliseconds(b.timingDeviationMs)))
            }
            if a.holdShare != nil, b.holdShare != nil {
                rows.append(Trend.Row(label: L("удержание"), first: percent(a.holdShare), last: percent(b.holdShare)))
            }
            let games = plural(r.count, L("игра"), L("игры"), L("игр"))
            out.append(Trend(title: L("Ритм, {0} уровень, {1} {2}", level(b), r.count, games), rows: rows))
        }
        let w = SessionHistory.progress(plays, game: .pursuit)
        if let a = w.first, let b = w.last {
            var rows = [Trend.Row(label: L("удержание"), first: percent(a.holdShare), last: percent(b.holdShare))]
            if let x = a.pursuitMeanCm, let y = b.pursuitMeanCm {
                rows.append(Trend.Row(label: L("до точки в среднем"), first: SessionHistory.number(x, 1) + nb + L("см"),
                                      last: SessionHistory.number(y, 1) + nb + L("см")))
            }
            let times = plural(w.count, L("раз"), L("раза"), L("раз")), how = b.byEye ? L("взглядом") : L("пальцем")
            out.append(Trend(title: L("Разминка {0}, {1} {2}", how, w.count, times), rows: rows))
        }
        return out
    }
}
