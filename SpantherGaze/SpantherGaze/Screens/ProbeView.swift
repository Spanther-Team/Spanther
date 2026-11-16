import SwiftUI

/// The frozen 90-second probe (architecture proposal §1): its own frozen look (`ProbeLook`), whatever the rest of the
/// app looks like: plain paper, nothing else to look at, and one fixed look
/// for its targets (version 1 with probe protocol 1): an ink ring with an amber centre whose arc fills over the hold,
/// a pop and the fixed wood chime when it is held, a quiet fade when its time runs out. The gliding target has the
/// same look; a distractor is a small amber star burst. A thin line at the top shows the time left.
struct ProbeView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let session = app.probe {
                    ProbeStage(session: session)
                    ProbeDone(session: session)
                } else {
                    Text(app.probePreparing ? "Готовим задание…" : " ")
                        .font(ProbeLook.display(22))
                        .foregroundStyle(ProbeLook.inkSoft)
                }
                VStack {
                    HStack {
                        Spacer()
                        Button { app.route = .clinic } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(ProbeLook.ink.opacity(0.5))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Остановить пробу")
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.trailing, 16)
            }
            .onAppear { app.beginProbe(screen: Vec2(Double(geo.size.width), Double(geo.size.height))) }
        }
        .ignoresSafeArea()
    }
}

/// The probe's drawing, 60 times a second from the session's clock.
private struct ProbeStage: View {
    @ObservedObject var session: ProbeSession

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = CACurrentMediaTime()
            Canvas { g, size in
                draw(&g, size: size, now: now)
            }
            .overlay(alignment: .center) {
                if session.time(host: now) < session.plan.rules.quietStartSec, session.phase == .running {
                    Text("Смотри на кружки")
                        .font(ProbeLook.display(22))
                        .foregroundStyle(ProbeLook.inkSoft)
                        .offset(y: 70)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, now: Double) {
        guard session.phase == .running else { return }
        let t = session.time(host: now)
        let rules = session.plan.rules
        // Time left: a thin ink line along the top.
        let share = max(0, min(1, t / rules.durationSec))
        var line = Path()
        line.move(to: CGPoint(x: 0, y: 2))
        line.addLine(to: CGPoint(x: size.width * (1 - share), y: 2))
        g.stroke(line, with: .color(ProbeLook.ink.opacity(0.18)), lineWidth: 3)
        let r = CGFloat(max(12, session.mapping.length(fromDeg: 0.6)))
        if t < rules.quietStartSec {
            dot(&g, at: CGPoint(x: size.width / 2, y: size.height / 2), r: r * 0.35, color: ProbeLook.ink.opacity(0.4))
        }
        if let i = session.run.visibleTarget {
            target(&g, at: point(session.targetPosition(i)), r: r, progress: session.run.holdProgress)
        }
        if let p = session.gliderPosition(host: now) {
            target(&g, at: point(p), r: r, progress: 0)
        }
        if let d = session.run.visibleDistractor {
            star(&g, at: point(session.distractorPosition(d)), r: r * 0.9)
        }
        // Held: the ring swells and fades for 0.3 s. Ran out: it fades for 0.2 s where it was.
        for (i, at) in session.held where now - at < 0.3 {
            let u = (now - at) / 0.3
            let c = point(session.targetPosition(i))
            let rr = r * CGFloat(1 + 0.8 * u)
            g.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)),
                     with: .color(ProbeLook.amber.opacity(0.9 * (1 - u))), lineWidth: 3)
        }
        for (i, at) in session.expired where now - at < 0.2 {
            let u = (now - at) / 0.2
            target(&g, at: point(session.targetPosition(i)), r: r, progress: 0, opacity: 1 - u)
        }
    }

    private func point(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }

    private func dot(_ g: inout GraphicsContext, at c: CGPoint, r: CGFloat, color: Color) {
        g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
    }

    /// The probe's target, version 1: an ink ring, an amber centre, and the hold's arc from 12 o'clock.
    private func target(_ g: inout GraphicsContext, at c: CGPoint, r: CGFloat, progress: Double, opacity: Double = 1) {
        g.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                 with: .color(ProbeLook.ink.opacity(0.85 * opacity)), lineWidth: 2)
        dot(&g, at: c, r: r * 0.38, color: ProbeLook.amber.opacity(opacity))
        if progress > 0 {
            var arc = Path()
            arc.addArc(center: c, radius: r + 5, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * progress),
                       clockwise: false)
            g.stroke(arc, with: .color(ProbeLook.ink.opacity(opacity)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    /// The distractor, version 1: a small amber star burst.
    private func star(_ g: inout GraphicsContext, at c: CGPoint, r: CGFloat) {
        g.fill(Atlas.star(c, r), with: .color(ProbeLook.amber))
        var rays = Path()
        for k in 0..<8 {
            let a = Double(k) * Double.pi / 4
            rays.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * r * 1.2, y: c.y + CGFloat(sin(a)) * r * 1.2))
            rays.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r * 1.7, y: c.y + CGFloat(sin(a)) * r * 1.7))
        }
        g.stroke(rays, with: .color(ProbeLook.amber.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }
}

/// After the probe: a reward line for the child and, for the clinician, the session's card: the main numbers and,
/// when the session failed the quality gate, why it stays off the chart.
private struct ProbeDone: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: ProbeSession

    var body: some View {
        if session.phase == .done {
            ZStack {
                // The probe is over: the sunlit world comes back for the reward.
                SunlitBackdrop().ignoresSafeArea()
                done
                    .kineticEntrance()
            }
        }
    }

    private var done: some View {
        VStack(spacing: 14) {
            Text("Готово!").font(Atlas.display(30)).foregroundStyle(Atlas.ink)
            if app.clinic.role == .clinician, let outcome = app.probeOutcome {
                SessionCard(session: outcome.session, issues: outcome.issues)
            } else {
                Text("Отличная работа! Теперь можно поиграть.")
                    .font(Atlas.body)
                    .foregroundStyle(Atlas.inkSoft)
            }
            HStack(spacing: 12) {
                Button { app.route = .clinic } label: { Text("К профилю") }
                    .buttonStyle(AtlasSecondaryButton())
                Button {
                    app.mode = .eyes
                    app.route = .game
                } label: { Text("Играть") }
                    .buttonStyle(AtlasPrimaryButton())
            }
        }
        .atlasPlate(padding: 20)
    }
}

/// One session's numbers for the clinician: the probe's main metrics and its conditions; a failed quality gate says
/// why in words, and the session stays off the trend.
struct SessionCard: View {
    let session: Session
    let issues: [ProbeQuality.Issue]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let n = session.number { Text("Занятие \(n)").font(Atlas.title).foregroundStyle(Atlas.ink) }
            if let m = session.probe?.metrics {
                ForEach(ClinicText.headline, id: \.self) { metric in
                    HStack {
                        Text(ClinicText.name(metric)).foregroundStyle(Atlas.inkSoft)
                        Spacer(minLength: 16)
                        Text(ClinicText.value(metric, m[metric.rawValue])).font(Atlas.metric(13)).foregroundStyle(Atlas.ink)
                    }
                    .font(Atlas.caption)
                }
            }
            if issues.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Atlas.emerald)
                    Text("Контроль качества пройден").foregroundStyle(Atlas.ink)
                }
                .font(Atlas.caption.weight(.semibold))
            } else {
                Text("Не на графике: " + issues.map(ClinicText.issue).joined(separator: ", "))
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.vermilion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 360)
    }
}
