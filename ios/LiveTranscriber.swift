import AVFoundation
import Foundation
import Speech

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
///   (pinned input, no HFP) are untouched.
/// - SpeechTranscriber is fully on-device with no duration cap — the
///   long-form replacement for the SFSpeech session that degrades past
///   ~1 minute (no server mode exists in this API at all).
@available(iOS 26.0, macOS 26.0, *)
final class LiveTranscriber: @unchecked Sendable {

    // MARK: - State

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private(set) var isActive = false

    /// Serializes start/stop against each other. JS also serializes calls,
    /// but a user double-tapping stop/record shouldn't be able to interleave
    /// native teardown with startup.
    private let controlQueue = DispatchQueue(label: "com.hypnos.liveTranscriber")

    // MARK: - Callbacks (owned by HybridSound, forwarded from the Nitro layer)

    var onResult: ((String, Bool) -> Void)?
    var onError: ((String, String) -> Void)?
    var log: ((String) -> Void)?

    // MARK: - Asset management

    /// 'ready' | 'downloading' | 'unsupported' — see Sound.nitro.ts.
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
                    } catch {
                        // Background provisioning failure is non-fatal here —
                        // the next ensureAssets() call reports the true state.
                    }
                }
                return "downloading"
            }
            // No request needed: the system considers the assets present.
            return "ready"
        } catch {
            return "downloading"
        }
    }

    // MARK: - Lifecycle

    func start(localeIdentifier: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            controlQueue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: RuntimeErrorShim.message("LiveTranscriber deallocated"))
                    return
                }
                if self.isActive {
                    cont.resume(throwing: RuntimeErrorShim.message("Live transcription already active"))
                    return
                }
                self.isActive = true
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
        // Snapshot + clear under the control queue, then finalize outside it.
        let (continuation, activeAnalyzer): (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?) =
            await withCheckedContinuation { cont in
                controlQueue.async { [weak self] in
                    guard let self, self.isActive else {
                        cont.resume(returning: (nil, nil))
                        return
                    }
                    cont.resume(returning: (self.inputContinuation, self.analyzer))
                }
            }
        guard let continuation else { return }

        // Stop feeding audio first so the analyzer can drain and finalize.
        stopEngineOnly()
        continuation.finish()
        do {
            // Delivers the last finalized result through transcriber.results
            // (our results task forwards it with isFinal=true) before returning.
            try await activeAnalyzer?.finalizeAndFinishThroughEndOfInput()
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
            onError?("assets-missing", "Speech model for \(localeIdentifier) is not installed")
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
            onError?("analyzer", "No compatible audio format for SpeechTranscriber")
            throw RuntimeErrorShim.message("No compatible audio format for SpeechTranscriber")
        }
        self.analyzerFormat = analyzerFormat

        // Forward results BEFORE audio starts so nothing is dropped.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    self?.onResult?(text, result.isFinal)
                }
            } catch {
                // A cancelled stream on stop lands here too; only surface
                // errors while a session is still supposed to be running.
                if let self, self.isActive {
                    self.log?("⚠️ [LT] results stream error: \(error.localizedDescription)")
                    self.onError?("analyzer", error.localizedDescription)
                }
            }
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        try configureAudioSessionAsSecondClient()
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

    private func startAudioEngine(
        feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat
    ) throws {
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            onError?("audio-engine", "Audio input unavailable (format \(hardwareFormat))")
            throw RuntimeErrorShim.message("Audio input unavailable")
        }

        let needsConversion = hardwareFormat != analyzerFormat
        if needsConversion {
            guard let converter = AVAudioConverter(from: hardwareFormat, to: analyzerFormat) else {
                onError?("audio-engine", "Cannot convert \(hardwareFormat) → \(analyzerFormat)")
                throw RuntimeErrorShim.message("Audio format conversion unavailable")
            }
            self.converter = converter
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if !needsConversion {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            guard let converter = self.converter else { return }
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
                self.log?("⚠️ [LT] convert error: \(conversionError.localizedDescription)")
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            onError?("audio-engine", error.localizedDescription)
            throw error
        }
    }

    // MARK: - Teardown

    /// Stop the mic feed only — used on stop() so the analyzer can still
    /// drain buffered audio and emit the final result.
    private func stopEngineOnly() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    /// Full reset. Runs on controlQueue. Deliberately does NOT touch the
    /// shared AVAudioSession (the recorder/JS layer owns restore).
    private func teardown() {
        stopEngineOnly()
        audioEngine = nil
        resultsTask?.cancel()
        resultsTask = nil
        inputContinuation = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        analyzerFormat = nil
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
