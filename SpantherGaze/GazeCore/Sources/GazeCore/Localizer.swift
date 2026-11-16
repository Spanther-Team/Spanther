import Foundation

/// The interface's translations. Russian is the source language: every text in the app's code is written in Russian
/// and is its own key. `Resources/strings.json` gives each key its English and Kazakh versions:
/// `{"Меню": {"en": "Menu", "kk": "Мәзір"}}`. Values go into `{0}`, `{1}` … in the text, in any order the language
/// needs; a text for `String(format:)` keeps its `%` specifiers instead.
public struct Localizer {
    /// Key (the Russian text) → language code → that language's text.
    public let table: [String: [String: String]]

    public init(table: [String: [String: String]]) {
        self.table = table
    }

    public init(json: Data) throws {
        table = try JSONDecoder().decode([String: [String: String]].self, from: json)
    }

    /// The text in `language` ("ru", "kk", "en"). Russian, and any text the table lacks, stays as written.
    public func text(_ ru: String, _ language: String) -> String {
        guard language != "ru", let t = table[ru]?[language], !t.isEmpty else { return ru }
        return t
    }

    /// `{0}`, `{1}` … replaced by `values`. A slot without a value stays as it is.
    public static func fill(_ s: String, _ values: [String]) -> String {
        guard !values.isEmpty, s.contains("{") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "{", let close = s[i...].firstIndex(of: "}"),
               let n = Int(s[s.index(after: i)..<close]), n >= 0, n < values.count {
                out += values[n]
                i = s.index(after: close)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    /// The `{n}` slots a text uses.
    public static func slots(_ s: String) -> Set<Int> {
        var found = Set<Int>()
        var i = s.startIndex
        while let open = s[i...].firstIndex(of: "{") {
            guard let close = s[open...].firstIndex(of: "}") else { break }
            if let n = Int(s[s.index(after: open)..<close]) { found.insert(n) }
            i = s.index(after: open)
        }
        return found
    }

    /// The `String(format:)` specifiers of a text, in order (`%%` left out): a translation must keep them as they are.
    public static func formats(_ s: String) -> [String] {
        var found: [String] = []
        let c = Array(s)
        var i = 0
        while i < c.count {
            guard c[i] == "%" else { i += 1; continue }
            var j = i + 1
            if j < c.count, c[j] == "%" { i = j + 1; continue }
            while j < c.count, "+-#0123456789.lhqzjt".contains(c[j]) { j += 1 }
            // «85 % of targets» is a sign, not a specifier: one ends in a conversion right after its flags.
            if j < c.count, "diuoxXfFeEgGaAcsp@".contains(c[j]) {
                found.append(String(c[i...j]))
                i = j + 1
            } else {
                i += 1
            }
        }
        return found
    }

    /// Which of the three Russian forms (одна игра, две игры, пять игр) a count takes in `language`. English takes
    /// the first for 1 and the second for the rest: its translations of «игра» and «игры» are game and games (the third
    /// can't serve: «раз» is both 1 раз and 5 раз). Kazakh keeps the noun singular after a number (бес ойын).
    public enum PluralForm { case one, few, many }

    public static func pluralForm(_ n: Int, _ language: String) -> PluralForm {
        switch language {
        case "en":
            return n == 1 ? .one : .few
        case "kk":
            return .one
        default:
            let d = abs(n) % 10, h = abs(n) % 100
            if d == 1 && h != 11 { return .one }
            if (2...4).contains(d) && !(12...14).contains(h) { return .few }
            return .many
        }
    }
}
