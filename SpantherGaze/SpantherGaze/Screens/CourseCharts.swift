import Charts
import SwiftUI

/// One course's numbers, session by session (architecture proposal, "The course chart"): each metric's values in
/// course order and whether the session passed the quality gate, the procedure marks between sessions, and from them
/// the baseline band, the Theil–Sen trend and the change against the baseline. The charts, the course card and the
/// export all read it.
struct CourseData {
    struct Point: Identifiable {
        let id: UUID
        let number: Int
        /// As shown: shares in percent.
        let value: Double
        let onChart: Bool
    }

    struct Mark: Identifiable {
        let id: UUID
        /// Between two sessions on the x axis: 3.5 is after session 3.
        let x: Double
        let label: String
    }

    let record: ChildRecord
    let course: Course
    /// The course's numbered sessions, in order.
    let sessions: [Session]
    let marks: [Mark]

    static let baselineCount = 3

    init(record: ChildRecord, course: Course) {
        self.record = record
        self.course = course
        let list = record.sessions(of: course.id).filter { $0.number != nil }.sorted { ($0.number ?? 0) < ($1.number ?? 0) }
        sessions = list
        marks = course.procedures.map { p in
            let before = list.last { $0.start <= p.date }?.number ?? 0
            return Mark(id: p.id, x: Double(before) + 0.5, label: p.label ?? ClinicText.procedure(p.kind))
        }
    }

    /// The x axis: the planned sessions, or more if the course ran longer.
    var lastNumber: Int { max(course.plannedSessions, sessions.last?.number ?? 0) }

    func points(_ m: ProbeMetric) -> [Point] {
        sessions.compactMap { s in
            guard let n = s.number, let v = s.probe?.metrics[m.rawValue], v.isFinite else { return nil }
            return Point(id: s.id, number: n, value: ClinicText.shown(m, v), onChart: s.onChart)
        }
    }

    /// The values of the sessions that passed the gate, in order (shown units).
    func charted(_ m: ProbeMetric) -> [Double] { points(m).filter(\.onChart).map(\.value) }

    func trend(_ m: ProbeMetric) -> CourseStats.Trend? {
        CourseStats.theilSen(points(m).filter(\.onChart).map { (x: Double($0.number), y: $0.value) })
    }

    func band(_ m: ProbeMetric, sem: Double?) -> ClosedRange<Double>? {
        guard let sem else { return nil }
        return CourseStats.baselineBand(charted(m), sem: sem, baselineCount: Self.baselineCount)
    }

    func change(_ m: ProbeMetric, sem: Double?) -> CourseStats.Change? {
        CourseStats.change(charted(m), better: m.better, sem: sem, baselineCount: Self.baselineCount)
    }

    /// The measurement error of a metric (shown units), estimated from the clinic's own children: the spread inside
    /// each child's baseline sessions, pooled. An estimate until the test-retest study gives an ICC: the screens and
    /// the export call it preliminary.
    static func sem(_ m: ProbeMetric, records: [ChildRecord]) -> Double? {
        var groups: [[Double]] = []
        for r in records {
            for c in r.courses {
                let d = CourseData(record: r, course: c)
                let base = Array(d.charted(m).prefix(baselineCount))
                if base.count >= 2 { groups.append(base) }
            }
        }
        return CourseStats.pooledWithinSD(groups)?.sd
    }
}

/// One chart per metric, sessions on the x axis: the baseline band (sessions 1 to 3 widened by the measurement
/// error), the trend with its 90% interval, filled points for sessions that passed the quality gate and hollow ones
/// for those that did not, and small marks for TMS, laser or neurofeedback.
struct MetricChart: View {
    let data: CourseData
    let metric: ProbeMetric
    let sem: Double?

    var body: some View {
        let points = data.points(metric)
        let band = data.band(metric, sem: sem)
        let trend = data.trend(metric)
        let xs = points.filter(\.onChart).map { Double($0.number) }
        let label = ClinicText.name(metric)
        VStack(alignment: .leading, spacing: 4) {
            Text(ClinicText.unit(metric).isEmpty ? label : "\(label), \(ClinicText.unit(metric))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Atlas.ink)
            Chart {
                if let band {
                    RectangleMark(xStart: .value(L("Занятие"), 0.5), xEnd: .value(L("Занятие"), Double(data.lastNumber) + 0.5),
                                  yStart: .value(label, band.lowerBound), yEnd: .value(label, band.upperBound))
                        .foregroundStyle(Atlas.moss.opacity(0.13))
                }
                if let trend, let first = xs.first, let last = xs.last, last > first {
                    ForEach(Self.steps(first, last), id: \.self) { x in
                        if let b = trend.band(at: x) {
                            AreaMark(x: .value(L("Занятие"), x), yStart: .value(label, b.lowerBound), yEnd: .value(label, b.upperBound))
                                .foregroundStyle(Atlas.ink.opacity(0.07))
                        }
                    }
                    ForEach([first, last], id: \.self) { x in
                        LineMark(x: .value(L("Занятие"), x), y: .value(label, trend.value(at: x)), series: .value(L("Ряд"), "trend"))
                            .foregroundStyle(Atlas.ink.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                ForEach(data.marks) { mark in
                    RuleMark(x: .value(L("Занятие"), mark.x))
                        .foregroundStyle(Atlas.amber.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .annotation(position: .top, alignment: .center) {
                            Text(mark.label).font(.system(size: 9)).foregroundStyle(Atlas.inkSoft)
                        }
                }
                ForEach(points) { p in
                    PointMark(x: .value(L("Занятие"), Double(p.number)), y: .value(label, p.value))
                        .symbol {
                            if p.onChart {
                                Circle().fill(Atlas.ink).frame(width: 7, height: 7)
                            } else {
                                Circle().strokeBorder(Atlas.ink.opacity(0.6), lineWidth: 1.4).frame(width: 8, height: 8)
                            }
                        }
                }
            }
            .chartXScale(domain: 0.5...(Double(data.lastNumber) + 0.5))
            .chartXAxis {
                AxisMarks(values: Self.ticks(data.lastNumber)) { _ in
                    AxisGridLine().foregroundStyle(Atlas.ink.opacity(0.06))
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
        }
        .padding(10)
        // Charts stay calm: a flat cream plate in ink outline, no coloured slab behind.
        .background(InkSlab(shape: CutPlate(cut: 12), fill: Atlas.paper, depth: 3))
    }

    private static func steps(_ a: Double, _ b: Double) -> [Double] {
        let n = 12
        return (0...n).map { a + (b - a) * Double($0) / Double(n) }
    }

    private static func ticks(_ last: Int) -> [Double] {
        let step = last > 15 ? 5 : (last > 6 ? 2 : 1)
        return stride(from: 1, through: last, by: step).map(Double.init)
    }
}

/// The course card: the last three sessions against the baseline (sessions 1 to 3), in the metric's units and in
/// multiples of the minimal detectable change. The measurement error is the clinic's own preliminary estimate, so no
/// change is coloured: the colours wait for the test-retest study (architecture proposal, phase 3).
struct CourseCard: View {
    let data: CourseData
    let sems: [ProbeMetric: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Последние 3 занятия против первых 3")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Atlas.ink)
            ForEach(ProbeMetric.charted, id: \.self) { m in
                HStack(alignment: .firstTextBaseline) {
                    Text(ClinicText.name(m)).foregroundStyle(Atlas.inkSoft)
                    Spacer(minLength: 12)
                    Text(line(m)).font(Atlas.metric(13)).foregroundStyle(Atlas.ink)
                }
                .font(.system(size: 13))
            }
            Text(L("Погрешность оценена по стартовым занятиям детей этого центра; это предварительная оценка до повторного исследования."))
                .font(.system(size: 11))
                .foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ m: ProbeMetric) -> String {
        guard let c = data.change(m, sem: sems[m]) else { return L("нужно больше занятий") }
        let d = ClinicText.digits(m)
        var s = "\(ClinicText.number(c.baseline, digits: d)) → \(ClinicText.number(c.recent, digits: d))"
        let sign = c.delta > 0 ? "+" : ""
        s += " (\(sign)\(ClinicText.number(c.delta, digits: d))"
        if let k = c.inMDC { s += "; \(ClinicText.number(k, digits: 1))\u{00A0}MDC" }
        return s + ")"
    }
}

/// The parent's view of a course: how many sessions are done and three numbers in plain words, at the start of the
/// course and now. No clinical terms and no verdicts.
struct ParentSummary: View {
    let data: CourseData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("{0}: занятий {1} из {2}", data.course.title, data.sessions.count, data.course.plannedSessions))
                .font(Atlas.title)
                .foregroundStyle(Atlas.ink)
            ForEach(ClinicText.parentMetrics, id: \.0) { metric, words in
                let values = data.sessions.filter(\.onChart).compactMap { $0.probe?.metrics[metric.rawValue] }
                VStack(alignment: .leading, spacing: 2) {
                    Text(words).font(Atlas.body).foregroundStyle(Atlas.ink)
                    Text(L("в начале: {0}", ClinicText.parentValue(metric, CourseStats.mean(Array(values.prefix(3)))))
                         + L(" · сейчас: {0}", ClinicText.parentValue(metric, CourseStats.mean(Array(values.suffix(3))))))
                        .font(Atlas.metric(13, weight: .regular))
                        .foregroundStyle(Atlas.inkSoft)
                }
            }
            Text(L("Это результаты игры, а не диагноз. Подробнее расскажет специалист."))
                .font(Atlas.caption)
                .foregroundStyle(Atlas.inkSoft)
        }
    }
}
