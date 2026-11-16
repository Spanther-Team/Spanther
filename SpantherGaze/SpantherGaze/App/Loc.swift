import Foundation

/// The app's language: Russian, Kazakh or English. Every text in the code is written in Russian and goes through `L`,
/// which gives it in the chosen language from Resources/strings.json (`Localizer`). The choice is the start screen's
/// (`StartGate.language`, kept between launches), and the menu's language chip changes it too; the screens are
/// built again when it changes (`RootView`).
///
/// Files made for the center (tables, the PDF, the course's raw data) stay in Russian whatever the interface's
/// language is: they are built inside `Loc.inRussian`.
///
/// A new text: write it in Russian inside `L("…")`, values as `{0}`, `{1}` … after it (`L("Звёзд {0} из 3", n)`),
/// and add its English and Kazakh to strings.json. `LocalizerTests` fails while a text in `L` has no translation or
/// a Russian text on screen is not in `L`.
enum Loc {
    static var language: GateLanguage = .saved

    /// For dates and numbers written by the system.
    static var locale: Locale {
        switch language {
        case .ru: return Locale(identifier: "ru_RU")
        case .kk: return Locale(identifier: "kk_KZ")
        case .en: return Locale(identifier: "en_US")
        }
    }

    /// A decimal number on screen: 1,5 in Russian and Kazakh, 1.5 in English. The session CSVs keep the comma
    /// (`SessionHistory.number`).
    static func number(_ v: Double?, _ digits: Int) -> String {
        let s = SessionHistory.number(v, digits)
        return language == .en ? s.replacingOccurrences(of: ",", with: ".") : s
    }

    static let table: Localizer = {
        guard let url = Bundle.main.url(forResource: "strings", withExtension: "json"),
              let data = try? Data(contentsOf: url), let t = try? Localizer(json: data) else {
            assertionFailure("strings.json is missing or invalid")
            return Localizer(table: [:])
        }
        return t
    }()

    /// `make` with the texts in Russian, whatever the interface's language: the files for the center.
    static func inRussian<T>(_ make: () throws -> T) rethrows -> T {
        let was = language
        language = .ru
        defer { language = was }
        return try make()
    }
}

/// `ru` in the app's language, with `values` in its `{0}`, `{1}` … slots.
func L(_ ru: String, _ values: Any...) -> String {
    let s = Loc.table.text(ru, Loc.language.rawValue)
    return values.isEmpty ? s : Localizer.fill(s, values.map { "\($0)" })
}

/// The form of a word that goes with the count `n`, given as its three Russian forms: 1 игра, 2 игры, 5 игр. English
/// and Kazakh pick theirs from the same three (game / games, ойын).
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    switch Localizer.pluralForm(n, Loc.language.rawValue) {
    case .one: return L(one)
    case .few: return L(few)
    case .many: return L(many)
    }
}
