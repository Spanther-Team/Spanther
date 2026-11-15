import SwiftUI
import UIKit

/// A course's export (architecture proposal, "Fitting the Excellent Brain and Fusion workflow"): files that sit next
/// to the center's own paperwork, with the same patient code and "Занятие 12 из 30": the per-course PDF (charts and the
/// table), the Excel table (semicolons, decimal commas, UTF-8 with a byte order mark, like the plays' table) and a zip
/// of the raw session CSVs with a one-page data dictionary. Written to a temporary folder for the share sheet; the
/// files leave the phone only through it. On the main actor: the PDF renders SwiftUI charts with ImageRenderer.
@MainActor
enum ClinicExport {
    /// The three files of a course, made fresh. Main thread (the PDF draws SwiftUI charts).
    static func files(_ data: CourseData, sems: [ProbeMetric: Double], store: ClinicStore?) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clinic-export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "SPANTHER_\(safe(data.record.child.code))_\(safe(data.course.title))"
        var urls: [URL] = []
        let pdfURL = dir.appendingPathComponent(base + ".pdf")
        if (try? pdf(data, sems: sems).write(to: pdfURL)) != nil { urls.append(pdfURL) }
        let csvURL = dir.appendingPathComponent(base + ".csv")
        if (try? Data(("\u{FEFF}" + table(data, sems: sems)).utf8).write(to: csvURL)) != nil { urls.append(csvURL) }
        let zipURL = dir.appendingPathComponent(base + "_raw.zip")
        if (try? rawZip(data, store: store).write(to: zipURL)) != nil { urls.append(zipURL) }
        return urls
    }

    private static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<> ")
        return s.components(separatedBy: bad).filter { !$0.isEmpty }.joined(separator: "-")
    }

    // MARK: The table

    static let tableMetrics: [ProbeMetric] = ProbeMetric.allCases.filter { ![.validShare, .fps, .radiusDeg].contains($0) }

    /// One session per row: the course's place, the quality gate and why it failed, every probe number in shown units,
    /// the conditions, the tags, and what rebuilds the form (seed, versions).
    static func table(_ data: CourseData, sems: [ProbeMetric: Double]) -> String {
        var head = ["Код", "Курс", "Занятие", "Из", "Дата", "Время", "Место", "Контроль качества", "Причины"]
        head += tableMetrics.map { m in ClinicText.unit(m).isEmpty ? ClinicText.name(m) : "\(ClinicText.name(m)), \(ClinicText.unit(m))" }
        head += ["Ошибка калибровки, см", "Расстояние, см", "Кадров в секунду", "Свет, лм", "Нагрев", "Энергосбережение",
                 "Ночное зрение", "Батарея, %", "Версия приложения", "Устройство", "Теги", "Заметка", "Seed",
                 "Версия пробы", "Версия генератора"]
        var rows = [head]
        let day = DateFormatter(), time = DateFormatter()
        day.locale = Locale(identifier: "ru_RU")
        day.dateFormat = "dd.MM.yyyy"
        time.locale = Locale(identifier: "ru_RU")
        time.dateFormat = "HH:mm"
        for s in data.sessions {
            rows.append(tableRow(s, data, day: day, time: time))
        }
        return rows.map { $0.map(cell).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
    }

    /// One session's row, cell by cell: a long array literal of optionals is too slow for the type checker.
    private static func tableRow(_ s: Session, _ data: CourseData, day: DateFormatter, time: DateFormatter) -> [String] {
        let c = s.conditions
        let metrics: [String: Double] = s.probe?.metrics ?? [:]
        let completed: Bool = s.probe?.completed ?? false
        let limit = ProbeQuality.maxErrorCm(sessionStart: s.start, birthYear: data.record.child.birthYear)
        let issues = ProbeQuality.issues(conditions: c, metrics: metrics, completed: completed, maxErrorCm: limit)
        var row: [String] = []
        row.append(data.record.child.code)
        row.append(data.course.title)
        row.append(s.number.map { String($0) } ?? "")
        row.append(String(data.course.plannedSessions))
        row.append(day.string(from: s.start))
        row.append(time.string(from: s.start))
        row.append(ClinicText.place(s.place))
        row.append(s.onChart ? "да" : "нет")
        row.append(s.onChart ? "" : issues.map(ClinicText.issue).joined(separator: ", "))
        for m in tableMetrics {
            if let v = metrics[m.rawValue], v.isFinite {
                row.append(ClinicText.number(ClinicText.shown(m, v), digits: ClinicText.digits(m) + 1))
            } else {
                row.append("")
            }
        }
        row.append(num(c.calibrationErrorCm, 2))
        row.append(num(c.distanceCm, 1))
        row.append(num(c.trackingFps, 0))
        row.append(num(c.lightLm, 0))
        row.append(c.thermal ?? "")
        row.append(flag(c.lowPower))
        row.append(flag(c.night))
        row.append(num(c.batteryUsed.map { $0 * 100 }, 1))
        row.append(c.appVersion ?? "")
        row.append(c.device ?? "")
        row.append(s.tags.joined(separator: ", "))
        row.append(s.note ?? "")
        if let p = s.probe {
            row.append(String(p.seed))
            row.append(String(p.version))
            row.append(String(p.generatorVersion))
        } else {
            row.append(contentsOf: ["", "", ""])
        }
        return row
    }

    private static func num(_ v: Double?, _ digits: Int) -> String {
        guard let v, v.isFinite else { return "" }
        return ClinicText.number(v, digits: digits)
    }

    private static func flag(_ v: Bool?) -> String { v.map { $0 ? "да" : "нет" } ?? "" }

    private static func cell(_ s: String) -> String {
        guard s.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: The raw files

    /// Every session's raw CSV under its number, and the data dictionary.
    static func rawZip(_ data: CourseData, store: ClinicStore?) -> Data {
        var zip = ZipArchive()
        zip.add("README.txt", text: dictionary(data))
        for s in data.sessions {
            guard let store, let url = store.csvURL(of: s, child: data.record.id),
                  let bytes = try? Data(contentsOf: url) else { continue }
            let n = s.number.map { String(format: "%02d", $0) } ?? "xx"
            zip.add("session-\(n).csv", data: bytes, modified: s.start)
        }
        return zip.data()
    }

    /// The one page that says what is in the files.
    static func dictionary(_ data: CourseData) -> String {
        var t = """
        SPANTHER: сырые данные курса «\(data.course.title)», код \(data.record.child.code)
        Игра для внимания с метриками взгляда. Не диагностика и не лечение.

        session-NN.csv: все кадры занятия NN, одна строка на кадр или событие; столбцы ищите по имени.
          kind: frame, probe_frame, calibration, check, tracking, event, asteroid, decoy, …
          time: время хоста, с (часы ARKit). target_*_pt, gaze_*_pt: цель и взгляд на экране, pt (60 pt ≈ 1 см).
          lookat_*_m, eyeaxis_*_m: пересечение лучей взгляда с плоскостью экрана, м. yaw/pitch/roll_rad: поза головы.
          distance_m: глаза — экран, м. pupil_u/v: зрачок относительно глаза (Vision). blink_l/r: веки 0…1.
          proc_ms: обработка кадра, мс. light_lm: свет, лм. video_format, thermal, low_power: условия съёмки.

        Таблица курса (.csv): одно занятие на строку; доли в %, времена в мс.

        """
        t += "Метрики пробы (90 с, одна и та же для всего курса, формы из seed):\n"
        for m in ProbeMetric.allCases {
            t += "  \(m.rawValue): \(ClinicText.name(m))" + (ClinicText.unit(m).isEmpty ? "" : ", \(ClinicText.unit(m))") + "\n"
        }
        t += """

        Контроль качества: ошибка калибровки ≤ 1,5 см (взрослый 1,0), расстояние 25–40 см, кадров со взглядом ≥ 75 %,
        ≥ 50 кадров/с, проба до конца. Занятия без контроля в таблице, но не в тренде.
        Погрешность (SEM, MDC) пока предварительная: по стартовым занятиям детей центра, до повторного исследования.
        """
        return t
    }

    // MARK: The PDF

    /// A4 landscape: the header with the code, the course and "занятие N из M", the course card and the table on the
    /// first page, the charts after it, and the line about what the numbers are not.
    static func pdf(_ data: CourseData, sems: [ProbeMetric: Double]) -> Data {
        let page = CGRect(x: 0, y: 0, width: 842, height: 595)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let charts: [UIImage] = ProbeMetric.charted.compactMap { m in
            let view = MetricChart(data: data, metric: m, sem: sems[m]).frame(width: 380, height: 200)
            let r = ImageRenderer(content: view)
            r.scale = 2
            return r.uiImage
        }
        let card = ImageRenderer(content: CourseCard(data: data, sems: sems).frame(width: 380).padding(8))
        card.scale = 2
        return renderer.pdfData { ctx in
            ctx.beginPage()
            let title = "\(data.record.child.code) · \(data.course.title) · занятие \(data.sessions.last?.number ?? 0) из \(data.course.plannedSessions)"
            draw(title, at: CGPoint(x: 36, y: 30), size: 20, bold: true)
            draw("SPANTHER · \(ClinicText.place(data.course.runsAt)) · начат \(ClinicText.date.string(from: data.course.started))"
                 + " · выгружено \(ClinicText.date.string(from: Date()))", at: CGPoint(x: 36, y: 58), size: 11)
            if let image = card.uiImage { image.draw(in: CGRect(x: 36, y: 84, width: 380, height: 380 * image.size.height / max(1, image.size.width))) }
            drawTable(data, in: CGRect(x: 440, y: 84, width: 366, height: 460))
            draw("Игра для внимания с метриками взгляда; не диагностика и не лечение.", at: CGPoint(x: 36, y: 560), size: 9)
            for (i, image) in charts.enumerated() {
                if i % 4 == 0 { ctx.beginPage() }
                let k = i % 4
                let x = 36 + CGFloat(k % 2) * 395, y = 36 + CGFloat(k / 2) * 270
                image.draw(in: CGRect(x: x, y: y, width: 380, height: 380 * image.size.height / max(1, image.size.width)))
            }
        }
    }

    private static func draw(_ text: String, at p: CGPoint, size: CGFloat, bold: Bool = false) {
        let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        (text as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: UIColor.black])
    }

    /// The sessions as a small table: number, date, the three headline numbers, the gate.
    private static func drawTable(_ data: CourseData, in rect: CGRect) {
        let heads = ["№", "Дата"] + ClinicText.headline.map { ClinicText.unit($0).isEmpty ? ClinicText.name($0) : ClinicText.unit($0) } + ["Контроль"]
        let widths: [CGFloat] = [28, 74, 70, 70, 70, 54]
        var y = rect.minY
        func row(_ cells: [String], bold: Bool) {
            var x = rect.minX
            for (i, c) in cells.enumerated() where i < widths.count {
                draw(c, at: CGPoint(x: x, y: y), size: 9, bold: bold)
                x += widths[i]
            }
            y += 14
        }
        row(heads, bold: true)
        let day = DateFormatter()
        day.locale = Locale(identifier: "ru_RU")
        day.dateFormat = "dd.MM.yy"
        for s in data.sessions where y < rect.maxY - 14 {
            let m = s.probe?.metrics ?? [:]
            row([s.number.map { String($0) } ?? "", day.string(from: s.start)]
                + ClinicText.headline.map { ClinicText.value($0, m[$0.rawValue]) } + [s.onChart ? "да" : "нет"], bold: false)
        }
    }
}
