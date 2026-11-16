import SwiftUI
import UIKit

/// The app's look: the Steppe Observatory in full sun. A crisp cream page, a clear sky, sunlit emerald grass and
/// sandstone gold, every shape drawn with a 2 pt deep ink outline and laid on a hard ink shadow, cel style: flat
/// fills, no blur, no gradients on the things you act on. Amber energy is the gaze's own colour (a lock charging, a
/// streak). Emerald is "go" (the main button), the sky and gold back the plates. Vermilion is kept for danger only
/// (a refused camera, the red signs). Heavy rounded type for titles, timers and callouts; tabular numerals for every
/// number a clinician or a parent reads. Spacing on a 4/8 pt grid.
/// Light on purpose: the bright page also lights the player's face for the camera, which night vision relies on.
enum Atlas {
    // The palette.
    static let emerald = Color(red: 0.278, green: 0.659, blue: 0.318)     // 47A851
    static let sky = Color(red: 0.220, green: 0.557, blue: 0.910)         // 388EE8
    static let gold = Color(red: 0.910, green: 0.659, blue: 0.220)        // E8A838
    static let cream = Color(red: 0.984, green: 0.957, blue: 0.886)       // FBF4E2
    static let energy = Color(red: 1.0, green: 0.541, blue: 0.118)        // FF8A1E
    /// The sky high up, where the backdrop starts: the clear sky mixed with white.
    static let skyPale = Color(red: 0.686, green: 0.824, blue: 0.965)     // AFD2F6
    /// Grass in the distance: emerald mixed with cream.
    static let grassPale = Color(red: 0.561, green: 0.776, blue: 0.533)   // 8FC688

    // The roles the screens use.
    static let paper = cream
    static let paperShade = Color(red: 0.953, green: 0.906, blue: 0.788)  // F3E7C9
    static let ink = Color(red: 0.114, green: 0.102, blue: 0.090)         // 1D1A17
    static let inkSoft = Color(red: 0.361, green: 0.333, blue: 0.298)     // 5C554C
    static let vermilion = Color(red: 0.761, green: 0.271, blue: 0.176)   // C2452D
    static let missGrey = Color(red: 0.639, green: 0.612, blue: 0.565)    // A39C90
    static let onAccent = cream
    /// The garden's life: leaves and the light that runs along the lianas.
    static let moss = emerald
    /// Fireflies, flowers and the other distractions.
    static let amber = gold
    /// The outline every shape gets.
    static let line: CGFloat = 2

    /// The same colours for SpriteKit.
    enum UI {
        static let paper = UIColor(red: 0.984, green: 0.957, blue: 0.886, alpha: 1)
        static let paperShade = UIColor(red: 0.953, green: 0.906, blue: 0.788, alpha: 1)
        static let ink = UIColor(red: 0.114, green: 0.102, blue: 0.090, alpha: 1)
        static let vermilion = UIColor(red: 0.761, green: 0.271, blue: 0.176, alpha: 1)
        static let missGrey = UIColor(red: 0.639, green: 0.612, blue: 0.565, alpha: 1)
        static let amber = UIColor(red: 0.910, green: 0.659, blue: 0.220, alpha: 1)
        static let emerald = UIColor(red: 0.278, green: 0.659, blue: 0.318, alpha: 1)
        static let sky = UIColor(red: 0.220, green: 0.557, blue: 0.910, alpha: 1)
        static let energy = UIColor(red: 1.0, green: 0.541, blue: 0.118, alpha: 1)
    }

    /// Titles, timers and callouts: heavy and rounded.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .rounded) }
    static let title = Font.system(size: 22, weight: .heavy, design: .rounded)
    static let body = Font.system(size: 17)
    static let caption = Font.system(size: 13)
    /// Numbers a clinician or a parent reads: plain, with every digit the same width, so columns line up.
    static func metric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        Font.system(size: size, weight: weight).monospacedDigit()
    }
    /// The wordmark: geometric and widely tracked (the caller adds the tracking), close to the brand's Michroma
    /// without bundling a font.
    static func wordmark(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }

    /// The one spring of the interface: fast, with a little overshoot.
    static let snap = Animation.spring(response: 0.28, dampingFraction: 0.72)

    /// One garden for every screen, so the lianas and trees stay put while the screens change in front of them.
    static let gardenSeed: UInt64 = 2026

    static func levelName(_ l: RhythmLevel) -> String {
        switch l {
        case .easy: return L("Лёгкий")
        case .normal: return L("Средний")
        case .hard: return L("Сложный")
        }
    }

    static func levelHint(_ l: RhythmLevel) -> String {
        switch l {
        case .easy: return L("Сильные доли. Можно моргать.")
        case .normal: return L("Больше нот, любой глаз, но одним.")
        case .hard: return L("Слева левый глаз, справа правый.")
        }
    }

    static func word(_ j: Judgement) -> String {
        switch j {
        case .perfect: return L("Точно")
        case .good: return L("Хорошо")
        case .ok: return L("Есть")
        case .miss: return L("Мимо")
        }
    }

    /// The point `radius` from `c` at `angle` (radians from 3 o'clock, clockwise on screen, where y points down).
    /// The cosine is taken in Double on purpose: with CGFloat around it, `cos` is ambiguous between the
    /// CoreGraphics and the Double overloads.
    static func polar(_ c: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        let dx: Double = cos(angle), dy: Double = sin(angle)
        return CGPoint(x: c.x + CGFloat(dx) * radius, y: c.y + CGFloat(dy) * radius)
    }

    /// A four-pointed star with curved sides, the atlas's mark for a note.
    static func star(_ c: CGPoint, _ r: CGFloat) -> Path {
        var p = Path()
        let tips = (0..<4).map { k in polar(c, r, Double(k) * .pi / 2 - .pi / 2) }
        p.move(to: tips[0])
        for k in 0..<4 {
            let ctrl = polar(c, r * 0.2, Double(k) * .pi / 2 - .pi / 4)
            p.addQuadCurve(to: tips[(k + 1) % 4], control: ctrl)
        }
        p.closeSubpath()
        return p
    }

    /// A cel-shaded orb: a flat body, a shade crescent on the lower right, a cream glint on the upper left, and the
    /// ink line round it. The warm-up's dot and the rhythm mode's notes.
    static func orb(_ g: inout GraphicsContext, _ p: CGPoint, _ r: CGFloat, fill: Color) {
        let body = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        g.fill(body, with: .color(fill))
        var shade = Path()
        shade.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        shade.addEllipse(in: CGRect(x: p.x - r * 1.25, y: p.y - r * 1.3, width: 2 * r, height: 2 * r))
        g.fill(shade, with: .color(ink.opacity(0.18)), style: FillStyle(eoFill: true))
        g.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.6, y: p.y - r * 0.65, width: r * 0.55, height: r * 0.4)),
               with: .color(cream.opacity(0.9)))
        g.stroke(body, with: .color(ink), lineWidth: line)
    }

    /// Rings that pulse out of a target while the eyes are on it: two at a time, 0.6 s each, from `from` pt out by
    /// `reach` pt, fading as they go. `k`: how much the eyes are on it, 0...1. They grow, they do not flash.
    static func pulses(_ g: inout GraphicsContext, _ p: CGPoint, from: CGFloat, reach: CGFloat, host: Double, k: Double) {
        guard k > 0 else { return }
        for phase in [0.0, 0.5] {
            let f = CGFloat((host * 1.6 + phase).truncatingRemainder(dividingBy: 1))
            let pr = from + reach * f
            g.stroke(Path(ellipseIn: CGRect(x: p.x - pr, y: p.y - pr, width: 2 * pr, height: 2 * pr)),
                     with: .color(energy.opacity(Double(1 - f) * k)), lineWidth: 3)
        }
    }

    /// A closed eyelid with three lashes, `w` wide: the eye a side note asks for.
    static func closedEye(_ c: CGPoint, _ w: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x - w / 2, y: c.y))
        p.addQuadCurve(to: CGPoint(x: c.x + w / 2, y: c.y), control: CGPoint(x: c.x, y: c.y + w * 0.6))
        for k: CGFloat in [-1, 0, 1] {
            let x = c.x + k * w * 0.27, y = c.y + w * 0.3 * (1 - abs(k) * 0.4)
            p.move(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x + k * w * 0.1, y: y + w * 0.24))
        }
        return p
    }

    /// Part of a circle from 12 o'clock, clockwise as the player sees it (y down), `fraction` of the way round.
    static func dial(_ c: CGPoint, _ r: CGFloat, _ fraction: Double) -> Path {
        var p = Path()
        let steps = max(2, Int(64 * fraction))
        for k in 0...steps {
            let pt = polar(c, r, -Double.pi / 2 + 2 * .pi * fraction * Double(k) / Double(steps))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    /// A slim leaf from `base`, `length` long, pointing at `angle` (radians, y down): the garden's leaf and the
    /// petal of its flowers.
    static func leaf(_ base: CGPoint, _ length: CGFloat, _ angle: Double, width: CGFloat? = nil) -> Path {
        let w = width ?? length * 0.34
        let tip = polar(base, length, angle)
        let mid = polar(base, length * 0.45, angle)
        var p = Path()
        p.move(to: base)
        p.addLine(to: polar(mid, w / 2, angle - .pi / 2))
        p.addLine(to: tip)
        p.addLine(to: polar(mid, w / 2, angle + .pi / 2))
        p.closeSubpath()
        return p
    }

    /// The SPANTHER mark (concept C, "locked pupil"): an iris with a slit pupil cut out of it, inside a hold ring
    /// open at the lower right. Drawn from the brand SVG's geometry (a 256 unit box) at `size` pt around `c`.
    /// `ring`: how much of the ring is drawn, 0...1 (it draws itself in on the menu); `slit`: the pupil's width
    /// as a share of the brand's.
    static func mark(_ c: CGPoint, size: CGFloat, ring: Double = 1, slit: Double = 1) -> Path {
        let k = size / 256
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + CGFloat(x - 128) * k, y: c.y + CGFloat(y - 128) * k) }
        var p = Path()
        // The iris, and the slit as a hole in it (even-odd fill).
        p.addEllipse(in: CGRect(x: c.x - 72 * k, y: c.y - 72 * k, width: 144 * k, height: 144 * k))
        let half = 30 * slit
        p.move(to: pt(128, 62))
        p.addQuadCurve(to: pt(128, 194), control: pt(128 + half, 128))
        p.addQuadCurve(to: pt(128, 62), control: pt(128 - half, 128))
        p.closeSubpath()
        // The ring: from 6 o'clock clockwise (on screen) for up to 300°, leaving the gap at the lower right.
        let sweep = 300 * min(1, max(0, ring))
        if sweep > 1 {
            let steps = max(2, Int(sweep / 4))
            var outer: [CGPoint] = [], inner: [CGPoint] = []
            for s in 0...steps {
                let deg = 90 + sweep * Double(s) / Double(steps)
                let a = deg * .pi / 180
                outer.append(pt(128 + 116 * cos(a), 128 + 116 * sin(a)))
                inner.append(pt(128 + 96 * cos(a), 128 + 96 * sin(a)))
            }
            p.move(to: outer[0])
            for q in outer.dropFirst() { p.addLine(to: q) }
            for q in inner.reversed() { p.addLine(to: q) }
            p.closeSubpath()
        }
        return p
    }
}

// MARK: - Shapes

/// A panel thrown on the slant: a parallelogram whose top edge sits `lean` pt to the right of its bottom edge. The
/// buttons, chips and banners.
struct Slant: InsettableShape {
    var lean: CGFloat = 10
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let l = min(lean, r.width / 4)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + l, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> Slant {
        var s = self
        s.inset += amount
        return s
    }
}

/// A plate with its top right and bottom left corners cut on the diagonal, like a brass plate of the observatory.
struct CutPlate: InsettableShape {
    var cut: CGFloat = 16
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = max(0, min(cut - inset, r.width / 3, r.height / 3))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> CutPlate {
        var s = self
        s.inset += amount
        return s
    }
}

/// A shape drawn the cel way: a hard ink shadow `depth` pt down and right, the flat fill, the ink outline.
struct InkSlab<S: InsettableShape>: View {
    let shape: S
    var fill: Color
    var depth: CGFloat = 4
    var shadow: Color = Atlas.ink
    var line: CGFloat = Atlas.line

    var body: some View {
        ZStack {
            shape.fill(shadow).offset(x: depth, y: depth)
            shape.fill(fill)
            shape.strokeBorder(Atlas.ink, lineWidth: line)
        }
    }
}

// MARK: - Buttons

/// The main button: an emerald slant with ink letters that presses down into its shadow.
struct AtlasPrimaryButton: ButtonStyle {
    var fill: Color = Atlas.emerald
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return configuration.label
            .font(.system(size: 18, weight: .heavy, design: .rounded))
            .foregroundStyle(Atlas.ink.opacity(enabled ? 1 : 0.5))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(InkSlab(shape: Slant(), fill: enabled ? fill : Atlas.paperShade, depth: down ? 1 : 4))
            .offset(x: down ? 3 : 0, y: down ? 3 : 0)
            .animation(Atlas.snap, value: down)
    }
}

/// The other buttons: a cream slant with ink letters.
struct AtlasSecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return configuration.label
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(Atlas.ink.opacity(enabled ? 1 : 0.4))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(InkSlab(shape: Slant(), fill: down ? Atlas.paperShade : Atlas.paper, depth: down ? 1 : 3))
            .offset(x: down ? 2 : 0, y: down ? 2 : 0)
            .animation(Atlas.snap, value: down)
    }
}

/// A plate laid over the world: cream on a slab of colour (gold unless said otherwise), both in ink outline, so
/// the plates stack like cut card.
struct AtlasPlate: ViewModifier {
    var padding: CGFloat = 16
    var accent: Color = Atlas.gold

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                ZStack {
                    InkSlab(shape: CutPlate(), fill: accent, depth: 0).offset(x: 6, y: 6)
                    InkSlab(shape: CutPlate(), fill: Atlas.paper, depth: 0)
                }
            }
    }
}

/// A small slanted chip (the menu's corner buttons, the HUD's counters). `border`: the outline's colour, ink unless
/// the chip warns; `fill`: cream unless it is the selected one.
struct AtlasChip: ViewModifier {
    var fill: Color = Atlas.paper
    var border: Color = Atlas.ink

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Slant(lean: 6).fill(Atlas.ink).offset(x: 3, y: 3)
                    Slant(lean: 6).fill(fill)
                    Slant(lean: 6).strokeBorder(border, lineWidth: Atlas.line)
                }
            }
    }
}

// MARK: - Motion

/// Slides a card in from the right with a tilt that springs flat, `order` × 45 ms after the screen shows, so a row of
/// cards lands one after another. With Reduce Motion it only fades in.
struct KineticEntrance: ViewModifier {
    let order: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let still = shown || reduceMotion
        return content
            .opacity(shown ? 1 : 0)
            .offset(x: still ? 0 : 64)
            .rotationEffect(.degrees(still ? 0 : -6), anchor: .bottomLeading)
            .scaleEffect(still ? 1 : 0.92)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? Animation.easeOut(duration: 0.15) : Atlas.snap.delay(0.045 * Double(order))) {
                    shown = true
                }
            }
    }
}

extension View {
    func atlasPlate(padding: CGFloat = 16, accent: Color = Atlas.gold) -> some View {
        modifier(AtlasPlate(padding: padding, accent: accent))
    }

    func atlasChip(fill: Color = Atlas.paper, border: Color = Atlas.ink) -> some View {
        modifier(AtlasChip(fill: fill, border: border))
    }

    /// The card lands with the others, in this place of the row.
    func kineticEntrance(order: Int = 0) -> some View { modifier(KineticEntrance(order: order)) }

    /// The chosen one of a row pops forward.
    func selectedPop(_ on: Bool) -> some View {
        scaleEffect(on ? 1.06 : 1)
            .zIndex(on ? 1 : 0)
            .animation(Atlas.snap, value: on)
    }

    /// A number that rolls to its new value instead of jumping, in tabular digits.
    func rolling<V: Equatable>(_ value: V) -> some View {
        monospacedDigit()
            .contentTransition(.numericText())
            .animation(Atlas.snap, value: value)
    }
}

/// A number that rolls up from zero when it appears (the digits turn over, tabular), then follows its value.
struct RollUp: View {
    let value: Double
    var font: Font = Atlas.display(30)
    let format: (Double) -> String
    @State private var shown = 0.0

    var body: some View {
        Text(format(shown))
            .font(font)
            .monospacedDigit()
            .contentTransition(.numericText())
            .onAppear { withAnimation(Atlas.snap.delay(0.12)) { shown = value } }
            .onChange(of: value) { v in withAnimation(Atlas.snap) { shown = v } }
            .accessibilityLabel(format(value))
    }
}

// MARK: - Backdrop

/// The sky behind the menus: clear high up and paling to cream at the horizon, a cel sun with an ink rim and flat
/// rays in the upper right, and two thin bands of far grass along the bottom edge with an ink line on top. Drawn once; light
/// enough that the screen still lights the player's face.
struct SunlitBackdrop: View {
    var body: some View {
        Canvas { g, size in
            let w = size.width, h = size.height
            g.fill(Path(CGRect(origin: .zero, size: size)),
                   with: .linearGradient(Gradient(colors: [Atlas.skyPale, Atlas.paper]),
                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.72)))
            // The sun: flat rays turning slowly would be one more thing to look at, so they stand still.
            let c = CGPoint(x: w * 0.9, y: h * 0.12), r = min(w, h) * 0.085
            var rays = Path()
            for k in 0..<12 {
                let a = Double(k) * .pi / 6
                rays.move(to: Atlas.polar(c, r * 1.25, a - 0.09))
                rays.addLine(to: Atlas.polar(c, r * 1.9, a))
                rays.addLine(to: Atlas.polar(c, r * 1.25, a + 0.09))
                rays.closeSubpath()
            }
            g.fill(rays, with: .color(Atlas.gold.opacity(0.45)))
            let sun = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            g.fill(sun, with: .color(Atlas.gold))
            g.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.62, y: c.y - r * 0.7, width: r * 0.9, height: r * 0.9)),
                   with: .color(Atlas.cream.opacity(0.55)))
            g.stroke(sun, with: .color(Atlas.ink), lineWidth: Atlas.line)
            // Far grass: two rolling bands.
            // A strip at the very bottom, mostly under the screens' margins, so text never sits on it.
            for (k, (top, colour)) in [(0.925, Atlas.grassPale), (0.962, Atlas.emerald)].enumerated() {
                var band = Path()
                let y0 = h * CGFloat(top)
                band.move(to: CGPoint(x: 0, y: h))
                band.addLine(to: CGPoint(x: 0, y: y0))
                let steps = 24
                for s in 1...steps {
                    let x = w * CGFloat(s) / CGFloat(steps)
                    let wave: Double = sin(Double(s) * (k == 0 ? 0.55 : 0.8) + Double(k) * 1.7)
                    band.addLine(to: CGPoint(x: x, y: y0 + CGFloat(wave) * h * 0.012))
                }
                band.addLine(to: CGPoint(x: w, y: h))
                band.closeSubpath()
                g.fill(band, with: .color(colour))
                g.stroke(band, with: .color(Atlas.ink), lineWidth: Atlas.line)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The 90-second probe's own colours and type, frozen with probe protocol 1 (look version 1): the stimulus a child
/// sees in session 1 must be the one they see in session 30, whatever the rest of the app looks like.
enum ProbeLook {
    static let paper = Color(red: 0.949, green: 0.925, blue: 0.882)       // F2ECE1
    static let ink = Color(red: 0.114, green: 0.141, blue: 0.220)         // 1D2438
    static let inkSoft = Color(red: 0.361, green: 0.384, blue: 0.459)     // 5C6275
    static let amber = Color(red: 0.851, green: 0.588, blue: 0.161)       // D99629
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
}
