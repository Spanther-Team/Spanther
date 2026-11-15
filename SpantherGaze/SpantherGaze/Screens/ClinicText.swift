import Foundation

/// The clinic's numbers in words, the Russian way (decimal commas, units after the number): metric names and units,
/// quality issues, procedures and the emblems of the picker. The parent's words avoid clinical terms.
enum ClinicText {
    /// The three numbers a session card leads with.
    static let headline: [ProbeMetric] = [.holdShare, .firstLookMs, .lookAwaysPerMin]

    static func name(_ m: ProbeMetric) -> String {
        switch m {
        case .holdShare: return "Удержание цели"
        case .holdShareQuiet: return "Удержание без отвлечений"
        case .holdShareDistracted: return "Удержание при отвлечениях"
        case .firstLookMs: return "Время до первого взгляда"
        case .latencySdMs: return "Разброс этого времени"
        case .latencyIqrMs: return "Межквартильный размах"
        case .anticipationShare: return "Упреждающие взгляды"
        case .distractorPullShare: return "Уход на отвлекающий"
        case .distractorReturnMs: return "Возврат к цели"
        case .distractorEvents: return "Отвлекающих стимулов"
        case .pursuitOnShare: return "Слежение: на цели"
        case .pursuitGain: return "Слежение: усиление"
        case .pursuitLagMs: return "Слежение: запаздывание"
        case .lookAwaysPerMin: return "Взгляды мимо экрана"
        case .awayShare: return "Время мимо экрана"
        case .validShare: return "Кадры со взглядом"
        case .fps: return "Кадров в секунду"
        case .radiusDeg: return "Радиус зоны цели"
        }
    }

    static func unit(_ m: ProbeMetric) -> String {
        switch m {
        case .holdShare, .holdShareQuiet, .holdShareDistracted, .anticipationShare, .distractorPullShare,
             .pursuitOnShare, .awayShare, .validShare:
            return "%"
        case .firstLookMs, .latencySdMs, .latencyIqrMs, .distractorReturnMs, .pursuitLagMs: return "мс"
        case .lookAwaysPerMin: return "в мин"
        case .fps: return "к/с"
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

    /// A number with a decimal comma.
    static func number(_ x: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: x)) ?? String(x)
    }

    static func issue(_ i: ProbeQuality.Issue) -> String {
        switch i {
        case .calibration: return "калибровка неточная"
        case .distance: return "телефон слишком близко или далеко"
        case .tracking: return "много кадров без взгляда"
        case .frameRate: return "камера работала медленно"
        case .incomplete: return "проба не дошла до конца"
        }
    }

    static func procedure(_ k: Procedure.Kind) -> String {
        switch k {
        case .tms: return "ТМС"
        case .laser: return "Лазер"
        case .neurofeedback: return "Нейрофидбек"
        case .other: return "Другое"
        }
    }

    static func place(_ p: Session.Place) -> String { p == .clinic ? "в центре" : "дома" }

    /// The picker's emblems (SF Symbols): creatures and signs, never a photo. `Child.emblemCount` of them.
    static let emblems = ["hare", "tortoise", "ladybug", "ant", "leaf", "star", "moon", "sun.max", "flame", "drop",
                          "snowflake", "pawprint"]

    static func emblem(_ i: Int) -> String { emblems[((i % emblems.count) + emblems.count) % emblems.count] }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    // MARK: For parents, in plain words

    /// The three numbers of the parent's view, said without clinical terms.
    static let parentMetrics: [(ProbeMetric, String)] = [
        (.holdShare, "Удерживает взгляд на цели"),
        (.firstLookMs, "Находит новую цель за"),
        (.lookAwaysPerMin, "Отводит взгляд от экрана"),
    ]

    static func parentValue(_ m: ProbeMetric, _ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        switch m {
        case .holdShare: return number(v * 100, digits: 0) + "\u{00A0}% целей"
        case .firstLookMs: return number(v / 1000, digits: 1) + "\u{00A0}с"
        case .lookAwaysPerMin: return number(v, digits: 1) + " раза в минуту"
        default: return value(m, v)
        }
    }
}
