import Foundation
import AVFoundation

/// Owns the ambient loop's volume (player node D): the level the session
/// asked for, and every ramp that moves the node (start fade-in, pause and
/// resume micro-fades, stop fade-out).
///
/// One owner means a fade-in, a pause, a resume or a stop can never write a
/// stale level over a newer `setTarget` (DUS-2094), and a ramp that was
/// superseded never runs its tail (a stale pause fade can't pause a resumed
/// loop; a stale stop fade can't stop a restarted one).
///
/// Threading: state lives behind `lock` so callers may be on any thread (the
/// JS thread, the global queues Sound uses). Every node write happens on the
/// main queue, the same queue `HybridSound.fadeVolume` writes on.
final class AmbientVolumeController {
    private enum Phase: String {
        case idle       // no loop, or a loop starting: the setter only stores
        case rampingUp  // fade-in or resume: each step reads the live target
        case steady     // the node sits at the target: the setter applies it
        case holding    // pausing or paused: the setter only stores
        case stopping   // stop fade-out: only a new loop or a reset ends it
    }

    private static let rampSteps = 60

    private let lock = NSLock()
    private var target: Float = 0.3
    private var phase: Phase = .idle
    private var generation: UInt64 = 0
    private var rampTimer: DispatchSourceTimer?
    private var pendingRampDownCompletion: ((Bool) -> Void)?
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// Store a new target. Applied to `node` right away only while the loop
    /// is steady; a running fade-in picks it up on its next step; while
    /// paused, stopping or with no loop it is only stored.
    func setTarget(_ volume: Float, node: AVAudioPlayerNode?) {
        let clamped = Self.clamp(volume)
        lock.lock()
        target = clamped
        let current = phase
        let gen = generation
        lock.unlock()

        log("🔊 AMBIENT volume target → \(clamped) (\(current.rawValue))")
        guard current == .steady, let node = node else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            // Re-read on main: a newer setTarget wins, and a pause or stop
            // that began after this call keeps the node where it is.
            let apply: Float? = (self.phase == .steady && self.generation == gen) ? self.target : nil
            self.lock.unlock()
            if let apply = apply {
                node.volume = apply
            }
        }
    }

    /// A new loop is starting at `volume`: it becomes the target, and any ramp
    /// still running (an earlier stop's fade-out) is superseded. Returns the
    /// clamped target. Follow with `rampUp` or `settle` once the node plays.
    func beginLoop(volume: Float) -> Float {
        lock.lock()
        defer { lock.unlock() }
        supersedeLocked()
        target = Self.clamp(volume)
        phase = .idle
        return target
    }

    /// The loop started without a fade: the node is at the target.
    func settle(node: AVAudioPlayerNode) {
        lock.lock()
        supersedeLocked()
        phase = .steady
        let gen = generation
        lock.unlock()
        // Catch a setTarget that landed between beginLoop and here.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let apply: Float? = self.generation == gen ? self.target : nil
            self.lock.unlock()
            if let apply = apply {
                node.volume = apply
            }
        }
    }

    /// Ramp from the node's current volume to the live target (equal-power
    /// curve, same as `HybridSound.fadeVolume`), then go steady. Ignored
    /// while the loop is stopping: a resume must not undo a stop.
    func rampUp(node: AVAudioPlayerNode, duration: Double) {
        lock.lock()
        if phase == .stopping {
            lock.unlock()
            log("🔊 AMBIENT ramp up ignored — loop is stopping")
            return
        }
        supersedeLocked()
        phase = .rampingUp
        let gen = generation
        let timer = DispatchSource.makeTimerSource(queue: .main)
        rampTimer = timer
        lock.unlock()

        let steps = Self.rampSteps
        var step = 0
        var startVolume: Float?

        timer.schedule(deadline: .now(), repeating: Self.stepInterval(duration))
        timer.setEventHandler { [weak self] in
            guard let self = self else {
                timer.cancel()
                return
            }
            self.lock.lock()
            guard self.generation == gen, node.engine != nil else {
                self.lock.unlock()
                timer.cancel()
                return
            }
            let goal = self.target
            let done = step >= steps
            if done {
                self.phase = .steady
                self.rampTimer = nil
            }
            self.lock.unlock()

            let from = startVolume ?? node.volume
            startVolume = from
            if done {
                node.volume = goal
                timer.cancel()
                self.log("🔊 AMBIENT ramp up complete at \(goal)")
            } else {
                let progress = Float(step) / Float(steps)
                node.volume = from + (goal - from) * progress.squareRoot()
            }
            step += 1
        }
        timer.resume()
    }

    /// Ramp the node to silence for a pause (`stopping: false`) or a stop
    /// (`stopping: true`). The target is kept, so a later resume returns to
    /// it. A pause while the loop is stopping is ignored (completion `false`)
    /// so it can't cancel the stop. `completion` runs on main exactly once:
    /// `true` when the ramp finished, `false` when a newer ramp, a new loop
    /// or a reset superseded it, or the node lost its engine (the caller must
    /// then leave the node alone).
    func rampDown(
        node: AVAudioPlayerNode,
        duration: Double,
        stopping: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        lock.lock()
        if !stopping && phase == .stopping {
            lock.unlock()
            log("🔊 AMBIENT pause fade ignored — loop is stopping")
            DispatchQueue.main.async { completion(false) }
            return
        }
        supersedeLocked()
        phase = stopping ? .stopping : .holding
        let gen = generation
        let timer = DispatchSource.makeTimerSource(queue: .main)
        rampTimer = timer
        pendingRampDownCompletion = completion
        lock.unlock()

        let steps = Self.rampSteps
        var step = 0
        var startVolume: Float?

        timer.schedule(deadline: .now(), repeating: Self.stepInterval(duration))
        timer.setEventHandler { [weak self] in
            guard let self = self else {
                timer.cancel()
                return
            }
            self.lock.lock()
            guard self.generation == gen else {
                // supersedeLocked already handed the completion `false`.
                self.lock.unlock()
                timer.cancel()
                return
            }
            // A node detached from its engine can't be touched: end the ramp
            // as not finished so the caller leaves the node alone.
            let detached = node.engine == nil
            let done = step >= steps || detached
            var finish: ((Bool) -> Void)?
            if done {
                self.rampTimer = nil
                finish = self.pendingRampDownCompletion
                self.pendingRampDownCompletion = nil
            }
            self.lock.unlock()

            if done {
                timer.cancel()
                if !detached {
                    node.volume = 0
                }
                finish?(!detached)
                return
            }

            let from = startVolume ?? node.volume
            startVolume = from
            let progress = Float(step) / Float(steps)
            node.volume = (1 - progress).squareRoot() * from
            step += 1
        }
        timer.resume()
    }

    /// The loop is gone (stopped, or the engine torn down). Cancels any ramp
    /// and keeps the target.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        supersedeLocked()
        phase = .idle
    }

    private func supersedeLocked() {
        generation &+= 1
        rampTimer?.cancel()
        rampTimer = nil
        if let completion = pendingRampDownCompletion {
            pendingRampDownCompletion = nil
            DispatchQueue.main.async { completion(false) }
        }
    }

    private static func stepInterval(_ duration: Double) -> DispatchTimeInterval {
        let seconds = max(duration, 0) / Double(rampSteps)
        return .microseconds(max(1_000, Int(seconds * 1_000_000)))
    }

    private static func clamp(_ volume: Float) -> Float {
        guard volume.isFinite else { return 0 }
        return max(0, min(1, volume))
    }
}
