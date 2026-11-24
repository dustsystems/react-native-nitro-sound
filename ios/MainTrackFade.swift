import Foundation
import AVFoundation

/// Micro-fades for the main track (player nodes A/B/C) on pause and resume
/// (DUS-3349). `AVAudioPlayerNode.pause()` and `play()` cut the waveform
/// mid-cycle, which is an audible click on device. The ambient loop already
/// fades over 0.1 s for the same reason (`AmbientVolumeController`); this
/// gives the main track the same 0.1 s fade.
///
/// Contract, so every other path behaves exactly as before:
/// - A pause fade ends with the node paused at the volume it had before the
///   fade. Anything that later plays the node (a seek, the lock screen's play
///   button) plays it at that volume, as it did before this change.
/// - A resume of a paused node starts it at 0 and ramps back to its volume.
/// - A resume during a pause fade (or a pause during a resume ramp) reverses
///   from wherever the volume is, toward the same remembered volume.
/// - `cancel()` (stop, a new track, engine teardown) ends a fade without
///   touching the node again.
///
/// Not coordinated with `fadeVolume` (crossfadeTo, fadeVolumeTo, the seamless
/// loop crossfade): if one of those starts on the same node inside this
/// fade's ~130 ms, both write `volume` until this fade ends. Reachable only
/// at a phase or loop boundary; pause/resume during an active loop crossfade
/// stays instant for that reason.
///
/// Threading: state lives behind `lock`; callers may be on any thread. Every
/// timer step runs on the main queue and writes the node while holding
/// `lock`, so a `cancel()` that returns guarantees no later write.
final class MainTrackFadeController {
    static let duration: Double = 0.1
    /// Same step count as the ambient ramps (one step ~1.7 ms).
    private static let steps = 60
    /// After the volume reaches 0, wait this long before `pause()`, so the
    /// render thread has played at least one buffer at silence first.
    private static let pauseSettle: Double = 0.03

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var timer: DispatchSourceTimer?
    /// The node a fade is running on, and the volume it returns to.
    private weak var fadingNode: AVAudioPlayerNode?
    private var restoreVolume: Float = 1
    /// Set once by HybridSound.init, before any other call.
    var log: (String) -> Void = { _ in }

    /// Fade `node` to silence over 0.1 s, then pause it and put its volume
    /// back. Returns at once; the caller treats the track as paused.
    func pause(node: AVAudioPlayerNode) {
        lock.lock()
        defer { lock.unlock() }
        let target = restoreTargetLocked(for: node) ?? node.volume
        startLocked(node: node, target: target, fadingOut: true)
    }

    /// Resume `node` with a 0.1 s fade-in. A node that is neither paused nor
    /// fading is left alone (as `play()` on a playing node did before).
    func resume(node: AVAudioPlayerNode) {
        lock.lock()
        defer { lock.unlock() }
        let target: Float
        if let fading = restoreTargetLocked(for: node) {
            // A pause fade is still running: the node is still playing, so
            // ramp back up from where the volume is now.
            target = fading
        } else if node.isPlaying {
            supersedeLocked()
            node.play()
            return
        } else {
            target = node.volume
            node.volume = 0
            node.play()
        }
        startLocked(node: node, target: target, fadingOut: false)
    }

    /// A new volume for the main track (`setVolume`) while a fade runs on
    /// `node`: the fade ends at it instead of the remembered volume.
    func retarget(_ volume: Float, node: AVAudioPlayerNode?) {
        lock.lock()
        defer { lock.unlock() }
        guard let node = node, fadingNode === node, timer != nil else { return }
        restoreVolume = volume
    }

    /// Stop, a new track or engine teardown: end any fade without touching
    /// the node again.
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        supersedeLocked()
    }

    /// The remembered volume, when a fade is running on this same node.
    private func restoreTargetLocked(for node: AVAudioPlayerNode) -> Float? {
        guard timer != nil, fadingNode === node else { return nil }
        return restoreVolume
    }

    private func startLocked(node: AVAudioPlayerNode, target: Float, fadingOut: Bool) {
        supersedeLocked()
        let gen = generation
        fadingNode = node
        restoreVolume = target
        let from = node.volume
        let timer = DispatchSource.makeTimerSource(queue: .main)
        self.timer = timer
        log(fadingOut
            ? "⏸️ MAIN fade out from \(from) (restores \(target))"
            : "▶️ MAIN fade in from \(from) to \(target)")

        let steps = Self.steps
        var step = 0
        timer.schedule(deadline: .now(), repeating: Self.stepInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else {
                timer.cancel()
                return
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.generation == gen else {
                timer.cancel()
                return
            }
            // A node detached from its engine can't be touched: the fade is
            // over and the caller's teardown owns the node now.
            guard node.engine != nil else {
                self.endLocked()
                timer.cancel()
                return
            }
            step += 1
            let progress = Float(min(step, steps)) / Float(steps)
            if fadingOut {
                node.volume = from * (1 - progress).squareRoot()
                if step >= steps {
                    timer.cancel()
                    self.timer = nil
                    self.schedulePauseLocked(node: node, generation: gen)
                }
            } else {
                let goal = self.restoreVolume
                node.volume = from + (goal - from) * progress.squareRoot()
                if step >= steps {
                    node.volume = goal
                    self.endLocked()
                    timer.cancel()
                }
            }
        }
        timer.resume()
    }

    /// The volume is at 0: pause once a buffer of silence has played, then
    /// put the volume back. Still cancellable (and reversible by a resume)
    /// until it runs, because `timer` is replaced by the settle timer.
    private func schedulePauseLocked(node: AVAudioPlayerNode, generation gen: UInt64) {
        let settle = DispatchSource.makeTimerSource(queue: .main)
        timer = settle
        settle.schedule(deadline: .now() + Self.pauseSettle)
        settle.setEventHandler { [weak self] in
            settle.cancel()
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.generation == gen else { return }
            if node.engine != nil {
                node.pause()
                node.volume = self.restoreVolume
            }
            self.endLocked()
        }
        settle.resume()
    }

    private func endLocked() {
        timer = nil
        fadingNode = nil
    }

    private func supersedeLocked() {
        generation &+= 1
        timer?.cancel()
        endLocked()
    }

    private static var stepInterval: DispatchTimeInterval {
        let seconds = duration / Double(steps)
        return .microseconds(max(1_000, Int(seconds * 1_000_000)))
    }
}
