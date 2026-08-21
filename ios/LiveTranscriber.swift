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
/// Error contract (PR #991 review, rounds 1-2):
/// - START-TIME failures (model missing, engine won't start) THROW only.
///   The JS engine picker owns start failures and falls back to legacy.
/// - MID-SESSION failures (results stream dies, audio interruption) fire
///   the session's onError AND tear the pipeline down — a dead session must
///   never keep the mic hot behind a UI that says dictation stopped.
///
/// Session identity (round-2 NB1/NB2): every session gets a monotonic id.
/// All DEFERRED teardown (the post-drain teardown queued by stop(), the
/// failure paths, the commit of an in-flight startup) is gated on that id —
/// a stale session's late teardown must never wipe the session that
/// replaced it, and an abandoned startup must dismantle ITS OWN pipeline
/// rather than committing it over the new session's.
@available(iOS 26.0, macOS 26.0, *)
final class LiveTranscriber: @unchecked Sendable {

    private static let oslog = os.Logger(subsystem: "systems.dust.nitrosound", category: "LiveTranscriber")

    // MARK: - Session identity & pipeline state (all mutated on controlQueue)

    private var sessionID: UInt64 = 0
    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?
    private(set) var isActive = false

    /// Serializes session state transitions. JS also serializes calls, but
    /// rapid stop→start (re-record) and mid-session failures interleave
    /// native completion with the next session's startup.
    private let controlQueue = DispatchQueue(label: "com.hypnos.liveTranscriber")

    /// Shared log bridge into the app's debug logging (session-agnostic).
    var log: ((String) -> Void)?

    // MARK: - Asset management

    /// Guards against stacking a new system download request on every start
    /// attempt while one is already in flight.
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
                        // os_log so field failures reach sysdiagnose — the
                        // instance log bridge is unavailable here.
                        oslog.error("speech model install FAILED for \(localeIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                    downloadFlagQueue.sync { downloadInFlight = false }
                }
                return "downloading"
            }
            downloadFlagQueue.sync { downloadInFlight = false }
            return "ready"
        } catch {
            downloadFlagQueue.sync { downloadInFlight = false }
            // A hard failure creating the request is NOT progress — reporting
            // it as 'downloading' made stuck devices look healthy.
            oslog.error("assetInstallationRequest failed for \(localeIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return "download-failed"
        }
    }

    // MARK: - Lifecycle

    /// Start a session with per-session callbacks (shared-slot callbacks let
    /// a stopping session's drain splice its final into the next session's
    /// transcript — round-1 C2). Any remnants of a previous session are torn
    /// down first: by the time JS calls start, the JS layer has already
    /// decided this session owns the mic.
    func start(
        localeIdentifier: String,
        onResult: @escaping (String, Bool) -> Void,
        onError: @escaping (String, String) -> Void
    ) async throws {
        // Claim the session slot synchronously on the control queue.
        let sid: UInt64 = await withCheckedContinuation { cont in
            controlQueue.async { [self] in
                if isActive || audioEngine != nil {
                    log?("⚠️ [LT] previous session still present at start — tearing down")
                }
                teardown() // idempotent; also invalidates any queued stale teardown via the id bump below
                sessionID &+= 1
                isActive = true
                cont.resume(returning: sessionID)
            }
        }

        do {
            try await startPipeline(
                sid: sid,
                localeIdentifier: localeIdentifier,
                onResult: onResult,
                onError: onError
            )
        } catch {
            controlQueue.async { [self] in
                if sessionID == sid { teardown() }
            }
            throw error
        }
    }

    func stop() async {
        // Snapshot AND release the slot under the control queue — isActive
        // going false here lets an immediate next start() proceed; the id
        // gate below keeps our deferred teardown from touching it. (NB1)
        let snapshot: (sid: UInt64, continuation: AsyncStream<AnalyzerInput>.Continuation?, analyzer: SpeechAnalyzer?, engine: AVAudioEngine?)? =
            await withCheckedContinuation { cont in
                controlQueue.async { [self] in
                    guard isActive else {
                        cont.resume(returning: nil)
                        return
                    }
                    isActive = false
                    cont.resume(returning: (sessionID, inputContinuation, analyzer, audioEngine))
                }
            }
        guard let snapshot else { return }

        // Stop feeding audio first so the analyzer can drain and finalize.
        Self.stopEngine(snapshot.engine)
        snapshot.continuation?.finish()
        if let analyzer = snapshot.analyzer {
            do {
                // Delivers the last finalized result through transcriber.results
                // (the results task forwards it with isFinal=true) before returning.
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                log?("⚠️ [LT] finalize failed: \(error.localizedDescription)")
            }
        }
        controlQueue.async { [self] in
            // Id-gated: if a new session claimed the instance during our
            // drain, this teardown must not wipe it. (round-2 NB1)
            if sessionID == snapshot.sid { teardown() }
        }
    }

    // MARK: - Pipeline

    /// Builds the entire pipeline in LOCALS and commits it to instance state
    /// only if this session still owns the slot — an abandoned startup
    /// dismantles its own objects instead of orphaning a running engine or
    /// overwriting the successor's. (round-2 NB2)
    private func startPipeline(
        sid: UInt64,
        localeIdentifier: String,
        onResult: @escaping (String, Bool) -> Void,
        onError: @escaping (String, String) -> Void
    ) async throws {
        let locale = Locale(identifier: localeIdentifier)

        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw RuntimeErrorShim.message("Speech model for \(localeIdentifier) is not installed")
        }
        guard await isCurrent(sid) else { throw RuntimeErrorShim.message("Session superseded during startup") }

        // .volatileResults gives the live in-flight text between finalized
        // segments — the direct analog of SFSpeech partials, minus the decay.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RuntimeErrorShim.message("No compatible audio format for SpeechTranscriber")
        }
        guard await isCurrent(sid) else { throw RuntimeErrorShim.message("Session superseded during startup") }

        // Forward results BEFORE audio starts so nothing is dropped. The
        // callbacks are locals — a stale session's late emissions route to
        // ITS closures, whose JS generation guard drops them.
        let resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    onResult(text, result.isFinal)
                }
            } catch {
                // A dead results stream means the session is unrecoverable:
                // surface AND tear down (mic must not stay hot behind a UI
                // that says dictation stopped — round-1 C1). Id-gated so a
                // cancel-during-teardown can't fire a spurious error.
                self?.failSession(sid: sid, code: "analyzer", message: error.localizedDescription, onError: onError)
            }
        }

        // Bounded as a safety valve: if the analyzer ever stalls, dropping
        // the newest audio bounds memory; the terminal-error path is what
        // actually ends a dead session. ~512 buffers ≈ 45s of tap audio.
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(512)
        )

        var engine: AVAudioEngine?
        var observers: [NSObjectProtocol] = []
        // Dismantle everything built so far on any failure below.
        func abandonLocals() {
            resultsTask.cancel()
            continuation.finish()
            Self.stopEngine(engine)
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        do {
            try configureAudioSessionAsSecondClient()
            let builtEngine = try Self.buildAudioEngine(
                feeding: continuation,
                analyzerFormat: analyzerFormat,
                log: log
            )
            engine = builtEngine
            observers = registerSessionObservers(sid: sid, engine: builtEngine, onError: onError)
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            abandonLocals()
            throw error
        }

        // COMMIT — only if this session still owns the slot.
        let committed: Bool = await withCheckedContinuation { cont in
            controlQueue.async { [self] in
                guard sessionID == sid, isActive else {
                    cont.resume(returning: false)
                    return
                }
                self.transcriber = transcriber
                self.analyzer = analyzer
                self.audioEngine = engine
                self.inputContinuation = continuation
                self.resultsTask = resultsTask
                self.interruptionObserver = observers.count > 0 ? observers[0] : nil
                self.configChangeObserver = observers.count > 1 ? observers[1] : nil
                cont.resume(returning: true)
            }
        }
        guard committed else {
            abandonLocals()
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            throw RuntimeErrorShim.message("Session superseded during startup")
        }

        log?("🎤🟢 [LT] SpeechAnalyzer live transcription started (\(localeIdentifier))")
    }

    private func isCurrent(_ sid: UInt64) async -> Bool {
        await withCheckedContinuation { cont in
            controlQueue.async { [self] in
                cont.resume(returning: sessionID == sid && isActive)
            }
        }
    }

    /// Join the shared AVAudioSession WITHOUT fighting the expo-audio recorder.
    ///
    /// If the session is already .playAndRecord (the recorder started first —
    /// the normal journal flow), touch nothing. Only when running standalone
    /// (no recorder, e.g. the typed-note dictation surface) do we set the
    /// category ourselves — with the option set the legacy dictation engine
    /// uses today (SpeechRecognitionService.ts buildConfig), for parity.
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
    /// feed with no error from any API we're already listening to; without
    /// these the session froze silently. Both route through the terminal
    /// mid-session error path. Returns the observers for commit.
    private func registerSessionObservers(
        sid: UInt64,
        engine: AVAudioEngine,
        onError: @escaping (String, String) -> Void
    ) -> [NSObjectProtocol] {
        var observers: [NSObjectProtocol] = []
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard typeValue == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.failSession(sid: sid, code: "interrupted", message: "Audio session interrupted", onError: onError)
        })
        #endif
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self, weak engine] notification in
            guard let engine, (notification.object as? AVAudioEngine) === engine else { return }
            self?.failSession(sid: sid, code: "audio-route-changed", message: "Audio configuration changed mid-session", onError: onError)
        })
        return observers
    }

    /// Mid-session terminal failure: notify the session's JS closure and tear
    /// down — id-gated so a stale session's failure can't kill its successor.
    private func failSession(
        sid: UInt64,
        code: String,
        message: String,
        onError: @escaping (String, String) -> Void
    ) {
        controlQueue.async { [self] in
            guard sessionID == sid, isActive else { return }
            log?("⚠️ [LT] session failed: \(code) — \(message)")
            onError(code, message)
            teardown()
        }
    }

    private static func buildAudioEngine(
        feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat,
        log: ((String) -> Void)?
    ) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw RuntimeErrorShim.message("Audio input unavailable (format \(hardwareFormat))")
        }

        let needsConversion = hardwareFormat != analyzerFormat
        // The tap runs on the render thread and must only touch its own
        // captured locals — never instance state that teardown() mutates on
        // controlQueue while a callback is still in flight.
        var localConverter: AVAudioConverter?
        if needsConversion {
            guard let converter = AVAudioConverter(from: hardwareFormat, to: analyzerFormat) else {
                throw RuntimeErrorShim.message("Cannot convert \(hardwareFormat) → \(analyzerFormat)")
            }
            localConverter = converter
        }

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
                    log?("⚠️ [LT] convert error: \(conversionError.localizedDescription)")
                }
            } else {
                // Even without conversion, COPY: the tap buffer's storage is
                // owned and recycled by AVAudioEngine once this callback
                // returns, while the stream hands it to the analyzer
                // asynchronously — yielding it directly is read-after-recycle.
                guard let copy = copyBuffer(buffer) else { return }
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
        return engine
    }

    private static func copyBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // frameCapacity: 0 traps in the AVAudioPCMBuffer initializer.
        guard source.frameLength > 0 else { return nil }
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

    private static func stopEngine(_ engine: AVAudioEngine?) {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    /// Full reset of instance state. Runs on controlQueue. Idempotent.
    /// Deliberately does NOT touch the shared AVAudioSession (the recorder /
    /// JS layer owns restore). Callers gate on sessionID for deferred paths.
    private func teardown() {
        Self.stopEngine(audioEngine)
        audioEngine = nil
        resultsTask?.cancel()
        resultsTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        analyzer = nil
        transcriber = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if isActive {
            isActive = false
            log?("🎤🔴 [LT] live transcription stopped")
        }
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
