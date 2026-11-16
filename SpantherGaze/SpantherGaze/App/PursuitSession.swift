import Foundation

/// One 60-second warm-up: a target glides across the screen (GazeCore's `PursuitPlan`) and every frame the distance
/// from the gaze to it is counted (`PursuitTally`). Host time (CACurrentMediaTime, the clock ARKit's frames share)
/// in, screen pt everywhere.
final class PursuitSession: ObservableObject {
    enum Phase: Equatable {
        /// The target rests in the centre while the player finds it.
        case countdown
        case running
        case done
    }

    @Published private(set) var phase: Phase = .countdown

    let plan = PursuitPlan()
    /// The screen the target moves on (screen pt).
    let screen: Vec2
    let byEye: Bool
    /// The gaze counts as on the target within this distance (screen pt).
    let radiusPt: Double
    /// «Мелкие цели»: the drawn target's scale.
    let targetScale: Double
    /// Host time at which the target starts to move. A wait for the face moves it later.
    var startHost: Double { clock.startHost }
    private var clock: PursuitClock
    private(set) var tally: PursuitTally
    /// The camera has not seen the face for a while: the target waits, and the screen says what to do.
    @Published private(set) var waitingForFace = false
    private var faceLostSince: Double?
    /// Frames the aim learned from the target while the eyes followed it (`AppModel.handle`).
    var taught = 0

    /// The target waits once the face has been out of the camera's sight this long (s). A blink does not lose the
    /// face, so this is the phone held too near, turned away or covered by a hand.
    static let faceWaitSec = 0.5

    /// Seconds the target rests before it moves.
    static let countdownSec = 4.0

    init(screen: Vec2, byEye: Bool, measuredErrorPt: Double?, targetScale: Double, now: Double) {
        self.screen = screen
        self.byEye = byEye
        self.targetScale = targetScale
        radiusPt = PursuitPlan.onTargetRadius(measuredErrorPt: byEye ? measuredErrorPt : nil)
        clock = PursuitClock(startHost: now + Self.countdownSec)
        tally = PursuitTally(radiusPt: radiusPt)
    }

    /// Seconds since the target started to move (negative during the countdown).
    func time(host: Double) -> Double { clock.time(host: host) }

    /// One tracking frame's news, by eye: did the camera see the face? Without it for `faceWaitSec` the target
    /// stops and the minute with it; both go on with the first frame that has the face again.
    func face(found: Bool, host: Double) {
        guard byEye, phase == .running else { return }
        if found {
            faceLostSince = nil
            if clock.isHeld {
                clock.resume(host: host)
                waitingForFace = false
            }
        } else {
            let since = faceLostSince ?? host
            faceLostSince = since
            if !clock.isHeld, host - since >= Self.faceWaitSec {
                clock.hold(host: host)
                waitingForFace = true
            }
        }
    }

    /// The target's centre at a host time (screen pt).
    func target(host: Double) -> Vec2 { plan.position(at: max(0, time(host: host)), in: screen) }

    /// Moves the phase on with the clock. Returns true on the call that ends the warm-up.
    func tick(host: Double) -> Bool {
        let t = time(host: host)
        switch phase {
        case .countdown:
            if t >= 0 { phase = .running }
            return false
        case .running:
            guard t > plan.durationSec else { return false }
            phase = .done
            return true
        case .done:
            return false
        }
    }

    /// One frame at `host`: where the gaze was (screen pt), nil when there was none. Frames around a change of
    /// part are left out (PursuitPlan.scored). Returns the target then, for the session CSV.
    @discardableResult
    func sample(host: Double, gaze: Vec2?) -> Vec2? {
        let t = time(host: host)
        guard phase != .done, !clock.isHeld, plan.scored(at: t) else { return nil }
        let target = plan.position(at: t, in: screen)
        tally.add(part: plan.part(at: t), distance: gaze.map { $0.distance(to: target) })
        return target
    }
}
