import AVFoundation
import Accelerate
import Foundation
import FluidAudio

/// Overnight sleep-talking capture engine (MVP: capture-only, Tier 0 + Tier 1).
///
/// Design sources: docs/projects/sleep-talking/ 02 (architecture), 03 (detection),
/// 04 (background-audio survival), 08 (decision rules / constants) in the app repo.
///
/// Topology — the LiveTranscriber precedent, NOT the overnight Nitro engine:
/// this class owns its own small `AVAudioEngine` and joins the shared
/// `AVAudioSession` as a polite second client. It adopts Sound.swift's exact
/// category/mode/options (`.playAndRecord` + `.default` +
/// `[.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]`, input pinned to
/// the built-in mic, never `.measurement`) and NEVER deactivates the session —
/// the session lifecycle belongs to whoever armed it first. This keeps the
/// production dream-recording path (beginRecording/endRecording and the shared
/// engine's tap) completely untouched.
///
/// Pipeline (all state owned by one serial queue):
///   tap @ hardware rate (RT: copy-only into SPSCRingBuffer)
///     → drain timer → AVAudioConverter → 16 kHz mono float
///     → Tier 0: 80–4000 Hz biquad band-pass → 512-sample (32 ms) frame RMS →
///       adaptive noise-floor gate (running 10th percentile, rise-clamped)
///     → Tier 1: FluidAudio Silero VAD, 4096-sample (256 ms) chunks, gated by
///       Tier 0 (and kept running while an episode is open)
///     → episode state machine → int16 → AAC .m4a clips with a 10 s pre-roll
///
/// FluidAudio 0.6.1 constraints (verified against the pod source):
/// - `VadManager.chunkSize == 4096` (256 ms @ 16 kHz) — doc 08's 512-sample
///   Tier-1 windows are not available through this pod; decisions run per
///   256 ms chunk with the same threshold semantics.
/// - The public per-chunk API `process([Float])` resets model state each call
///   (`processChunk(_:inputState:)` is internal). Accepted for a permissive
///   Tier 1; probability is required for `vadConfidence` and thresholds.
/// - `VadManager.init` downloads the CoreML model on first use. Until it is
///   ready (or if it fails), the engine runs Tier-0-only: episodes open on the
///   adaptive gate alone with `vadConfidence = 0` — recall-biased by design.
final class SleepCapture {
    static let shared = SleepCapture()

    /// Bridged into the app's debug log by the Sound forwarder.
    var log: ((String) -> Void)?
    /// JS episode callback (episode JSON per closed clip). Set via forwarder.
    var episodeCallback: ((String) -> Void)?
    /// Returns true while the app's own audio (guide voice / soundscape) is
    /// playing — drives guarded mode + ownAudioOverlap tagging. Wired by the
    /// Sound forwarder from existing playback state.
    var ownAudioActiveProvider: (() -> Bool)?

    // MARK: - Config (doc-08 defaults compiled in; JSON keys mirror doc-08 names)

    struct Config {
        var configVersion = "doc08-defaults-v1"
        var sensitivity = "medium"            // high|medium|low → 6/9/12 dB margin
        var tier0MarginDb: Double?            // explicit override of sensitivity
        var tier0FloorPercentile = 0.10
        var tier0FloorWindowSec = 60.0
        var tier0FloorRiseMaxDbPerMin = 3.0
        var tier0TriggerFrames = 3
        var tier0ReleaseHysteresisDb = 3.0
        var tier0BandLowHz = 80.0
        var tier0BandHighHz = 4000.0
        var guardedModeExtraMarginDb = 6.0
        var vadStartProbability = 0.35
        var vadContinueProbability = 0.25
        var silenceHangoverSec = 2.0
        var mergeWindowSec = 3.0
        var maxClipSec = 90.0
        var preRollSec = 10.0
        var maxClipsPerNight = 40
        var maxEncodedSecPerNight = 1800.0
        var capBreachVadStepUp = 0.10
        var capBreachVadCap = 0.65
        var capBreachMarginStepDb = 3.0
        var minFreeDiskMb = 500.0
        var watchdogIntervalSec = 30.0
        var aacBitRate = 24000
        /// True when the supplied configJson was not valid JSON — the session
        /// runs on compiled defaults and stats surface the fact.
        var parseFailed = false

        var baseMarginDb: Double {
            if let explicit = tier0MarginDb { return explicit }
            switch sensitivity {
            case "high": return 6.0
            case "low": return 12.0
            default: return 9.0
            }
        }

        /// Unknown keys are ignored; missing keys keep the compiled defaults.
        static func parse(json: String) -> Config {
            var c = Config()
            guard let data = json.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                c.parseFailed = true
                return c
            }
            func num(_ key: String) -> Double? { (dict[key] as? NSNumber)?.doubleValue }
            if let v = dict["configVersion"] as? String { c.configVersion = v }
            if let v = dict["sensitivity"] as? String { c.sensitivity = v }
            if let v = num("tier0MarginDb") { c.tier0MarginDb = v }
            if let v = num("tier0FloorPercentile") { c.tier0FloorPercentile = min(max(v, 0.0), 1.0) }
            if let v = num("tier0FloorWindowSec"), v > 1 { c.tier0FloorWindowSec = v }
            if let v = num("tier0FloorRiseMaxDbPerMin"), v >= 0 { c.tier0FloorRiseMaxDbPerMin = v }
            if let v = num("tier0TriggerFrames"), v >= 1 { c.tier0TriggerFrames = Int(v) }
            if let v = num("tier0ReleaseHysteresisDb"), v >= 0 { c.tier0ReleaseHysteresisDb = v }
            if let v = num("tier0BandLowHz"), v > 0 { c.tier0BandLowHz = v }
            if let v = num("tier0BandHighHz"), v > 0 { c.tier0BandHighHz = v }
            if let v = num("guardedModeExtraMarginDb"), v >= 0 { c.guardedModeExtraMarginDb = v }
            if let v = num("vadStartProbability") { c.vadStartProbability = min(max(v, 0.0), 1.0) }
            if let v = num("vadContinueProbability") { c.vadContinueProbability = min(max(v, 0.0), 1.0) }
            if let v = num("silenceHangoverSec"), v > 0 { c.silenceHangoverSec = v }
            if let v = num("mergeWindowSec"), v >= 0 { c.mergeWindowSec = v }
            if let v = num("maxClipSec"), v > 1 { c.maxClipSec = v }
            if let v = num("preRollSec"), v >= 0 { c.preRollSec = v }
            if let v = num("maxClipsPerNight"), v >= 1 { c.maxClipsPerNight = Int(v) }
            if let v = num("maxEncodedSecPerNight"), v > 0 { c.maxEncodedSecPerNight = v }
            if let v = num("capBreachVadStepUp"), v >= 0 { c.capBreachVadStepUp = v }
            if let v = num("capBreachVadCap") { c.capBreachVadCap = min(max(v, 0.0), 1.0) }
            if let v = num("capBreachMarginStepDb"), v >= 0 { c.capBreachMarginStepDb = v }
            if let v = num("minFreeDiskMb"), v >= 0 { c.minFreeDiskMb = v }
            if let v = num("watchdogIntervalSec"), v >= 5 { c.watchdogIntervalSec = v }
            if let v = num("aacBitRate"), v >= 8000 { c.aacBitRate = Int(v) }
            // An inverted band collapses the band-pass into a near-null filter
            // and silently disables Tier 0 — fall back to the doc-08 band.
            if c.tier0BandLowHz >= c.tier0BandHighHz {
                c.tier0BandLowHz = 80.0
                c.tier0BandHighHz = 4000.0
            }
            return c
        }
    }

    // MARK: - State (mutated on `queue` only, except the RT tap counter)

    private enum EpisodeState: String {
        case idle, recording, pendingClose, suspended
    }

    private let queue = DispatchQueue(label: "com.dust.sleepcapture", qos: .userInitiated)
    private var config = Config()

    // Engine / audio plumbing
    private var engine: AVAudioEngine?
    private var spsc: SPSCRingBuffer?
    private var converter: AVAudioConverter?
    private var hwFormat: AVAudioFormat?
    private var float16kFormat: AVAudioFormat?
    private var int16FileFormat: AVAudioFormat?
    /// Written from the RT tap (plain increment, same accepted pattern as
    /// Sound.swift's tapCallbackCounter); read from the watchdog.
    private var tapCounter: Int = 0

    // Timers
    private var drainTimer: DispatchSourceTimer?
    private var tickTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?

    // Session
    private var active = false
    /// Monotonic per-arm generation. All deferred async work (VAD model init,
    /// VAD chunk results) is gated on it so a stale session's late completion
    /// can never clobber the session that replaced it — the same pattern as
    /// LiveTranscriber's session-ID gates (submodule commit c62ca10).
    private var sessionGeneration: UInt64 = 0
    private var sessionId = ""
    private var sessionStartMs: Int64 = 0
    private var endReason = ""
    private var lastSummaryJson = "{}"
    private var outputDir: URL?
    private var observers: [NSObjectProtocol] = []

    // Tier 0
    private var bandHighPass = Biquad()
    private var bandLowPass = Biquad()
    private var frameAccum: [Float] = []
    private var floorWindow: [Float] = []          // frame RMS dB ring
    private var floorWindowNext = 0
    private var floorWindowFilled = 0
    private var framesSinceFloorUpdate = 0
    private var noiseFloorDb: Double = -70.0
    /// False until the first real floor measurement. The gate must not arm
    /// against the -70 cold-start value: a normal room sits ~30 dB above it,
    /// which opened an episode instantly and froze the idle-only floor forever
    /// (measured 2026-08-25: noiseFloorDb -70 vs lastRmsDb -33.9, latched).
    private var floorSeeded = false
    private var lastFloorUpdateAt = Date()
    private var lastRmsDb: Double = -100.0
    private var tier0Open = false
    private var tier0OverCount = 0
    private var tier0UnderCount = 0
    private var capBreachMarginBoostDb = 0.0
    private var guardedNow = false

    // Tier 1
    private var vadManager: VadManager?
    private var vadReady = false
    /// True only when VAD init FAILED (model download error). Degraded
    /// Tier-0-only episode opens key off this, not `!vadReady` — otherwise the
    /// ~2 s init window races the freshly-seeded gate and opens an ambient
    /// episode before the VAD gets a vote (observed on-sim 2026-08-25).
    private var vadInitFailed = false
    private var vadSuspended = false               // thermal .serious
    private var vadStartProbability = 0.35         // mutable: cap-breach step-ups
    private var lastVadProb = 0.0                  // telemetry: latest chunk probability
    private var vadProbRing = [Double]()           // telemetry: ~last minute of chunk probs
    private var vadProbRingNext = 0
    private var vadAccum: [Float] = []
    private var vadChunkContinuation: AsyncStream<[Float]>.Continuation?
    private var vadConsumerTask: Task<Void, Never>?
    private var vadInitTask: Task<Void, Never>?

    // Episode state machine
    private var state: EpisodeState = .idle
    private var episodeFile: AVAudioFile?
    private var episodeId = ""
    private var episodePath = ""
    private var episodeStartMs: Int64 = 0
    private var episodeFramesWritten: Int64 = 0
    private var episodePeakDb: Double = -100.0
    private var episodeVadConfidence: Double = 0.0
    private var episodePreRollSec: Double = 0.0
    private var episodeOwnAudioOverlap = false
    private var lastVoiceAt = Date.distantPast
    private var pendingCloseDeadline = Date.distantFuture
    /// Audio arriving during the merge window. Held in memory, flushed into
    /// the clip only if a restart actually merges; discarded on finalize so an
    /// unmerged clip is not padded with 3 s of dead air (round-1 review #2).
    private var pendingTail: [Int16] = []

    // Pre-roll: plain circular Int16 buffer. Single-threaded consumer (this
    // queue), so no lock-free structure is needed — SPSCRingBuffer stays in
    // its designed tap→worker role and is continuously drained, so it never
    // *retains* history.
    private var preRoll: [Int16] = []
    private var preRollNext = 0
    private var preRollFilled = 0

    // Stats / forensics
    private var tier0Wakes = 0
    private var tier1Starts = 0
    private var episodeCount = 0
    private var totalEncodedSec = 0.0
    private var noisyNight = false
    private var gapIntervals: [[String: Any]] = []
    private var openGapStartMs: Int64?
    private var openGapCause = ""
    private var lastWatchdogTapCount = 0
    private var sawNonZeroSinceCheck = false
    private var lastEpisodeAtMs: Int64 = 0
    /// Consecutive clip open/write failures that were NOT explained by a full
    /// disk. A persistent I/O fault must terminate the session, not retry all
    /// night with no signal (round-1 review #3).
    private var consecutiveWriteFailures = 0
    /// Rebuild backoff (round-1 review #4): after repeated failed rebuilds
    /// (e.g. the mic is held for a long phone call) the watchdog keeps trying
    /// all night — that is the feature — but at a widening interval so an
    /// unattended 8-hour session doesn't burn battery on 30 s retries.
    private var consecutiveRebuildFailures = 0
    private var rebuildBackoffUntil = Date.distantPast

    // MARK: - Public API (called from the Sound forwarders)

    func start(configJson: String, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            guard !active else {
                completion(RuntimeErrorShim.message("Sleep capture is already active"))
                return
            }
            config = Config.parse(json: configJson)
            vadStartProbability = config.vadStartProbability

            guard AVAudioApplication.shared.recordPermission == .granted else {
                completion(RuntimeErrorShim.message("Microphone permission not granted"))
                return
            }

            do {
                let dir = try makeOutputDir()
                try preflightDisk(at: dir)
                outputDir = dir
                try configureSessionAsSecondClient()
                resetDetectionState()
                try buildEngineAndTap()
            } catch {
                teardownEngine()
                completion(error)
                return
            }

            sessionGeneration &+= 1
            sessionId = UUID().uuidString
            sessionStartMs = Self.nowMs()
            endReason = ""
            state = .idle
            active = true
            consecutiveWriteFailures = 0
            consecutiveRebuildFailures = 0
            rebuildBackoffUntil = .distantPast
            if config.parseFailed {
                log?("⚠️ [SC] configJson was not valid JSON — running on compiled doc-08 defaults")
            }
            tier0Wakes = 0
            tier1Starts = 0
            episodeCount = 0
            totalEncodedSec = 0.0
            noisyNight = false
            gapIntervals = []
            openGapStartMs = nil
            capBreachMarginBoostDb = 0.0
            lastEpisodeAtMs = 0

            startTimers()
            registerObservers()
            startVad()
            log?("😴🟢 [SC] sleep capture armed (config \(config.configVersion), margin \(config.baseMarginDb) dB)")
            completion(nil)
        }
    }

    func stop(completion: @escaping (String) -> Void) {
        queue.async { [self] in
            guard active else {
                completion(lastSummaryJson)
                return
            }
            stopInternal(reason: "stopped")
            completion(lastSummaryJson)
        }
    }

    func isActive() -> Bool {
        // Called from the JS/bridge thread. Calling from `queue` would
        // deadlock — assert so a future refactor trips in development.
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { active }
    }

    func statsJson() -> String {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            let dict: [String: Any] = [
                "active": active,
                "state": state.rawValue,
                "noiseFloorDb": round1(noiseFloorDb),
                "lastRmsDb": round1(lastRmsDb),
                "effectiveMarginDb": round1(effectiveMarginDb()),
                "tier0Open": tier0Open,
                "guarded": guardedNow,
                "vadReady": vadReady,
                "vadSuspended": vadSuspended,
                "vadStartProbability": vadStartProbability,
                "lastVadProb": round3(lastVadProb),
                "vadProbP50": round3(vadProbPercentile(0.5)),
                "vadProbP95": round3(vadProbPercentile(0.95)),
                "floorSeeded": floorSeeded,
                "thermalState": thermalName(ProcessInfo.processInfo.thermalState),
                "episodeCount": episodeCount,
                "tier0Wakes": tier0Wakes,
                "tier1Starts": tier1Starts,
                "totalEncodedSec": round1(totalEncodedSec),
                "noisyNight": noisyNight,
                "gapCount": gapIntervals.count + (openGapStartMs != nil ? 1 : 0),
                "uptimeSec": active ? round1(Double(Self.nowMs() - sessionStartMs) / 1000.0) : 0,
                "preRollFillSec": round1(Double(preRollFilled) / 16000.0),
                "lastEpisodeAtMs": lastEpisodeAtMs,
                "endReason": endReason,
                "configVersion": config.configVersion,
                "configParseFailed": config.parseFailed,
            ]
            return Self.jsonString(dict)
        }
    }

    // MARK: - Arming plumbing

    private func makeOutputDir() throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RuntimeErrorShim.message("Application Support directory unavailable")
        }
        let dir = appSupport.appendingPathComponent("sleep-capture", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func preflightDisk(at dir: URL) throws {
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage {
            let freeMb = Double(free) / (1024 * 1024)
            if freeMb < config.minFreeDiskMb {
                throw RuntimeErrorShim.message(
                    "Not enough free space to record overnight (\(Int(freeMb)) MB free, need \(Int(config.minFreeDiskMb)) MB)")
            }
        }
        // If capacity can't be read, arm anyway — mid-night write failures
        // still route to the disk_full stop path.
    }

    /// Join the shared AVAudioSession without fighting whoever configured it.
    /// Category/mode/options are Sound.swift's verbatim (see the header note);
    /// if the session is already .playAndRecord we touch nothing but the input
    /// pin. This class NEVER deactivates the session.
    private func configureSessionAsSecondClient() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            )
        }
        if session.maximumInputNumberOfChannels >= 1 {
            try? session.setPreferredInputNumberOfChannels(1)
        }
        // Pin input to the built-in mic (doc 04: never capture from AirPods on
        // the nightstand; also the app-wide Bluetooth-survival invariant).
        if let inputs = session.availableInputs,
           let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtInMic)
        }
        try session.setActive(true)
    }

    private func buildEngineAndTap() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else {
            throw RuntimeErrorShim.message("Audio input unavailable (format \(hw))")
        }
        // The SPSC ring carries channel 0 only, so the converter input is a
        // mono hw-rate format — never the raw hw format, whose extra channels
        // would be uninitialized memory in the wrapper buffer.
        guard let monoHw = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.sampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let fileFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: monoHw, to: target) else {
            throw RuntimeErrorShim.message("Cannot build 16 kHz converter from \(hw)")
        }

        if spsc == nil {
            // Same sizing as Sound.swift: 64 × 8192 ≥ any tap buffer iOS delivers.
            spsc = SPSCRingBuffer(capacity: 64, samplesPerChunk: 8192)
        }
        spsc?.reset()
        tapCounter = 0
        lastWatchdogTapCount = 0

        // RT-SAFE: copy-only, no allocation, no logging (Sound.swift pattern).
        input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buffer, _ in
            guard let self, let ring = self.spsc else { return }
            self.tapCounter &+= 1
            _ = ring.write(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.hwFormat = monoHw
        self.converter = conv
        self.float16kFormat = target
        self.int16FileFormat = fileFmt
        log?("😴 [SC] engine up — hw \(Int(hw.sampleRate)) Hz \(hw.channelCount) ch → 16 kHz mono")
    }

    private func resetDetectionState() {
        bandHighPass.setHighPass(frequency: config.tier0BandLowHz, sampleRate: 16000)
        bandLowPass.setLowPass(frequency: config.tier0BandHighHz, sampleRate: 16000)
        frameAccum.removeAll(keepingCapacity: true)
        let floorCapacity = max(32, Int(config.tier0FloorWindowSec / 0.032))
        floorWindow = [Float](repeating: 0, count: floorCapacity)
        floorWindowNext = 0
        floorWindowFilled = 0
        framesSinceFloorUpdate = 0
        noiseFloorDb = -70.0
        floorSeeded = false
        vadInitFailed = false
        lastVadProb = 0.0
        vadProbRing.removeAll(keepingCapacity: true)
        vadProbRingNext = 0
        lastFloorUpdateAt = Date()
        lastRmsDb = -100.0
        tier0Open = false
        tier0OverCount = 0
        tier0UnderCount = 0
        vadAccum.removeAll(keepingCapacity: true)
        let preRollCapacity = max(1, Int(config.preRollSec * 16000))
        preRoll = [Int16](repeating: 0, count: preRollCapacity)
        preRollNext = 0
        preRollFilled = 0
        lastVoiceAt = Date.distantPast
        sawNonZeroSinceCheck = false
    }

    private func startTimers() {
        let drain = DispatchSource.makeTimerSource(queue: queue)
        drain.schedule(deadline: .now(), repeating: .milliseconds(25))
        drain.setEventHandler { [weak self] in self?.drainAndProcess() }
        drain.resume()
        drainTimer = drain

        let tick = DispatchSource.makeTimerSource(queue: queue)
        tick.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250))
        tick.setEventHandler { [weak self] in self?.episodeTick() }
        tick.resume()
        tickTimer = tick

        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + config.watchdogIntervalSec, repeating: config.watchdogIntervalSec)
        watchdog.setEventHandler { [weak self] in self?.watchdogCheck() }
        watchdog.resume()
        watchdogTimer = watchdog
    }

    // MARK: - Tier 1 (FluidAudio VAD)

    private func startVad() {
        let startProb = Float(vadStartProbability)
        // Generation-gate every deferred completion: model init can outlive a
        // quick stop→start cycle (first-run download), and cancel() alone does
        // not interrupt it (round-1 review #1).
        let generation = sessionGeneration
        vadInitTask = Task { [weak self] in
            do {
                let manager = try await VadManager(config: VadConfig(threshold: startProb))
                self?.queue.async {
                    guard let self, self.active, self.sessionGeneration == generation else { return }
                    self.vadManager = manager
                    self.vadReady = true
                    self.log?("😴 [SC] Tier 1 VAD ready")
                }
            } catch {
                self?.queue.async {
                    guard let self, self.sessionGeneration == generation else { return }
                    self.vadReady = false
                    self.vadInitFailed = true
                    self.log?("⚠️ [SC] Tier 1 VAD unavailable (\(error.localizedDescription)) — running Tier-0-only")
                }
            }
        }

        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(8))
        vadChunkContinuation = continuation
        vadConsumerTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                let manager = self.queue.sync { self.vadManager }
                guard let manager else { continue }
                let probability: Double
                do {
                    let results = try await manager.process(chunk)
                    probability = Double(results.first?.probability ?? 0)
                } catch {
                    self.queue.async { self.log?("⚠️ [SC] VAD chunk failed: \(error.localizedDescription)") }
                    continue
                }
                self.queue.async { self.handleVadProbability(probability, generation: generation) }
            }
        }
    }

    private func handleVadProbability(_ probability: Double, generation: UInt64) {
        guard active, sessionGeneration == generation else { return }
        // Telemetry: latest prob + a ~1-minute ring (256 ms chunks) so stats can
        // report what this runtime actually scores ambient — the FluidAudio
        // chunk probabilities do not match the offline harness's streaming ones.
        lastVadProb = probability
        if vadProbRing.count < 240 {
            vadProbRing.append(probability)
        } else {
            vadProbRing[vadProbRingNext] = probability
            vadProbRingNext = (vadProbRingNext + 1) % 240
        }
        if state == .recording || state == .pendingClose {
            episodeVadConfidence = max(episodeVadConfidence, probability)
        }
        if probability >= config.vadContinueProbability {
            lastVoiceAt = Date()
            if state == .pendingClose {
                mergeIntoOpenEpisode()
            }
        }
        if state == .idle, tier0Open, probability >= vadStartProbability {
            openEpisode(vadStarted: true, initialConfidence: probability)
        }
    }

    // MARK: - Worker: drain, convert, detect, write

    private func drainAndProcess() {
        guard active, state != .suspended, let ring = spsc else { return }
        guardedNow = ownAudioActiveProvider?() ?? false
        if guardedNow, state == .recording || state == .pendingClose {
            episodeOwnAudioOverlap = true
        }
        while active, let (samples, frames) = ring.read() {
            guard frames > 0 else { continue }
            guard let buf16k = resample(samples, frameLength: frames) else { continue }
            process16k(buf16k)
        }
    }

    private func resample(_ samples: UnsafePointer<Float>, frameLength: Int) -> AVAudioPCMBuffer? {
        guard let hw = hwFormat, let target = float16kFormat, let conv = converter else { return nil }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: hw, frameCapacity: AVAudioFrameCount(frameLength)) else { return nil }
        inputBuffer.frameLength = AVAudioFrameCount(frameLength)
        if let dest = inputBuffer.floatChannelData?[0] {
            memcpy(dest, samples, frameLength * MemoryLayout<Float>.size)
        }
        let ratio = target.sampleRate / hw.sampleRate
        let capacity = AVAudioFrameCount((Double(frameLength) * ratio).rounded(.up) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        conv.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if error != nil { return nil }
        return output
    }

    private func process16k(_ buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let src = buffer.floatChannelData?[0] else { return }

        // Watchdog liveness: any non-zero sample this window?
        if !sawNonZeroSinceCheck {
            var maxMag: Float = 0
            vDSP_maxmgv(src, 1, &maxMag, vDSP_Length(n))
            if maxMag > 1e-6 { sawNonZeroSinceCheck = true }
        }

        // Tier 0: band-limited copy → 512-sample frame RMS.
        var filtered = [Float](repeating: 0, count: n)
        memcpy(&filtered, src, n * MemoryLayout<Float>.size)
        bandHighPass.processInPlace(&filtered)
        bandLowPass.processInPlace(&filtered)
        frameAccum.append(contentsOf: filtered)
        while frameAccum.count >= 512 {
            var rms: Float = 0
            frameAccum.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress!, 1, &rms, 512)
            }
            frameAccum.removeFirst(512)
            let rmsDb = Double(20.0 * log10(max(rms, 1e-6)))
            tier0Frame(rmsDb: rmsDb)
        }

        // Tier 1 feed: raw (unfiltered) samples, only while the gate is open
        // or an episode is in flight. Cleared when neither, so a re-opened
        // gate starts from fresh audio.
        let shouldRunVad = vadReady && !vadSuspended && (tier0Open || state == .recording || state == .pendingClose)
        if shouldRunVad {
            vadAccum.append(contentsOf: UnsafeBufferPointer(start: src, count: n))
            while vadAccum.count >= VadManager.chunkSize {
                let chunk = Array(vadAccum.prefix(VadManager.chunkSize))
                vadAccum.removeFirst(VadManager.chunkSize)
                vadChunkContinuation?.yield(chunk)
            }
        } else if !vadAccum.isEmpty {
            vadAccum.removeAll(keepingCapacity: true)
        }

        // int16 for the pre-roll ring and clip writing.
        var int16Samples = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            let v = max(-1.0, min(1.0, src[i]))
            int16Samples[i] = Int16(v * 32767.0)
        }
        appendToPreRoll(int16Samples)
        if state == .recording {
            appendToEpisode(int16Samples)
        } else if state == .pendingClose {
            let cap = Int((config.mergeWindowSec + 1.0) * 16000.0)
            if pendingTail.count < cap {
                pendingTail.append(contentsOf: int16Samples)
            }
        }
    }

    /// A restart inside the merge window continues the same clip: flush the
    /// buffered gap audio first so the merged clip stays continuous.
    private func mergeIntoOpenEpisode() {
        state = .recording
        pendingCloseDeadline = .distantFuture
        if !pendingTail.isEmpty {
            let tail = pendingTail
            pendingTail.removeAll(keepingCapacity: true)
            appendToEpisode(tail)
        }
    }

    private func tier0Frame(rmsDb: Double) {
        lastRmsDb = rmsDb
        if state == .recording || state == .pendingClose {
            episodePeakDb = max(episodePeakDb, rmsDb)
        }

        // Floor window collects continuously; the floor VALUE only updates in
        // IDLE (doc 08: never adapt to an in-progress episode).
        floorWindow[floorWindowNext] = Float(rmsDb)
        floorWindowNext = (floorWindowNext + 1) % floorWindow.count
        floorWindowFilled = min(floorWindowFilled + 1, floorWindow.count)
        framesSinceFloorUpdate += 1
        // Floor updates run in EVERY state (not idle-only): updateNoiseFloor()
        // is rise-clamped and skips falls while an episode is in progress, which
        // preserves doc 08's "never adapt to an in-progress episode" intent
        // without the failure mode where a recording freezes the floor forever.
        if framesSinceFloorUpdate >= 32, floorWindowFilled >= 32 {
            framesSinceFloorUpdate = 0
            updateNoiseFloor()
        }

        // Warm-up: until the first real measurement seeds the floor, the gate
        // stays disarmed — arming against the -70 cold-start value opens on any
        // normal room instantly. Costs ~1 s of deafness at arm time.
        guard floorSeeded else { return }

        let trigger = noiseFloorDb + effectiveMarginDb()
        let release = trigger - config.tier0ReleaseHysteresisDb
        if !tier0Open {
            if rmsDb > trigger {
                tier0OverCount += 1
                if tier0OverCount >= config.tier0TriggerFrames {
                    tier0Open = true
                    tier0Wakes += 1
                    tier0UnderCount = 0
                    // Degraded mode (no usable Tier 1): the gate alone opens
                    // episodes — recall over precision, judged in the morning.
                    if state == .idle, vadInitFailed || vadSuspended {
                        openEpisode(vadStarted: false, initialConfidence: 0)
                    }
                }
            } else {
                tier0OverCount = 0
            }
        } else {
            if rmsDb < release {
                tier0UnderCount += 1
                if tier0UnderCount >= config.tier0TriggerFrames {
                    tier0Open = false
                    tier0OverCount = 0
                }
            } else {
                tier0UnderCount = 0
            }
        }
        if tier0Open, vadInitFailed || vadSuspended {
            lastVoiceAt = Date()
            if state == .pendingClose {
                mergeIntoOpenEpisode()
            }
        }
    }

    private func updateNoiseFloor() {
        let filled = floorWindowFilled
        var window = [Float](repeating: 0, count: filled)
        if floorWindowFilled < floorWindow.count {
            window.replaceSubrange(0..<filled, with: floorWindow[0..<filled])
        } else {
            window.replaceSubrange(0..<filled, with: floorWindow)
        }
        window.sort()
        let idx = min(filled - 1, Int(Double(filled) * config.tier0FloorPercentile))
        let candidate = Double(window[idx])
        let now = Date()
        if !floorSeeded {
            // First real measurement replaces the -70 cold-start value outright.
            // Clamping the seed would leave the gate deaf-then-hair-triggered for
            // ~10 min (3 dB/min from -70 to a normal -40 room).
            noiseFloorDb = candidate
            floorSeeded = true
        } else if candidate > noiseFloorDb {
            // Rise clamped (doc 08: sustained snoring can't drag the floor up).
            let dtMin = now.timeIntervalSince(lastFloorUpdateAt) / 60.0
            noiseFloorDb = min(candidate, noiseFloorDb + config.tier0FloorRiseMaxDbPerMin * dtMin)
        } else if state == .idle {
            noiseFloorDb = candidate  // falls unclamped — fast re-arm (idle only)
        }
        lastFloorUpdateAt = now
    }

    private func effectiveMarginDb() -> Double {
        config.baseMarginDb + capBreachMarginBoostDb + (guardedNow ? config.guardedModeExtraMarginDb : 0)
    }

    // MARK: - Pre-roll ring

    private func appendToPreRoll(_ samples: [Int16]) {
        let cap = preRoll.count
        guard cap > 0 else { return }
        for s in samples {
            preRoll[preRollNext] = s
            preRollNext = (preRollNext + 1) % cap
        }
        preRollFilled = min(preRollFilled + samples.count, cap)
    }

    private func preRollSnapshot() -> [Int16] {
        let cap = preRoll.count
        guard preRollFilled > 0, cap > 0 else { return [] }
        var out = [Int16](repeating: 0, count: preRollFilled)
        let start = (preRollNext - preRollFilled + cap * 2) % cap
        for i in 0..<preRollFilled {
            out[i] = preRoll[(start + i) % cap]
        }
        return out
    }

    // MARK: - Episode state machine

    private func openEpisode(vadStarted: Bool, initialConfidence: Double) {
        guard state == .idle, episodeFile == nil, let dir = outputDir, let fileFmt = int16FileFormat else { return }
        let nowMs = Self.nowMs()
        let id = UUID().uuidString
        let url = dir.appendingPathComponent("sleep-\(nowMs)-\(id.prefix(8)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: config.aacBitRate,
        ]
        do {
            episodeFile = try AVAudioFile(forWriting: url, settings: settings,
                                          commonFormat: fileFmt.commonFormat,
                                          interleaved: fileFmt.isInterleaved)
        } catch {
            // The encoder can reject an unsupported bitrate/rate combination —
            // retry at encoder defaults before giving up on the episode.
            let fallback: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
            ]
            do {
                episodeFile = try AVAudioFile(forWriting: url, settings: fallback,
                                              commonFormat: fileFmt.commonFormat,
                                              interleaved: fileFmt.isInterleaved)
                log?("⚠️ [SC] clip encoder fell back to default bitrate: \(error.localizedDescription)")
            } catch {
                log?("❌ [SC] cannot open clip file: \(error.localizedDescription)")
                handleWriteFailure()
                return
            }
        }
        episodeId = id
        episodePath = url.path
        episodeFramesWritten = 0
        episodePeakDb = lastRmsDb
        episodeVadConfidence = initialConfidence
        episodeOwnAudioOverlap = guardedNow
        state = .recording
        pendingCloseDeadline = .distantFuture
        lastVoiceAt = Date()
        if vadStarted { tier1Starts += 1 }

        // Flush the pre-roll so the clip starts before the first word.
        let history = preRollSnapshot()
        episodePreRollSec = Double(history.count) / 16000.0
        episodeStartMs = nowMs - Int64(episodePreRollSec * 1000.0)
        if !history.isEmpty { appendToEpisode(history) }
        log?("😴🎙️ [SC] episode open (\(vadStarted ? "vad" : "tier0") p=\(String(format: "%.2f", initialConfidence)) preRoll=\(String(format: "%.1f", episodePreRollSec))s)")
    }

    private func appendToEpisode(_ samples: [Int16]) {
        guard let file = episodeFile, let fmt = int16FileFormat, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dest = buffer.int16ChannelData?[0] {
            samples.withUnsafeBufferPointer { ptr in
                memcpy(dest, ptr.baseAddress!, samples.count * MemoryLayout<Int16>.size)
            }
        }
        do {
            try file.write(from: buffer)
            consecutiveWriteFailures = 0
            episodeFramesWritten += Int64(samples.count)
            if Double(episodeFramesWritten) / 16000.0 >= config.maxClipSec {
                // Hard cut (doc 08). A new episode may immediately restart.
                finalizeEpisode(cause: "max-length")
            }
        } catch {
            log?("❌ [SC] clip write failed: \(error.localizedDescription)")
            finalizeEpisode(cause: "write-error")
            handleWriteFailure()
        }
    }

    /// 250 ms cadence: hangover expiry, merge-window expiry.
    private func episodeTick() {
        guard active else { return }
        let now = Date()
        switch state {
        case .recording:
            if now.timeIntervalSince(lastVoiceAt) > config.silenceHangoverSec {
                if config.mergeWindowSec > 0 {
                    state = .pendingClose
                    pendingCloseDeadline = now.addingTimeInterval(config.mergeWindowSec)
                } else {
                    finalizeEpisode(cause: "silence")
                }
            }
        case .pendingClose:
            if now >= pendingCloseDeadline {
                finalizeEpisode(cause: "silence")
            }
        case .idle, .suspended:
            break
        }
    }

    private func finalizeEpisode(cause: String) {
        guard episodeFile != nil else { return }
        episodeFile = nil  // AVAudioFile closes on release
        let endMs = Self.nowMs()
        let durationSec = Double(episodeFramesWritten) / 16000.0
        episodeCount += 1
        totalEncodedSec += durationSec
        lastEpisodeAtMs = endMs
        state = (state == .suspended) ? .suspended : .idle
        pendingCloseDeadline = .distantFuture
        pendingTail.removeAll(keepingCapacity: true)

        let episode: [String: Any] = [
            "id": episodeId,
            "filePath": episodePath,
            "startedAtMs": episodeStartMs,
            "endedAtMs": endMs,
            "durationSec": round1(durationSec),
            "peakDb": round1(episodePeakDb),
            "vadConfidence": (round(episodeVadConfidence * 100) / 100),
            "preRollSec": round1(episodePreRollSec),
            "ownAudioOverlap": episodeOwnAudioOverlap,
        ]
        log?("😴💾 [SC] episode closed (\(cause), \(String(format: "%.1f", durationSec))s, peak \(String(format: "%.0f", episodePeakDb)) dB, clips \(episodeCount))")
        episodeCallback?(Self.jsonString(episode))
        applyCapBreachIfNeeded()
    }

    /// Doc 08 circuit breaker: past the per-night caps, keep capturing under a
    /// stricter gate rather than stopping. Steps apply at every clip close
    /// while over the cap; the VAD start threshold is capped.
    private func applyCapBreachIfNeeded() {
        let overCap = episodeCount >= config.maxClipsPerNight || totalEncodedSec >= config.maxEncodedSecPerNight
        guard overCap else { return }
        noisyNight = true
        let previous = vadStartProbability
        vadStartProbability = min(config.capBreachVadCap, vadStartProbability + config.capBreachVadStepUp)
        capBreachMarginBoostDb += config.capBreachMarginStepDb
        log?("⚠️ [SC] per-night cap breached (clips \(episodeCount), \(Int(totalEncodedSec))s) — vadStart \(String(format: "%.2f", previous))→\(String(format: "%.2f", vadStartProbability)), margin +\(Int(capBreachMarginBoostDb)) dB")
    }

    private func handleWriteFailure() {
        // Distinguish a full disk from other I/O faults: below a hard floor,
        // stop cleanly with the doc-08 end reason.
        if let dir = outputDir,
           let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage,
           Double(free) / (1024 * 1024) < 50 {
            stopInternal(reason: "disk_full")
            return
        }
        // A persistent non-disk fault (permissions, encoder rejection the
        // fallback can't satisfy) must not retry silently all night.
        consecutiveWriteFailures += 1
        if consecutiveWriteFailures >= 5 {
            log?("❌ [SC] \(consecutiveWriteFailures) consecutive clip I/O failures — stopping session")
            stopInternal(reason: "io_error")
        }
    }

    // MARK: - Interruptions, route changes, watchdog (doc 04)

    private func registerObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let shouldResume = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                == AVAudioSession.InterruptionOptions.shouldResume.rawValue
            self.queue.async {
                guard self.active else { return }
                if typeValue == AVAudioSession.InterruptionType.began.rawValue {
                    self.enterSuspended(cause: "interruption")
                } else if typeValue == AVAudioSession.InterruptionType.ended.rawValue {
                    // .ended is a HINT (doc 04) — attempt recovery now, but the
                    // watchdog remains the authority if this never fires.
                    self.log?("😴 [SC] interruption ended (shouldResume=\(shouldResume)) — rebuilding")
                    self.attemptRebuild(cause: "interruption-ended")
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.active, self.state != .suspended else { return }
                // Input is pinned to the built-in mic, but doc 04's safe
                // response to any route change is a full rebuild of THIS
                // engine (never the shared one).
                self.log?("😴 [SC] route change — rebuilding capture engine")
                self.attemptRebuild(cause: "route-change")
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.active else { return }
                self.enterSuspended(cause: "media-services-reset")
                self.attemptRebuild(cause: "media-services-reset")
            }
        })
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let thermal = ProcessInfo.processInfo.thermalState
            self.queue.async {
                guard self.active else { return }
                switch thermal {
                case .serious:
                    if !self.vadSuspended {
                        self.vadSuspended = true
                        self.log?("🌡️ [SC] thermal .serious — Tier 1 suspended, Tier 0 keeps running")
                    }
                case .critical:
                    self.log?("🌡️ [SC] thermal .critical — stopping session")
                    self.stopInternal(reason: "thermal")
                default:
                    if self.vadSuspended {
                        self.vadSuspended = false
                        self.log?("🌡️ [SC] thermal recovered — Tier 1 resumed")
                    }
                }
            }
        })
    }

    /// Interruption .began: checkpoint the in-flight clip to disk immediately
    /// (lose nothing), open a gap interval, park in SUSPENDED. Recovery is
    /// watchdog-driven or via the .ended hint.
    private func enterSuspended(cause: String) {
        if state == .recording || state == .pendingClose {
            finalizeEpisode(cause: "checkpoint-\(cause)")
        }
        if openGapStartMs == nil {
            openGapStartMs = Self.nowMs()
            openGapCause = cause
        }
        state = .suspended
        tier0Open = false
        vadAccum.removeAll(keepingCapacity: true)
        log?("😴⏸️ [SC] suspended (\(cause)) — clip checkpointed, awaiting recovery")
    }

    /// Full teardown + rebuild of THIS engine (doc 04: naive stop/start often
    /// "recovers" into a running-but-silent engine). Never touches the shared
    /// session beyond re-joining it politely.
    private func attemptRebuild(cause: String) {
        guard active else { return }
        teardownEngine()
        do {
            try configureSessionAsSecondClient()
            try buildEngineAndTap()
            frameAccum.removeAll(keepingCapacity: true)
            vadAccum.removeAll(keepingCapacity: true)
            sawNonZeroSinceCheck = false
            if state == .suspended { state = .idle }
            if let gapStart = openGapStartMs {
                gapIntervals.append([
                    "startedAtMs": gapStart,
                    "endedAtMs": Self.nowMs(),
                    "cause": openGapCause.isEmpty ? cause : openGapCause,
                ])
                openGapStartMs = nil
                openGapCause = ""
            }
            consecutiveRebuildFailures = 0
            rebuildBackoffUntil = .distantPast
            log?("😴🔁 [SC] engine rebuilt (\(cause)) — capture resumed")
        } catch {
            // Stay suspended and keep retrying all night (recovering after a
            // long mic seizure IS the feature), but back off exponentially to
            // a 5-minute ceiling so an unattended session doesn't burn battery
            // hammering a mic another process holds.
            if openGapStartMs == nil {
                openGapStartMs = Self.nowMs()
                openGapCause = cause
            }
            state = .suspended
            consecutiveRebuildFailures += 1
            let backoffSec = min(300.0, config.watchdogIntervalSec * pow(2.0, Double(min(consecutiveRebuildFailures - 1, 4))))
            rebuildBackoffUntil = Date().addingTimeInterval(backoffSec)
            log?("❌ [SC] rebuild failed (\(cause), attempt \(consecutiveRebuildFailures)): \(error.localizedDescription) — next retry in \(Int(backoffSec))s")
        }
    }

    /// Every 30 s: assert tap callbacks arrived AND samples weren't all zero.
    /// A running-but-silent engine is caught here, not trusted (doc 04).
    private func watchdogCheck() {
        guard active else { return }
        let callbacksAdvanced = tapCounter != lastWatchdogTapCount
        lastWatchdogTapCount = tapCounter
        let healthy = callbacksAdvanced && sawNonZeroSinceCheck && state != .suspended
        sawNonZeroSinceCheck = false
        if !healthy {
            if openGapStartMs == nil {
                openGapStartMs = Self.nowMs()
                openGapCause = "watchdog"
            }
            guard Date() >= rebuildBackoffUntil else { return }
            log?("🐕 [SC] watchdog: unhealthy (callbacks=\(callbacksAdvanced), state=\(state.rawValue)) — rebuilding")
            attemptRebuild(cause: "watchdog")
        }
    }

    // MARK: - Teardown

    private func stopInternal(reason: String) {
        if state == .recording || state == .pendingClose {
            finalizeEpisode(cause: "session-stop")
        }
        if let gapStart = openGapStartMs {
            gapIntervals.append([
                "startedAtMs": gapStart,
                "endedAtMs": Self.nowMs(),
                "cause": openGapCause,
            ])
            openGapStartMs = nil
        }
        endReason = reason
        active = false
        state = .idle

        drainTimer?.cancel(); drainTimer = nil
        tickTimer?.cancel(); tickTimer = nil
        watchdogTimer?.cancel(); watchdogTimer = nil
        teardownEngine()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        vadChunkContinuation?.finish()
        vadChunkContinuation = nil
        vadConsumerTask?.cancel(); vadConsumerTask = nil
        vadInitTask?.cancel(); vadInitTask = nil
        vadManager = nil
        vadReady = false
        vadSuspended = false

        let summary: [String: Any] = [
            "id": sessionId,
            "startedAtMs": sessionStartMs,
            "endedAtMs": Self.nowMs(),
            "endReason": reason,
            "episodeCount": episodeCount,
            "totalEncodedSec": round1(totalEncodedSec),
            "tier0Wakes": tier0Wakes,
            "tier1Starts": tier1Starts,
            "gapIntervals": gapIntervals,
            "noisyNight": noisyNight,
            "configVersion": config.configVersion,
        ]
        lastSummaryJson = Self.jsonString(summary)
        log?("😴🔴 [SC] sleep capture stopped (\(reason)) — \(episodeCount) clips, \(Int(totalEncodedSec))s encoded, \(gapIntervals.count) gaps")
    }

    /// Stops and releases THIS class's engine only. Deliberately never calls
    /// `setActive(false)` — the shared session belongs to the recorder-first
    /// teardown order the JS layer enforces.
    private func teardownEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        converter = nil
        hwFormat = nil
    }

    // MARK: - Helpers

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private func round3(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    private func vadProbPercentile(_ p: Double) -> Double {
        guard !vadProbRing.isEmpty else { return 0 }
        let sorted = vadProbRing.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[idx]
    }

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Direct-form-I biquad used for the Tier-0 80–4000 Hz band limit
/// (2nd-order Butterworth high-pass + low-pass cascade, RBJ cookbook
/// coefficients, Q = 1/√2). State persists across chunks.
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func setHighPass(frequency: Double, sampleRate: Double) {
        setCoefficients(frequency: frequency, sampleRate: sampleRate, highPass: true)
    }

    mutating func setLowPass(frequency: Double, sampleRate: Double) {
        setCoefficients(frequency: frequency, sampleRate: sampleRate, highPass: false)
    }

    private mutating func setCoefficients(frequency: Double, sampleRate: Double, highPass: Bool) {
        let clamped = min(max(frequency, 1.0), sampleRate / 2.0 - 1.0)
        let omega = 2.0 * Double.pi * clamped / sampleRate
        let sinO = sin(omega)
        let cosO = cos(omega)
        let alpha = sinO / (2.0 * (1.0 / 2.0.squareRoot()))
        let a0 = 1.0 + alpha
        if highPass {
            b0 = Float(((1.0 + cosO) / 2.0) / a0)
            b1 = Float((-(1.0 + cosO)) / a0)
            b2 = b0
        } else {
            b0 = Float(((1.0 - cosO) / 2.0) / a0)
            b1 = Float((1.0 - cosO) / a0)
            b2 = b0
        }
        a1 = Float((-2.0 * cosO) / a0)
        a2 = Float((1.0 - alpha) / a0)
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    mutating func processInPlace(_ samples: inout [Float]) {
        for i in 0..<samples.count {
            let x0 = samples[i]
            let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = y0
            samples[i] = y0
        }
    }
}
