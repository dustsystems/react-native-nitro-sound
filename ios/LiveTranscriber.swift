import AVFoundation
import Foundation
import Speech
import os

/// Live journal dictation on Apple's SpeechAnalyzer/SpeechTranscriber (iOS 26+).
///
/// Design constraints (see docs/architecture/dreams/investigations/
/// 2026-08-13-dictation-lag-investigation.md in the app repo):
///
/// - This is the *second* audio client during a journal recording. The
///   expo-audio recorder starts first, configures the shared AVAudioSession
///   (.playAndRecord), and writes the persisted m4a. We therefore NEVER
///   re-mode the session while it is configured for recording, and NEVER
///   deactivate it — the recorder owns the session lifecycle. Violating this
///   is how the half-volume regression happened (expo-speech-recognition
///   defaulted the session to mode .measurement).
/// - This class is deliberately NOT wired into the overnight Nitro engine.
///   It owns its own small AVAudioEngine, mirroring the topology
///   expo-speech-recognition uses today, so the overnight invariants
///   (pinned input, no HFP on the overnight engine) are untouched.
/// - SpeechTranscriber is fully on-device with no duration cap — the
///   long-form replacement for the SFSpeech session that degrades past
///   ~1 minute (no server mode exists in this API at all).
///
/// Error contract (PR #991 round-1 review):
/// - START-TIME failures (model missing, engine won't start) THROW only.
///   The JS engine picker owns start failures and falls back to legacy;
///   firing onError as well double-reports and shows the user a false
///   error while legacy dictation is working. (review I1)
/// - MID-SESSION failures (results stream dies, audio interruption) fire
///   the session's onError AND tear the pipeline down — a dead session must
///   never keep the mic hot behind a UI that says dictation stopped.
///   (review C1 / I4)
@available(iOS 26.0, macOS 26.0, *)
final class LiveTranscriber: @unchecked Sendable {

    private static let oslog = os.Logger(subsystem: "systems.dust.nitrosound", category: "LiveTranscriber")

    // MARK: - Per-session pipeline state
    //
    // All of this is torn down in teardown(), which runs on controlQueue.
    // The result/error callbacks are CAPTURED PER SESSION at start() time
    // (review C2: a shared mutable callback slot let a stopping session's
    // drain deliver its final into the NEXT session's callbacks, splicing
    // dream A's tail into dream B's transcript — per-session capture routes
    // late emissions to the stale session's JS closure, whose generation
    // guard drops them).

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?
    private var sessionOnResult: ((String, Bool) -> Void)?
    private var sessionOnError: ((String, String) -> Void)?
    private(set) var isActive = false

    /// Serializes start/stop/teardown state transitions. JS also serializes
    /// calls, but rapid stop→start (re-record) and mid-session failures can
    /// interleave native completion with the next session's startup.
    private let controlQueue = DispatchQueue(label: "com.hypnos.liveTranscriber")

    /// Shared log bridge into the app's debug logging (safe to share across
    /// sessions — it carries no session identity).
    var log: ((String) -> Void)?

    // MARK: - Asset management

    /// Guards against stacking a new system download request on every
    /// start attempt while one is already in flight. (review)
    private static var downloadInFlight = false
    private static let downloadFlagQueue = DispatchQueue(label: "com.hypnos.liveTranscriber.assets")

    /// 'ready' | 'downloading' | 'download-failed' | 'unsupported' — see Sound.nitro.ts.
    static func ensureAssets(localeIdentifier: String) async -> String {
        let locale = Locale(identifier: localeIdentifier)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            return "unsupported"
        }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            return "ready"
        }

        let alreadyDownloading = downloadFlagQueue.sync { () -> Bool in
            if downloadInFlight { return true }
            downloadInFlight = true
            return false
        }
        if alreadyDownloading { return "downloading" }

        // Model missing: kick the system download off in the background and
        // report 'downloading' so the caller falls back to the legacy engine
        // for THIS session. Next session finds it installed.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Task.detached(priority: .utility) {
                    do {
                        try await request.downloadAndInstall()
                        oslog.info("speech model install completed for \(localeIdentifier, privacy: .public)")
                    } catch {
                        // Instance log bridge is unavailable in a static
                        // context — os_log so field failures are visible in
                        // sysdiagnose instead of vanishing. (review I5)
                        oslog.error("speech model install FAILED for \(localeIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                    downloadFlagQueue.sync { downloadInFlight = false }
                }
                return "downloading"
            }
            downloadFlagQueue.sync { downloadInFlight = false }
            // No request needed: the system considers the assets present.
            return "ready"
        } catch {
            downloadFlagQueue.sync { downloadInFlight = false }
            // A hard failure creating the request is NOT progress — reporting
            // it as 'downloading' made stuck devices indistinguishable from
            // healthy ones. (review I5)
            oslog.error("assetInstallationRequest failed for \(localeIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return "download-failed"
        }
    }

    // MARK: - Lifecycle

    /// Start a session with per-session callbacks. If a previous session is
    /// still draining (rapid stop→start — review I2/CR4), it is torn down
    /// first rather than rejecting: by the time JS calls start, the JS layer
    /// has already decided this session owns the mic, and rejecting here
    /// silently pinned users to the legacy engine for the whole next take.
    func start(
        localeIdentifier: String,
        onResult: @escaping (String, Bool) -> Void,
        onError: @escaping (String, String) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            controlQueue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: RuntimeErrorShim.message("LiveTranscriber deallocated"))
                    return
                }
                if self.isActive {
                    self.log?("⚠️ [LT] stale session still draining at start — force-tearing down")
                    self.teardown()
                }
                self.isActive = true
                self.sessionOnResult = onResult
                self.sessionOnError = onError
                Task {
                    do {
                        try await self.startPipeline(localeIdentifier: localeIdentifier)
                        cont.resume(returning: ())
                    } catch {
                        self.controlQueue.async { self.teardown() }
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func stop() async {
        // Snapshot AND flip isActive under the control queue — isActive going
        // false here (not in the eventual teardown) is what lets an immediate
        // next start() proceed instead of colliding with the drain. (review I2)
        let (continuation, activeAnalyzer): (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) =
            await withCheckedContinuation { cont in
                controlQueue.async { [weak self] in
                    guard let self, self.isActive else {
                        cont.resume(returning: (nil, nil))
                        return
                    }
                    self.isActive = false
                    cont.resume(returning: (self.inputContinuation, self.analyzer))
                }
            }
        guard let activeAnalyzer else {
            // Either never active, or start() was still mid-pipeline (the
            // continuation/analyzer not yet assigned). Tear down whatever
            // exists so nothing is stranded holding the mic. (review CR6)
            controlQueue.async { [weak self] in self?.teardown() }
            return
        }

        // Stop feeding audio first so the analyzer can drain and finalize.
        stopEngineOnly()
        continuation?.finish()
        do {
            // Delivers the last finalized result through transcriber.results
            // (our results task forwards it with isFinal=true) before returning.
            try await activeAnalyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            log?("⚠️ [LT] finalize failed: \(error.localizedDescription)")
        }
        controlQueue.async { [weak self] in self?.teardown() }
    }

    // MARK: - Pipeline

    private func startPipeline(localeIdentifier: String) async throws {
        let locale = Locale(identifier: localeIdentifier)

        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            // Throw only — start-time failures are the picker's to handle. (review I1)
            throw RuntimeErrorShim.message("Speech model for \(localeIdentifier) is not installed")
        }

        // .volatileResults gives the live in-flight text between finalized
        // segments — the direct analog of SFSpeech partials, minus the decay.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RuntimeErrorShim.message("No compatible audio format for SpeechTranscriber")
        }

        // Forward results BEFORE audio starts so nothing is dropped.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    self?.sessionOnResult?(text, result.isFinal)
                }
            } catch {
                // A dead results stream means the session is unrecoverable.
                // Surface it AND tear down — logging alone left the engine
                // running and the mic indicator lit behind a UI that said
                // dictation had stopped. (review C1) The stale-session case
                // (cancel during teardown) is filtered by isActive.
                guard let self else { return }
                self.controlQueue.async {
                    guard self.isActive else { return }
                    self.log?("⚠️ [LT] results stream error: \(error.localizedDescription)")
                    self.sessionOnError?("analyzer", error.localizedDescription)
                    self.teardown()
                }
            }
        }

        // Bounded as a safety valve: if the analyzer ever stalls, dropping
        // the newest audio bounds memory; the C1 teardown path is what
        // actually ends a dead session. ~512 buffers ≈ 45s of tap audio.
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )
        self.inputContinuation = continuation

        try configureAudioSessionAsSecondClient()
        registerSessionObservers()
        try startAudioEngine(feeding: continuation, analyzerFormat: analyzerFormat)

        try await analyzer.start(inputSequence: inputSequence)
        log?("🎤🟢 [LT] SpeechAnalyzer live transcription started (\(localeIdentifier))")
    }

    /// Join the shared AVAudioSession WITHOUT fighting the expo-audio recorder.
    ///
    /// If the session is already .playAndRecord (the recorder started first —
    /// the normal journal flow), touch nothing. Only when running standalone
    /// (no recorder, e.g. a future dictation-only surface) do we set the
    /// category ourselves — with the exact option set the journal flow pins
    /// (SpeechRecognitionService.ts buildConfig / Sound.swift session config).
    /// Never mode .measurement, never deactivate.
    private func configureAudioSessionAsSecondClient() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers]
            )
        }
        // Activating an already-active session is a no-op; when standalone it
        // is required. Never paired with a deactivate in this class.
        try session.setActive(true)
        #endif
    }

    /// A phone call, Siri, or an engine configuration change kills the mic
    /// feed with no error from any API we're already listening to. Without
    /// these observers the session froze silently: text stopped, isActive
    /// stayed true, JS stayed "listening". (review I4/CR5) Route both through
    /// the mid-session error path, which tears down and tells JS.
    private func registerSessionObservers() {
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard typeValue == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.failSession(code: "interrupted", message: "Audio session interrupted")
        }
        #endif
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, let engine = self.audioEngine,
                  (notification.object as? AVAudioEngine) === engine else { return }
            self.failSession(code: "audio-route-changed", message: "Audio configuration changed mid-session")
        }
    }

    /// Mid-session terminal failure: notify the session's JS closure, tear down.
    private func failSession(code: String, message: String) {
        controlQueue.async { [weak self] in
            guard let self, self.isActive else { return }
            self.log?("⚠️ [LT] session failed: \(code) — \(message)")
            self.sessionOnError?(code, message)
            self.teardown()
        }
    }

    private func startAudioEngine(
        feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat
    ) throws {
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw RuntimeErrorShim.message("Audio input unavailable (format \(hardwareFormat))")
        }

        let needsConversion = hardwareFormat != analyzerFormat
        // Converter is a LOCAL captured by the tap closure — the tap runs on
        // the render thread and must never read self's mutable state, which
        // teardown() nils on controlQueue while a callback can still be in
        // flight. (review CR6)
        var localConverter: AVAudioConverter?
        if needsConversion {
            guard let converter = AVAudioConverter(from: hardwareFormat, to: analyzerFormat) else {
                throw RuntimeErrorShim.message("Cannot convert \(hardwareFormat) → \(analyzerFormat)")
            }
            localConverter = converter
        }
        let logBridge = self.log

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
            if let converter = localConverter {
                let ratio = analyzerFormat.sampleRate / hardwareFormat.sampleRate
                let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
                guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
                    return
                }
                var fed = false
                var conversionError: NSError?
                let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
                    if fed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                if status == .haveData || (status == .inputRanDry && converted.frameLength > 0) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                } else if let conversionError {
                    logBridge?("⚠️ [LT] convert error: \(conversionError.localizedDescription)")
                }
            } else {
                // Even without conversion, COPY: the tap buffer's storage is
                // owned and recycled by AVAudioEngine once this callback
                // returns, while the stream hands it to the analyzer
                // asynchronously — yielding it directly is read-after-recycle.
                // (review CR7)
                guard let copy = Self.copyBuffer(buffer) else { return }
                continuation.yield(AnalyzerInput(buffer: copy))
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }
        copy.frameLength = source.frameLength
        let src = source.audioBufferList
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: src))
        for (i, srcBuf) in srcList.enumerated() where i < dst.count {
            if let srcData = srcBuf.mData, let dstData = dst[i].mData {
                memcpy(dstData, srcData, Int(srcBuf.mDataByteSize))
                dst[i].mDataByteSize = srcBuf.mDataByteSize
            }
        }
        return copy
    }

    // MARK: - Teardown

    /// Stop the mic feed only — used on stop() so the analyzer can still
    /// drain buffered audio and emit the final result.
    private func stopEngineOnly() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    /// Full reset. Runs on controlQueue. Idempotent. Deliberately does NOT
    /// touch the shared AVAudioSession (the recorder/JS layer owns restore).
    private func teardown() {
        stopEngineOnly()
        audioEngine = nil
        resultsTask?.cancel()
        resultsTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        analyzer = nil
        transcriber = nil
        sessionOnResult = nil
        sessionOnError = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        isActive = false
        log?("🎤🔴 [LT] live transcription stopped")
    }
}

/// Local error shim so this file has no dependency on NitroModules —
/// HybridSound maps thrown errors into Nitro promise rejections.
enum RuntimeErrorShim: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}
