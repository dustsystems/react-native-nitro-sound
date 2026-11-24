import AVFoundation
import Accelerate
import Foundation

/// How long the current recording has been silent, for the app (DUS-2556).
///
/// The recording worker feeds it each 16 kHz chunk. It compares the chunk's
/// level with the room's own noise floor and stamps the last time it heard
/// speech. JS polls `silenceMs()` and ends a dream recording after a long
/// silence. It only measures: it never stops, starts or changes anything.
///
/// Written from the worker, read from JS threads: every field is lock-guarded.
final class SpeechLevelTracker {
    /// Speech is this far above the noise floor (SleepCapture's "medium" margin).
    private let marginDb: Float = 9.0
    /// Nothing quieter than this counts as speech, whatever the floor.
    private let minimumDb: Float = -60.0
    /// The floor follows a rising room slowly (SleepCapture's 3 dB per minute).
    private let floorRiseDbPerSecond: Float = 3.0 / 60.0

    private let lock = NSLock()
    private var lastSpeechAt: Date?
    private var noiseFloorDb: Float?

    /// A new recording: silence is counted from `start` until the first speech.
    func reset(at start: Date) {
        lock.lock()
        lastSpeechAt = start
        noiseFloorDb = nil
        lock.unlock()
    }

    /// Worker only. The floor drops at once to a quieter chunk and rises
    /// slowly, so a person talking from the first chunk still gets a floor
    /// once they pause.
    func track(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let samples = buffer.floatChannelData?[0] else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frames))
        let levelDb = 20 * log10(max(rms, 1e-6))
        let seconds = Float(frames) / Float(buffer.format.sampleRate)

        lock.lock()
        var floor = noiseFloorDb ?? levelDb
        if levelDb < floor {
            floor = levelDb
        } else {
            floor += floorRiseDbPerSecond * seconds
        }
        noiseFloorDb = floor
        if levelDb > max(floor + marginDb, minimumDb) {
            lastSpeechAt = Date()
        }
        lock.unlock()
    }

    /// Milliseconds since speech was last heard, or nil before any reset.
    func silenceMs(now: Date = Date()) -> Double? {
        lock.lock()
        let since = lastSpeechAt
        lock.unlock()
        guard let since = since else { return nil }
        return (now.timeIntervalSince(since) * 1000).rounded()
    }
}
