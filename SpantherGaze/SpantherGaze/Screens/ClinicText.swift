import Foundation

/// The clinic's numbers in words, the Russian way (decimal commas, units after the number): metric names and units,
/// quality issues, procedures and the emblems of the picker. The parent's words avoid clinical terms.
enum ClinicText {
    /// The three numbers a session card leads with.
    static let headline: [ProbeMetric] = [.holdShare, .firstLookMs, .lookAwaysPerMin]

    static func name(_ m: ProbeMetric) -> String {
        switch m {
        case .holdShare: return L("Удержание цели")
        case .holdShareQuiet: return L("Удержание без отвлечений")
        case .holdShareDistracted: return L("Удержание при отвлечениях")
        case .firstLookMs: return L("Время до первого взгляда")
        case .latencySdMs: return L("Разброс этого времени")
        case .latencyIqrMs: return L("Межквартильный размах")
        case .anticipationShare: return L("Упреждающие взгляды")
        case .distractorPullShare: return L("Уход на отвлекающий")
        case .distractorReturnMs: return L("Возврат к цели")
        case .distractorEvents: return L("Отвлекающих стимулов")
        case .pursuitOnShare: return L("Слежение: на цели")
        case .pursuitGain: return L("Слежение: усиление")
        case .pursuitLagMs: return L("Слежение: запаздывание")
        case .lookAwaysPerMin: return L("Взгляды мимо экрана")
        case .awayShare: return L("Время мимо экрана")
        case .validShare: return L("Кадры со взглядом")
        case .fps: return L("Кадров в секунду")
        case .radiusDeg: return L("Радиус зоны цели")
        }
    }

    static func unit(_ m: ProbeMetric) -> String {
        switch m {
        case .holdShare, .holdShareQuiet, .holdShareDistracted, .anticipationShare, .distractorPullShare,
             .pursuitOnShare, .awayShare, .validShare:
            return "%"
        case .firstLookMs, .latencySdMs, .latencyIqrMs, .distractorReturnMs, .pursuitLagMs: return L("мс")
        case .lookAwaysPerMin: return L("в мин")
        case .fps: return L("к/с")
        case .radiusDeg: return "°"
        case .pursuitGain, .distractorEvents: return ""
        }
    }

    /// Shares are shown in percent; everything else as stored.
    static func shown(_ m: ProbeMetric, _ v: Double) -> Double { unit(m) == "%" ? v * 100 : v }

    /// Digits after the comma for the shown value.
    static func digits(_ m: ProbeMetric) -> Int {
        switch m {
        case .pursuitGain: return 2
        case .lookAwaysPerMin, .radiusDeg: return 1
        default: return 0
        }
    }

    /// "82 %", "640 мс", "1,4 в мин"; a dash when the number could not be measured.
    static func value(_ m: ProbeMetric, _ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        let n = number(shown(m, v), digits: digits(m))
        let u = unit(m)
        return u.isEmpty ? n : n + "\u{00A0}" + u
    }

    /// A number in the language's way: a decimal comma in Russian and Kazakh, a point in English.
    static func number(_ x: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.locale = Loc.locale
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: x)) ?? String(x)
    }

    static func issue(_ i: ProbeQuality.Issue) -> String {
        switch i {
        case .calibration: return L("калибровка неточная")
        case .distance: return L("телефон слишком близко или далеко")
        case .tracking: return L("много кадров без взгляда")
        case .frameRate: return L("камера работала медленно")
        case .incomplete: return L("проба не дошла до конца")
        }
    }

    static func procedure(_ k: Procedure.Kind) -> String {
        switch k {
        case .tms: return L("ТМС")
        case .laser: return L("Лазер")
        case .neurofeedback: return L("Нейрофидбек")
        case .other: return L("Другое")
        }
    }

    static func place(_ p: Session.Place) -> String { p == .clinic ? L("в центре") : L("дома") }

    /// The picker's emblems (SF Symbols): creatures and signs, never a photo. `Child.emblemCount` of them.
    static let emblems = ["hare", "tortoise", "ladybug", "ant", "leaf", "star", "moon", "sun.max", "flame", "drop",
                          "snowflake", "pawprint"]

    static func emblem(_ i: Int) -> String { emblems[((i % emblems.count) + emblems.count) % emblems.count] }

    static var date: DateFormatter {
        let f = DateFormatter()
        f.locale = Loc.locale
        f.dateFormat = "d MMM yyyy"
        return f
    }

    // MARK: For parents, in plain words

    /// The three numbers of the parent's view, said without clinical terms.
    static var parentMetrics: [(ProbeMetric, String)] { [
        (.holdShare, L("Удерживает взгляд на цели")),
        (.firstLookMs, L("Находит новую цель за")),
        (.lookAwaysPerMin, L("Отводит взгляд от экрана")),
    ] }

    static func parentValue(_ m: ProbeMetric, _ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        switch m {
        case .holdShare: return number(v * 100, digits: 0) + L("\u{00A0}% целей")
        case .firstLookMs: return number(v / 1000, digits: 1) + L("\u{00A0}с")
        case .lookAwaysPerMin: return number(v, digits: 1) + L(" раза в минуту")
        default: return value(m, v)
        }
    }
}
