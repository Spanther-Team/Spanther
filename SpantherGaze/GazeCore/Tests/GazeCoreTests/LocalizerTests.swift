import Foundation
import XCTest
@testable import GazeCore

/// The interface's three languages: the translation table (Resources/strings.json) against the app's code.
final class LocalizerTests: XCTestCase {
    // MARK: The rules

    func testFillPutsValuesInTheirSlotsInAnyOrder() {
        XCTAssertEqual(Localizer.fill("{1} ★ more to “{0}”", ["Dome", "3"]), "3 ★ more to “Dome”")
        XCTAssertEqual(Localizer.fill("Звёзд {0} из 3", ["2"]), "Звёзд 2 из 3")
        XCTAssertEqual(Localizer.fill("{0} и {5}", ["a"]), "a и {5}")
        XCTAssertEqual(Localizer.fill("без значений {0}", []), "без значений {0}")
        XCTAssertEqual(Localizer.slots("{0}: занятие {1} из {2}, {3}"), [0, 1, 2, 3])
    }

    func testFormatsKeepOrderAndSkipPercentSigns() {
        XCTAssertEqual(Localizer.formats("Сбито %.0f%% · Уровень %d"), ["%.0f", "%d"])
        XCTAssertEqual(Localizer.formats("%.0f уд/мин · %ld:%02ld · %@"), ["%.0f", "%ld", "%02ld", "%@"])
        XCTAssertEqual(Localizer.formats("%+.0f мс"), ["%+.0f"])
        XCTAssertEqual(Localizer.formats("\u{00A0}% of targets, {0}% smaller"), [])
    }

    func testTextFallsBackToRussian() {
        let t = Localizer(table: ["Меню": ["en": "Menu", "kk": ""]])
        XCTAssertEqual(t.text("Меню", "en"), "Menu")
        XCTAssertEqual(t.text("Меню", "kk"), "Меню")
        XCTAssertEqual(t.text("Меню", "ru"), "Меню")
        XCTAssertEqual(t.text("Нет в таблице", "en"), "Нет в таблице")
    }

    func testPluralForms() {
        let ru = [1, 2, 5, 11, 12, 21, 22, 25, 111, 104].map { Localizer.pluralForm($0, "ru") }
        XCTAssertEqual(ru, [.one, .few, .many, .many, .many, .one, .few, .many, .many, .few])
        XCTAssertEqual([0, 1, 2, 5, 21].map { Localizer.pluralForm($0, "en") }, [.few, .one, .few, .few, .few])
        XCTAssertEqual([1, 2, 5].map { Localizer.pluralForm($0, "kk") }, [.one, .one, .one])
    }

    // MARK: The table against the app

    /// SpantherGaze/SpantherGaze, the app's sources, next to this package.
    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("SpantherGaze")

    private func table() throws -> Localizer {
        let url = Self.app.appendingPathComponent("Resources/strings.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "the app's sources are not here")
        return try Localizer(json: Data(contentsOf: url))
    }

    func testEveryTranslationKeepsItsSlotsAndFormats() throws {
        let t = try table()
        XCTAssertGreaterThan(t.table.count, 300)
        for (ru, row) in t.table {
            for lang in ["en", "kk"] {
                guard let s = row[lang], !s.isEmpty else {
                    XCTFail("strings.json: «\(ru)» has no \(lang)")
                    continue
                }
                XCTAssertEqual(Localizer.slots(s), Localizer.slots(ru), "strings.json \(lang): «\(ru)» → «\(s)»")
                if !Localizer.formats(ru).isEmpty {
                    XCTAssertEqual(Localizer.formats(s), Localizer.formats(ru), "strings.json \(lang): «\(ru)» → «\(s)»")
                }
                XCTAssertEqual(s.hasPrefix(" "), ru.hasPrefix(" "), "strings.json \(lang): «\(ru)» → «\(s)»")
            }
        }
    }

    /// Every text the app gives to `L` or `plural`, and the Russian names kept in data and shown through `L`, is in
    /// strings.json with both translations.
    func testEveryTextInTheAppIsTranslated() throws {
        let t = try table()
        var used: [String: String] = [:]
        for (file, src) in try sources() {
            let lines = src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let code = lines.joined(separator: "\n")
            for key in Self.matches(#"\bL\("((?:[^"\\]|\\.)*)""#, in: code) { used[Self.unescape(key)] = file }
            let lit = #""((?:[^"\\]|\\.)*)""#
            for key in Self.matches(#"\bplural\([^,]+,\s*"# + lit + #",\s*"# + lit + #",\s*"# + lit + #"\)"#, in: code) {
                used[Self.unescape(key)] = file
            }
            for key in Self.matches(#"Landmark\(name: "# + lit, in: code) { used[Self.unescape(key)] = file }
            if let gifts = Self.matches(#"giftNames = \[(.*)\]"#, in: code).first {
                for key in Self.matches(lit, in: gifts) { used[Self.unescape(key)] = file }
            }
        }
        let tracks = try JSONSerialization.jsonObject(
            with: Data(contentsOf: Self.app.appendingPathComponent("Resources/tracks.json"))) as? [[String: Any]] ?? []
        for track in tracks { if let title = track["title"] as? String { used[title] = "tracks.json" } }
        for g in [SessionSummary.Game.meteors, .rhythm, .pursuit] { used[SessionHistory.gameName(g)] = "SessionReport" }

        XCTAssertGreaterThan(used.count, 300)
        for (key, file) in used.sorted(by: { $0.key < $1.key }) {
            let row = t.table[key] ?? [:]
            XCTAssertTrue(!(row["en"] ?? "").isEmpty && !(row["kk"] ?? "").isEmpty,
                          "\(file): «\(key)» needs its English and Kazakh in Resources/strings.json")
        }
    }

    /// A Russian text on screen goes through `L`. The files that are Russian on purpose: the start screen (its own
    /// three languages), the center's export files, the debug overlay, and the made-up plays of the screenshots.
    func testNoRussianTextBypassesL() throws {
        _ = try table()
        let russianOnPurpose: Set<String> = ["StartGate.swift", "ClinicExport.swift", "DebugOverlay.swift", "AppModel.swift",
                                             "Loc.swift"]
        // The CI bot's child and course.
        let allowed: Set<String> = ["Бот", "Курс CI"]
        for (file, src) in try sources() where !russianOnPurpose.contains((file as NSString).lastPathComponent) {
            for lit in SwiftLiterals.scan(src) where lit.text.unicodeScalars.contains(where: { (0x400...0x4FF).contains($0.value) }) {
                if lit.before.hasSuffix("L(") || lit.lineBefore.contains("plural(") || lit.lineBefore.contains("Landmark(name:")
                    || lit.lineBefore.contains("giftNames = [") || allowed.contains(lit.text) {
                    continue
                }
                XCTFail("\(file):\(lit.line): «\(lit.text)» is shown without L(…): write L(\"…\") and add it to strings.json")
            }
        }
    }

    // MARK: Helpers

    private func sources() throws -> [(String, String)] {
        let root = Self.app
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in e where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            out.append((rel, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 10)
        return out.sorted { $0.0 < $1.0 }
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        var out: [String] = []
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            for g in 1..<m.numberOfRanges where m.range(at: g).location != NSNotFound {
                out.append(ns.substring(with: m.range(at: g)))
            }
        }
        return out
    }

    /// A Swift literal's text as the program sees it.
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = Array(s)[...]
        while let c = it.popFirst() {
            guard c == "\\", let e = it.popFirst() else { out.append(c); continue }
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "u":
                var hex = ""
                if it.first == "{" { it.removeFirst() }
                while let h = it.popFirst(), h != "}" { hex.append(h) }
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            default: out.append(e)
            }
        }
        return out
    }
}

/// The plain string literals of Swift source, as written, past comments, multi-line and raw strings.
enum SwiftLiterals {
    struct Literal {
        /// Between the quotes, escapes and interpolations as written.
        let text: String
        let line: Int
        /// The source just before the opening quote, and the line up to it.
        let before: String
        let lineBefore: String
    }

    static func scan(_ src: String) -> [Literal] {
        let c = Array(src)
        var out: [Literal] = []
        var i = 0, line = 1
        func at(_ k: Int, _ s: String) -> Bool {
            let p = Array(s)
            guard k + p.count <= c.count else { return false }
            return (0..<p.count).allSatisfy { c[k + $0] == p[$0] }
        }
        /// From the opening quote at `k`: the index after the closing one.
        func string(_ k: Int) -> Int {
            var j = k + 1
            while j < c.count {
                if c[j] == "\\", j + 1 < c.count, c[j + 1] == "(" {
                    j = interpolation(j + 2)
                } else if c[j] == "\\" {
                    j += 2
                } else if c[j] == "\"" || c[j] == "\n" {
                    return j + 1
                } else {
                    j += 1
                }
            }
            return j
        }
        func interpolation(_ k: Int) -> Int {
            var depth = 1, j = k
            while j < c.count {
                if c[j] == "\"" { j = string(j); continue }
                if c[j] == "(" { depth += 1 }
                if c[j] == ")" { depth -= 1; if depth == 0 { return j + 1 } }
                j += 1
            }
            return j
        }
        while i < c.count {
            if c[i] == "\n" { line += 1; i += 1; continue }
            if at(i, "//") {
                while i < c.count, c[i] != "\n" { i += 1 }
                continue
            }
            if at(i, "/*") || at(i, "\"\"\"") || at(i, "#\"") {
                let close = at(i, "/*") ? "*/" : at(i, "#\"") ? "\"#" : "\"\"\""
                i += at(i, "\"\"\"") ? 3 : 2
                while i < c.count, !at(i, close) {
                    if c[i] == "\n" { line += 1 }
                    i += 1
                }
                i += close.count
                continue
            }
            if c[i] == "\"" {
                let end = string(i)
                var lineStart = i
                while lineStart > 0, c[lineStart - 1] != "\n" { lineStart -= 1 }
                out.append(Literal(text: String(c[(i + 1)..<max(i + 1, end - 1)]), line: line,
                                   before: String(c[max(0, i - 2)..<i]), lineBefore: String(c[lineStart..<i])))
                i = end
                continue
            }
            i += 1
        }
        return out
    }
}
