import AVFoundation
import Foundation
import SoundAnalysis

/// How long the current recording has gone without speech, for the app
/// (DUS-2556, DUS-3437).
///
/// "Speech" is what Apple's built-in sound classifier calls speech, not
/// loudness: an airplane, a fan or a cough above the room's noise floor is
/// not speech (DUS-3437 replaced the level tracker that counted them).
///
/// The recording worker hands it each 16 kHz chunk. It does nothing until JS
/// first asks for the silence (`activate()`), so recordings nobody watches
/// (the flag off) never run the classifier. Once active, each chunk is copied
/// and analysed on a private serial queue: the worker only takes a lock and
/// copies ~100 ms of samples, it never waits for the classifier, and nothing
/// here touches the audio session, the engine, the tap or any recorder state.
///
/// If the classifier cannot be created, fails, or falls far behind, the
/// recording's silence becomes unknown (nil, -1 to JS) until the next
/// recording: JS then never ends the recording on silence.
///
/// Written from the worker, the analysis queue and JS threads: every field
/// below the queue is lock-guarded.
final class SpeechClassifierTracker {
    /// Speech-family labels of Apple's classifier (version1, 303 labels) that
    /// count as the person telling their dream. `whispering` covers someone
    /// keeping their voice down next to a sleeping partner. Left out on
    /// purpose: `shout`/`yell`/`children_shouting` (not dream telling, and a
    /// neighbour's), `chatter`/`babble` (a crowd or a TV), `singing`, `laughter`.
    static let speechLabels: [String] = ["speech", "whispering"]

    /// A window counts as speech when any speech label reaches this
    /// confidence. The labels are scored independently (not a softmax), so
    /// 0.5 means "more likely than not". The offline harness (DUS-3437 PR) found
    /// normal and -20 dB speech, alone and over rumble, well above it, and
    /// rumble, fan, a cough and silence well below it.
    static let confidenceThreshold: Double = 0.5

    /// One second of audio per decision: long enough for the classifier to
    /// see a syllable or two (shorter windows lose accuracy on quiet speech),
    /// short enough that the last speech is placed within about a second.
    static let windowSeconds: Double = 1.0
    /// Half-overlapping windows give a decision every 0.5 s, matching JS's
    /// 500 ms poll, so talking moves the speech mark on every poll and JS's
    /// 200 ms run check (SPEECH_MIN_RUN_MS) passes on the second one.
    static let overlapFactor: Double = 0.5

    /// About 6 s of 100 ms chunks waiting for the classifier. Beyond that it
    /// cannot keep up on this device; the reading goes unknown rather than
    /// lagging further behind the person.
    private static let maxPendingChunks = 64

    /// Set once by the owner before any recording (Sound.init).
    var log: ((String) -> Void)?
    /// Optional per-window report (offline harness and debugging only).
    var onWindow: ((_ startSeconds: Double, _ confidences: [String: Double], _ isSpeech: Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.nitrosound.speechClassifier", qos: .utility)

    private enum State {
        /// No recording, or a recording JS has not asked about yet.
        case idle
        /// JS asked: start the analyser with the next chunk.
        case wanted
        case running
        /// The analyser could not run this recording: silence is unknown.
        case failed
    }

    private let lock = NSLock()
    private var state: State = .idle
    /// Bumped on every reset/stop so late work from an older recording is dropped.
    private var generation: Int = 0
    private var lastSpeechAt: Date?
    private var pendingChunks = 0

    // Analysis queue only.
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: Observer?
    private var framePosition: AVAudioFramePosition = 0
    private var analyzerGeneration: Int = -1

    /// A new recording: silence is counted from `start` until the first speech.
    /// The classifier waits for `activate()`.
    func reset(at start: Date) {
        lock.lock()
        generation += 1
        state = .idle
        lastSpeechAt = start
        pendingChunks = 0
        lock.unlock()
        releaseAnalyzerLater()
    }

    /// JS is watching this recording: classify from the next chunk on.
    /// Cheap and idempotent; called on every poll.
    func activate() {
        lock.lock()
        if state == .idle, lastSpeechAt != nil { state = .wanted }
        lock.unlock()
    }

    /// The recording ended or its tap is gone: release the classifier.
    /// The reading stays unknown until the next `reset`.
    func stop() {
        lock.lock()
        generation += 1
        state = .idle
        lastSpeechAt = nil
        pendingChunks = 0
        lock.unlock()
        releaseAnalyzerLater()
    }

    /// Worker only. Never blocks on the classifier: copies the chunk and queues it.
    func track(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let active = state == .wanted || state == .running
        let gen = generation
        var overloaded = false
        if active {
            if pendingChunks >= Self.maxPendingChunks {
                state = .failed
                overloaded = true
            } else {
                pendingChunks += 1
            }
        }
        lock.unlock()
        if overloaded {
            log?("⚠️ [SpeechClassifier] fell \(Self.maxPendingChunks) chunks behind; silence unknown for this recording")
            releaseAnalyzerLater()
            return
        }
        guard active else { return }
        guard let copy = Self.copy(buffer) else {
            lock.lock()
            pendingChunks -= 1
            lock.unlock()
            return
        }
        queue.async { [weak self] in
            self?.analyze(copy, generation: gen)
        }
    }

    /// Milliseconds since speech was last heard; nil when unknown (no
    /// recording, or the classifier failed for this one).
    func silenceMs(now: Date = Date()) -> Double? {
        lock.lock()
        let since = state == .failed ? nil : lastSpeechAt
        lock.unlock()
        guard let since = since else { return nil }
        return max(0, (now.timeIntervalSince(since) * 1000).rounded())
    }

    /// Waits for queued chunks to be analysed (offline harness only).
    func drainForTesting() {
        queue.sync {}
    }

    // MARK: - Analysis queue

    private func analyze(_ buffer: AVAudioPCMBuffer, generation gen: Int) {
        lock.lock()
        pendingChunks = max(0, pendingChunks - 1)
        let current = gen == generation
        let currentState = state
        lock.unlock()
        guard current, currentState == .wanted || currentState == .running else { return }

        if analyzer == nil || analyzerGeneration != gen {
            tearDownAnalyzer()
            do {
                try startAnalyzer(format: buffer.format, generation: gen)
            } catch {
                fail(generation: gen, reason: "could not start: \(error.localizedDescription)")
                return
            }
        }
        analyzer?.analyze(buffer, atAudioFramePosition: framePosition)
        framePosition += AVAudioFramePosition(buffer.frameLength)
    }

    private func startAnalyzer(format: AVAudioFormat, generation gen: Int) throws {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: Self.windowSeconds, preferredTimescale: 48_000)
        request.overlapFactor = Self.overlapFactor
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = Observer(owner: self, generation: gen)
        try analyzer.add(request, withObserver: observer)
        self.analyzer = analyzer
        self.observer = observer
        self.analyzerGeneration = gen
        self.framePosition = 0

        lock.lock()
        let stillCurrent = gen == generation && state == .wanted
        if stillCurrent { state = .running }
        lock.unlock()
        if stillCurrent {
            log?("🗣️ [SpeechClassifier] started (window \(Self.windowSeconds)s, overlap \(Self.overlapFactor), threshold \(Self.confidenceThreshold))")
        }
    }

    private func releaseAnalyzerLater() {
        queue.async { [weak self] in self?.tearDownAnalyzer() }
    }

    private func tearDownAnalyzer() {
        analyzer?.removeAllRequests()
        analyzer = nil
        observer = nil
        analyzerGeneration = -1
        framePosition = 0
    }

    fileprivate func fail(generation gen: Int, reason: String) {
        lock.lock()
        let current = gen == generation
        if current { state = .failed }
        lock.unlock()
        guard current else { return }
        log?("❌ [SpeechClassifier] \(reason); silence unknown for this recording")
        releaseAnalyzerLater()
    }

    fileprivate func handle(_ result: SNClassificationResult, generation gen: Int) {
        var confidences: [String: Double] = [:]
        for label in Self.speechLabels {
            confidences[label] = result.classification(forIdentifier: label)?.confidence ?? 0
        }
        let isSpeech = confidences.values.contains { $0 >= Self.confidenceThreshold }
        onWindow?(result.timeRange.start.seconds, confidences, isSpeech)
        guard isSpeech else { return }
        lock.lock()
        if gen == generation, state == .running {
            lastSpeechAt = Date()
        }
        lock.unlock()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0,
              let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames),
              let destination = copy.floatChannelData else { return nil }
        copy.frameLength = frames
        let channels = Int(buffer.format.channelCount)
        let stride = buffer.format.isInterleaved ? channels : 1
        let samplesPerChannelBuffer = Int(frames) * stride
        let channelBuffers = buffer.format.isInterleaved ? 1 : channels
        for channel in 0..<channelBuffers {
            memcpy(destination[channel], source[channel], samplesPerChannelBuffer * MemoryLayout<Float>.size)
        }
        return copy
    }

    /// Results arrive on the analysis queue (inside `analyze`).
    private final class Observer: NSObject, SNResultsObserving {
        private weak var owner: SpeechClassifierTracker?
        private let generation: Int

        init(owner: SpeechClassifierTracker, generation: Int) {
            self.owner = owner
            self.generation = generation
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            owner?.handle(result, generation: generation)
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            owner?.fail(generation: generation, reason: "failed: \(error.localizedDescription)")
        }
    }
}
