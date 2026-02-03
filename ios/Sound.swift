import Foundation
import AVFoundation
import NitroModules
import SoundAnalysis
import FluidAudio
import Speech
import MediaPlayer

final class HybridSound: HybridSoundSpec_base, HybridSoundSpec_protocol, SNResultsObserving {
    private var audioEngine: AVAudioEngine?
    private var audioEngineInitialized = false
    private let engineInitLock = NSLock() // Thread-safe initialization guard

    // Dual player nodes for crossfading support
    private var audioPlayerNodeA: AVAudioPlayerNode?
    private var audioPlayerNodeB: AVAudioPlayerNode?
    private var currentPlayerNode: AVAudioPlayerNode?
    private var currentAudioFile: AVAudioFile?

    // Third crossfade player (part of A/B/C rotation)
    private var audioPlayerNodeC: AVAudioPlayerNode?

    // Ambient loop player (dedicated, independent layer - never used for crossfade)
    private var audioPlayerNodeD: AVAudioPlayerNode?
    private var isAmbientLoopPlaying: Bool = false
    private var currentAmbientFile: AVAudioFile?
    private var ambientVolumeBeforePause: Float?  // Store volume for micro-fade on resume
    private var currentLoopingFileURI: String?

    // Track which player is active (for future crossfading)
    private enum ActivePlayer {
        case playerA, playerB, playerC, none
    }
    private var activePlayer: ActivePlayer = .none

    // =============================================================================
    // DISABLED: VAD/Mode System (2025-02-02)
    // Reason: Simplified to fixed-duration recording (90s max) for reliability.
    // The mode system (idle/manual/vad) and silence detection added complexity
    // that caused bugs. Keeping code for potential future use.
    // =============================================================================

    // Fixed-duration recording state (replaces mode system)
    private var fixedDurationTimer: DispatchSourceTimer?
    private var recordingStartTime: Date?
    private var maxRecordingDuration: Double = 90.0  // Default 90 seconds

    // Crossfade state management
    private var crossfadeTimer: Timer?
    private var isCrossfading: Bool = false

    // Loop playback for overnight recording
    private var shouldLoopPlayback: Bool = false
    private var currentPlaybackURI: String?

    // Seamless looping with crossfade
    private var loopCrossfadeTimer: DispatchSourceTimer?
    private var loopCrossfadeDuration: TimeInterval = 1.0  // 1 second crossfade
    private var isLoopCrossfadeActive: Bool = false
    private var playbackVolume: Float = 1.0  // Track desired playback volume for crossfades

    // Track starting frame offset for getCurrentPosition after seek
    private var startingFrameOffset: AVAudioFramePosition = 0

    // Cache last valid position to avoid returning 0 during player state transitions
    private var lastValidPosition: Double = 0.0

    private var playTimer: Timer?

    // Removed recordBackListener - only used with AVAudioRecorder
    private var playBackListener: ((PlayBackType) -> Void)?
    private var playbackEndListener: ((PlaybackEndType) -> Void)?
    private var didEmitPlaybackEnd = false

    private var subscriptionDuration: TimeInterval = 0.06
    private var playbackRate: Double = 1.0 // default 1x

    // Buffer recording properties - removed, now using native file events

    // Speech detection properties
    private var audioAnalyzer: SNAudioStreamAnalyzer?
    private var soundClassifier: SNClassifySoundRequest?
    private var isSpeechActive: Bool = false
    // DISABLED: Silence detection state
    // private var silenceFrameCount: Int = 0
    // private var audioLevelThreshold: Float = -25.0 // COMMENTED OUT - using VAD instead
    private var workerChunkCounter: Int = 0  // Debug counter for worker thread logging
    private var tapCallbackCounter: Int = 0  // Tap callback counter (incremented RT-safely, logged from worker)
    private var lastLoggedTapCount: Int = 0  // Track what we last logged to detect tap activity
    private var tapMonitorTimer: DispatchSourceTimer?  // Logs tap activity periodically (runs on main queue, not RT)

    // DISABLED: VAD properties
    // private var vadManager: VadManager?
    // private var vadStreamState: VadStreamState?
    // private var vadThreshold: Float = 0.10  // 10% confidence - optimized for whisper detection (FluidAudio recommended 0.05-0.15)

    // Audio format conversion (48kHz → 16kHz for VAD)
    private var audioConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?  // 16kHz format for VAD and file writing

    // Now Playing Info (lock screen controls)
    private var currentTrackTitle: String = "Hypnos"
    private var currentTrackArtist: String = "Sleep Journey"
    private var currentTrackDuration: Double = 0.0
    private var nowPlayingArtwork: MPMediaItemArtwork?

    // DISABLED: Manual mode silence detection (default 15 seconds at ~14 fps = 210 frames)
    // private var manualSilenceFrameCount: Int = 0
    // private var manualSilenceThreshold: Int = 210  // Configurable, defaults to ~15 seconds at observed 14 fps

    // MARK: - RT-Safe Audio Pipeline (Phase 1: Session Recording)
    // Tap does copy-only to SPSC buffer, worker does all processing
    private var spscBuffer: SPSCRingBuffer?
    private var processingQueue: DispatchQueue?
    private var processingTimer: DispatchSourceTimer?
    private var isRecordingSession: Bool = false

    // Pre-allocated conversion buffer for worker (reused every chunk)
    private var workerConversionBuffer: AVAudioPCMBuffer?
    private var workerInputFormat: AVAudioFormat?  // 48kHz format from hardware

    // File writing
    private var currentSegmentFile: AVAudioFile?
    private var currentSegmentIsManual: Bool = false
    private var segmentCounter = 0
    private var sessionTimestamp: Int64 = 0  // Unix timestamp for unique filenames across restarts
    private var silenceCounter = 0
    private let silenceThreshold = 25  // ~0.5 second of silence before ending segment
    private var segmentStartTime: Date?  // Track when segment started for duration calculation

    // Output directory for segments
    private var outputDirectory: URL?

    // Files are written to documents/speech_segments/ for JavaScript polling

    // Log callback to bridge Swift logs to JavaScript
    private var logCallback: ((String) -> Void)?

    // Interruption tracking
    private var currentInterruptionId: String?
    private var interruptionStartTime: Date?

    // Segment callback to notify JavaScript when a new file is written
    private var segmentCallback: ((String, String, Bool, Double) -> Void)?

    // DISABLED: Manual silence timeout callback - notifies JS when 15s of silence detected in manual mode
    // private var manualSilenceCallback: (() -> Void)?

    // Lock screen track navigation callbacks
    private var nextTrackCallback: (() -> Void)?
    private var previousTrackCallback: (() -> Void)?

    // Lock screen pause/play callbacks (to sync UI with lock screen controls)
    private var pauseCallback: (() -> Void)?
    private var playCallback: (() -> Void)?

    // MARK: - Initialization

    override init() {
        super.init()
        setupAudioInterruptionHandling()
    }

    private func setupAudioEngine() throws {
        // Thread-safe initialization: serialize access to guard check and initialization
        engineInitLock.lock()
        defer { engineInitLock.unlock() }

        guard !audioEngineInitialized else {
            return
        }

        // Setup audio session for recording + playback
        let audioSession = AVAudioSession.sharedInstance()

        try audioSession.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        if audioSession.maximumInputNumberOfChannels >= 1 {
            try? audioSession.setPreferredInputNumberOfChannels(1)
        }
        try audioSession.setPreferredIOBufferDuration(0.0232)

        do {
            try audioSession.setActive(true)
        } catch {
            let nsError = error as NSError
            bridgedLog("❌ Session activation failed: \(error.localizedDescription) (code: \(nsError.code))")
            throw RuntimeError.error(withMessage: "Audio session activation failed - app may be suspended. Retry when app wakes: \(error.localizedDescription)")
        }

        // Create engine and player nodes
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else {
            throw RuntimeError.error(withMessage: "Failed to create audio engine")
        }

        audioPlayerNodeA = AVAudioPlayerNode()
        audioPlayerNodeB = AVAudioPlayerNode()
        audioPlayerNodeC = AVAudioPlayerNode()
        audioPlayerNodeD = AVAudioPlayerNode()  // Dedicated ambient loop player

        guard let playerA = audioPlayerNodeA,
            let playerB = audioPlayerNodeB,
            let playerC = audioPlayerNodeC,
            let playerD = audioPlayerNodeD else {
            throw RuntimeError.error(withMessage: "Failed to create audio engine components")
        }

        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(playerC)
        engine.attach(playerD)

        let mainMixer = engine.mainMixerNode
        engine.connect(playerA, to: mainMixer, format: nil)
        engine.connect(playerB, to: mainMixer, format: nil)
        engine.connect(playerC, to: mainMixer, format: nil)
        engine.connect(playerD, to: mainMixer, format: nil)

        // Initialize input node (required for .playAndRecord)
        let _ = engine.inputNode

        do {
            try engine.start()
            audioEngineInitialized = true

            // Log hardware sample rate
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            let hwSampleRate = inputFormat.sampleRate
            let hwChannels = inputFormat.channelCount
            bridgedLog("🟩🟩🟩  🎙️ AUDIO ENGINE: PLAY+RECORD MODE 🎙️  🟩🟩🟩")
            bridgedLog("📊 Hardware: \(Int(hwSampleRate))Hz, \(hwChannels) channel(s)")
        } catch {
            let nsError = error as NSError
            bridgedLog("❌ Engine start failed: \(error.localizedDescription) (code: \(nsError.code))")
            audioEngineInitialized = false
            throw error
        }
    }

    // MARK: - Engine Lifecycle

    private func ensureEngineRunning() throws {
        guard let engine = audioEngine else {
            throw RuntimeError.error(withMessage: "Audio engine not initialized")
        }

        if !engine.isRunning {
            bridgedLog("⚠️ ENGINE: Restarting stopped engine")
            try restartAudioEngine()
        }
    }

    private func restartAudioEngine() throws {
        guard let engine = audioEngine else {
            bridgedLog("❌ Cannot restart engine - engine is nil")
            throw RuntimeError.error(withMessage: "No engine to restart")
        }

        bridgedLog("🔧 Restarting audio engine (no reassertions)...")

        if !engine.isRunning {
            do {
                try engine.start()
                bridgedLog("✅ Audio engine restarted")
            } catch {
                let nsError = error as NSError
                bridgedLog("❌ Engine restart failed: \(error.localizedDescription) (code: \(nsError.code))")
                throw error
            }
        } else {
            bridgedLog("✅ Audio engine already running")
        }
    }

    // MARK: - Audio Interruption Handling

    private func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private func setupAudioInterruptionHandling() {
        // Handle audio interruptions (phone calls, other apps, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        // Handle audio engine configuration changes (route changes, hardware changes, etc.)
        // This notification fires AFTER interruptionNotification when hardware config changes
        // Note: Using nil for object since audioEngine may not exist yet at init() time
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    @objc private func handleEngineConfigurationChange(notification: Notification) {
        let timestamp = formattedTimestamp()

        // Get engine state
        let engineRunning = audioEngine?.isRunning ?? false
        let engineInitialized = audioEngineInitialized

        bridgedLog("╔════════════════════════════════════════════════════════════════╗")
        bridgedLog("║  ⚙️ AUDIO ENGINE CONFIGURATION CHANGE                          ║")
        bridgedLog("╠════════════════════════════════════════════════════════════════╣")
        bridgedLog("║  Time:              \(timestamp)")
        bridgedLog("║  Engine Running:    \(engineRunning)")
        bridgedLog("║  Engine Initialized: \(engineInitialized)")
        bridgedLog("╚════════════════════════════════════════════════════════════════╝")
        logStateSnapshot(context: "engine-config-change")
    }

    @objc private func handleAudioInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            bridgedLog("⚠️ [\(formattedTimestamp())] Audio interruption notification missing required keys")
            return
        }

        // Extract interruption reason (iOS 14.5+)
        var reasonString = "unknown"
        if #available(iOS 14.5, *) {
            if let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
               let reason = AVAudioSession.InterruptionReason(rawValue: reasonValue) {
                switch reason {
                case .default:
                    reasonString = "default (another audio session)"
                case .appWasSuspended:
                    reasonString = "app was suspended by system"
                case .builtInMicMuted:
                    reasonString = "built-in mic muted (iPad)"
                @unknown default:
                    reasonString = "unknown (\(reasonValue))"
                }
            }
        }

        let timestamp = formattedTimestamp()

        if type == .began {
            // Generate new interruption ID and record start time
            currentInterruptionId = String(UUID().uuidString.prefix(8)).lowercased()
            interruptionStartTime = Date()

            bridgedLog("╔════════════════════════════════════════════════════════════════╗")
            bridgedLog("║  🔇 AUDIO INTERRUPTION BEGAN                                   ║")
            bridgedLog("╠════════════════════════════════════════════════════════════════╣")
            bridgedLog("║  ID:        \(currentInterruptionId ?? "n/a")")
            bridgedLog("║  Time:      \(timestamp)")
            bridgedLog("║  Reason:    \(reasonString)")
            bridgedLog("╚════════════════════════════════════════════════════════════════╝")
            logStateSnapshot(context: "interruption-began")

        } else if type == .ended {
            let shouldResume = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) == AVAudioSession.InterruptionOptions.shouldResume.rawValue

            // Calculate duration
            var durationString = "unknown"
            if let startTime = interruptionStartTime {
                let duration = Date().timeIntervalSince(startTime)
                durationString = String(format: "%.2fs", duration)
            }

            bridgedLog("╔════════════════════════════════════════════════════════════════╗")
            bridgedLog("║  🔊 AUDIO INTERRUPTION ENDED                                   ║")
            bridgedLog("╠════════════════════════════════════════════════════════════════╣")
            bridgedLog("║  ID:            \(currentInterruptionId ?? "n/a")")
            bridgedLog("║  Time:          \(timestamp)")
            bridgedLog("║  Duration:      \(durationString)")
            bridgedLog("║  Reason:        \(reasonString)")
            bridgedLog("║  Should Resume: \(shouldResume)")
            bridgedLog("╚════════════════════════════════════════════════════════════════╝")
            logStateSnapshot(context: "interruption-ended")

            // Attempt engine restart if shouldResume is true
            if let engine = audioEngine, audioEngineInitialized && !engine.isRunning {
                if shouldResume {
                    bridgedLog("🔄 shouldResume=true, attempting engine.start()...")
                    do {
                        try engine.start()
                        bridgedLog("✅ Engine restarted after interruption")
                    } catch {
                        let nsError = error as NSError
                        bridgedLog("❌ Engine restart after interruption failed: \(error.localizedDescription) (code: \(nsError.code))")
                    }
                } else {
                    bridgedLog("⏸️ shouldResume=false, not auto-restarting engine")
                }
            }

            // Clear tracking state
            currentInterruptionId = nil
            interruptionStartTime = nil
        }
    }

    // MARK: - Recording Methods

    public func startRecorder() throws -> Promise<Void> {
        let promise = Promise<Void>()

        // Return immediately and process in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            do {
                try self.setupAudioEngine()

                // Remote command center disabled - no lock screen widget needed
                // self.setupRemoteCommandCenter()

                let audioSession = AVAudioSession.sharedInstance()
                let currentPermission = audioSession.recordPermission

                // Optimize: If permission already granted, skip async callback
                if currentPermission == .granted {
                    DispatchQueue.global(qos: .userInitiated).async {
                        self.installTap(promise: promise)
                    }
                } else {
                    audioSession.requestRecordPermission { [weak self] allowed in
                        guard let self = self else { return }

                        if allowed {
                            DispatchQueue.global(qos: .userInitiated).async {
                                self.installTap(promise: promise)
                            }
                        } else {
                            self.bridgedLog("❌ RECORDING: Microphone permission denied")
                            promise.reject(withError: RuntimeError.error(withMessage: "Microphone permission denied. Please enable microphone access in Settings > Dust."))
                        }
                    }
                }

            } catch {
                self.bridgedLog("❌ RECORDING: Failed - \(error.localizedDescription)")
                promise.reject(withError: RuntimeError.error(withMessage: "Audio engine initialization failed: \(error.localizedDescription)"))
            }
        }

        return promise
    }

    private func installTap(promise: Promise<Void>) {
        do {
            guard let engine = self.audioEngine else {
                bridgedLog("❌ installTap: Audio engine is nil")
                promise.reject(withError: RuntimeError.error(withMessage: "Audio engine not initialized"))
                return
            }

            if !engine.isRunning {
                throw RuntimeError.error(withMessage: "Audio engine is not running")
            }

            let inputNode = engine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)

            // Remove any existing taps
            inputNode.removeTap(onBus: 0)

            // Set default output directory if needed
            if outputDirectory == nil {
                let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                outputDirectory = documentsURL.appendingPathComponent("recordings")
            }
            if let outputDir = outputDirectory {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            }

            // Initialize SPSC buffer for RT-safe audio pipeline
            // samplesPerChunk must be >= actual tap buffer size (iOS gives ~4800 frames at 48kHz)
            if spscBuffer == nil {
                spscBuffer = SPSCRingBuffer(capacity: 64, samplesPerChunk: 8192)
            }
            spscBuffer?.reset()

            // Store input format for file writing
            self.workerInputFormat = hwFormat

            // Initialize 16kHz target format for recording
            self.targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )

            // Create converter from hardware format (48kHz) to 16kHz
            if let targetFmt = self.targetFormat {
                self.audioConverter = AVAudioConverter(from: hwFormat, to: targetFmt)
                bridgedLog("🎤 Audio converter initialized: \(hwFormat.sampleRate)Hz → \(targetFmt.sampleRate)Hz")
            }

            // Install tap - RT-SAFE: copy-only, no processing, NO LOGGING
            // (Logging from RT audio thread can cause glitches via memory allocation & GCD locks)
            // Only RT-safe operations: increment counter + buffer write
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, time in
                guard let self = self, let spsc = self.spscBuffer else { return }
                self.tapCallbackCounter += 1  // RT-safe: simple int increment
                _ = spsc.write(buffer)
            }

            // Start tap monitor timer - logs every 2 seconds to confirm tap is receiving data
            self.tapCallbackCounter = 0
            self.lastLoggedTapCount = 0
            self.startTapMonitor()

            self.bridgedLog("🎙️🟠 TAP INSTALLED")
            promise.resolve(withResult: ())

        } catch {
            bridgedLog("❌ installTap failed: \(error.localizedDescription)")
            promise.reject(withError: RuntimeError.error(withMessage: "Tap installation failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Tap Monitor (logs tap activity from non-RT thread)

    private func startTapMonitor() {
        stopTapMonitor()  // Cancel any existing timer

        tapMonitorTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        tapMonitorTimer?.schedule(deadline: .now() + 5.0, repeating: 5.0)  // Log every 5 seconds
        tapMonitorTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let currentCount = self.tapCallbackCounter
            let delta = currentCount - self.lastLoggedTapCount
            self.lastLoggedTapCount = currentCount

            if delta > 0 {
                self.bridgedLog("🎤 TAP ACTIVE | callbacks: \(currentCount) (+\(delta) in 5s) | recording: \(self.isRecordingSession)")
            } else {
                self.bridgedLog("⚠️ TAP STALLED | callbacks: \(currentCount) (no new data in 5s) | recording: \(self.isRecordingSession)")
            }
        }
        tapMonitorTimer?.resume()
    }

    private func stopTapMonitor() {
        tapMonitorTimer?.cancel()
        tapMonitorTimer = nil
    }

    // MARK: - Debug Helpers

    private func logStateSnapshot(context: String) {
        let session = AVAudioSession.sharedInstance()

        // Recording state (note: no API to check if tap is installed - only buffer flow confirms it)
        let hasSegment = currentSegmentFile != nil
        let bufferCount = spscBuffer?.availableChunks ?? 0

        // Engine state
        let engineInit = audioEngineInitialized
        let engineRun = audioEngine?.isRunning ?? false

        // Session state
        let category = session.category.rawValue
        let isActive = session.isOtherAudioPlaying == false  // Indirect check
        let route = session.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        let inputRoute = session.currentRoute.inputs.map { $0.portName }.joined(separator: ", ")
        let sampleRate = Int(session.sampleRate)

        bridgedLog("📊 STATE SNAPSHOT [\(context)]:")
        bridgedLog("   🎙️ Recording: segment=\(hasSegment), buffer=\(bufferCount) chunks")
        bridgedLog("   🔧 Engine: init=\(engineInit), running=\(engineRun)")
        bridgedLog("   🔊 Playback: loop=\(shouldLoopPlayback), ambient=\(isAmbientLoopPlaying)")
        bridgedLog("   📡 Session: \(category), \(sampleRate)Hz")
        bridgedLog("   📡 Routes: out=[\(route)], in=[\(inputRoute)]")
    }



    public func stopRecorder() throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // Stop recording session if active
            if self.isRecordingSession {
                self.stopRecordingSession()
            }

            // DISABLED: Stop VAD monitoring if active (autoVAD mode)
            // if self.currentMode == .autoVAD {
            //     self.stopVADMonitoring()
            // }

            // Remove tap from unified engine's input node
            if let engine = self.audioEngine {
                engine.inputNode.removeTap(onBus: 0)
                self.stopTapMonitor()
                self.bridgedLog("🎙️⚪ RECORDING TAP REMOVED - mic indicator should disappear if tap was the cause")
            }

            // Clean up SPSC buffer
            self.spscBuffer = nil

            // DISABLED: Clean up VAD resources
            // self.vadManager = nil
            // self.vadStreamState = nil

            // DISABLED: Reset mode to idle
            // self.currentMode = .idle

            // No callback to clear - using event emitting

            // Keep the unified engine running for potential playback or quick restart
            promise.resolve(withResult: ())
        }

        return promise
    }

    /**
     * End the engine session and completely destroy all audio resources.
     * This method performs a full teardown:
     * - Ends any active recording segments
     * - Stops all playback
     * - Stops the audio engine
     * - Deactivates the audio session (removes microphone indicator)
     * - Destroys the engine instance (forces clean re-initialization)
     *
     * Call this when stopping a sleep session to ensure the microphone
     * indicator disappears and all audio resources are released.
     */
    public func endEngineSession() throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            self.bridgedLog("🔚 endEngineSession() - full teardown")

            // Step 1: Stop recording session if active
            if self.isRecordingSession {
                self.stopRecordingSession()
            }

            // Step 1b: Stop fixed duration timer if active
            self.fixedDurationTimer?.cancel()
            self.fixedDurationTimer = nil

            // DISABLED: Stop VAD monitoring if active (autoVAD mode)
            // if self.currentMode == .autoVAD {
            //     self.stopVADMonitoring()
            // }

            // Step 2: Stop all playback
            self.currentPlayerNode?.stop()
            self.audioPlayerNodeA?.stop()
            self.audioPlayerNodeB?.stop()
            self.audioPlayerNodeC?.stop()
            self.audioPlayerNodeD?.stop()

            // Step 3: Remove microphone tap
            if let engine = self.audioEngine {
                engine.inputNode.removeTap(onBus: 0)
                self.stopTapMonitor()
                self.bridgedLog("🎙️⚪ RECORDING TAP REMOVED (endEngineSession)")
            }

            // Step 4: Stop the audio engine
            if let engine = self.audioEngine, engine.isRunning {
                engine.stop()
                self.bridgedLog("🔴 AUDIO ENGINE STOPPED")
            }

            // Step 5: Deactivate audio session (critical for removing mic indicator)
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                self.bridgedLog("⚠️ Failed to deactivate session: \(error.localizedDescription)")
            }

            // Step 6: Destroy engine instance (forces re-initialization on next session)
            self.audioEngine = nil
            self.audioPlayerNodeA = nil
            self.audioPlayerNodeB = nil
            self.audioPlayerNodeC = nil
            self.audioPlayerNodeD = nil
            self.audioEngineInitialized = false

            // Step 7: Clean up recording resources
            self.currentSegmentFile = nil
            self.spscBuffer = nil
            self.processingTimer = nil
            self.processingQueue = nil
            // DISABLED: VAD cleanup
            // self.vadManager = nil
            // self.vadStreamState = nil

            // Step 8: Reset playback state
            self.currentPlayerNode = nil
            self.currentAudioFile = nil
            self.currentAmbientFile = nil
            self.isAmbientLoopPlaying = false
            self.shouldLoopPlayback = false
            self.currentPlaybackURI = nil

            // Step 9: Reset recording state
            // DISABLED: self.currentMode = .idle
            self.isRecordingSession = false

            self.bridgedLog("✅ endEngineSession() completed")
            promise.resolve(withResult: ())
        }

        return promise
    }

    // MARK: - Simple Recording API (Fixed Duration)
    // New simplified recording: start with max duration, auto-stops when timer fires

    /**
     * Begin recording with a maximum duration. Recording will automatically stop
     * when the duration is reached, or can be stopped early with endRecording().
     *
     * @param maxDurationSeconds Maximum recording duration (e.g., 90 seconds)
     */
    public func beginRecording(maxDurationSeconds: Double) throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // If already recording, stop first
            if self.isRecordingSession {
                self.bridgedLog("⚠️ Stopping existing recording session before starting new one")
                self.stopRecordingSession()
            }

            // Cancel any existing timer
            self.fixedDurationTimer?.cancel()
            self.fixedDurationTimer = nil

            // Verify target format is available
            guard self.targetFormat != nil else {
                promise.reject(withError: RuntimeError.error(withMessage: "Target format not initialized"))
                return
            }

            // Generate file URL for this segment
            guard let outputDir = self.outputDirectory else {
                promise.reject(withError: RuntimeError.error(withMessage: "Output directory not set"))
                return
            }

            self.segmentCounter += 1
            let filename = String(format: "speech_%lld_%03d.wav", self.sessionTimestamp, self.segmentCounter)
            let fileURL = outputDir.appendingPathComponent(filename)

            // Store max duration for reference
            self.maxRecordingDuration = maxDurationSeconds
            self.recordingStartTime = Date()

            // Mark as manual segment (all simple recordings are manual)
            self.currentSegmentIsManual = true

            // Start the RT-safe recording session (worker queue + SPSC buffer)
            self.startRecordingSession(fileURL: fileURL)

            let now = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            self.bridgedLog("🎙️ Recording started at \(formatter.string(from: now)) (max duration: \(Int(maxDurationSeconds))s)")

            // Start fixed duration timer
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            timer.schedule(deadline: .now() + maxDurationSeconds)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.bridgedLog("🛑 Recording auto-stopped (duration: \(Int(maxDurationSeconds))s reached)")
                self.stopRecordingInternal(wasManualStop: false)
            }
            timer.resume()
            self.fixedDurationTimer = timer

            promise.resolve(withResult: ())
        }

        return promise
    }

    /**
     * End recording early (before max duration is reached).
     * If no recording is active, this is a no-op.
     */
    public func endRecording() throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            if self.isRecordingSession {
                self.bridgedLog("🛑 Recording ended manually")
                self.stopRecordingInternal(wasManualStop: true)
            } else {
                self.bridgedLog("⚠️ endRecording called but no recording is active")
            }

            promise.resolve(withResult: ())
        }

        return promise
    }

    /**
     * Internal method to stop recording and fire callback
     */
    private func stopRecordingInternal(wasManualStop: Bool) {
        // Cancel the timer
        self.fixedDurationTimer?.cancel()
        self.fixedDurationTimer = nil

        // Calculate actual duration
        var duration: Double = 0
        if let startTime = self.recordingStartTime {
            duration = Date().timeIntervalSince(startTime)
        }

        // Stop the recording session
        guard self.isRecordingSession else { return }
        self.isRecordingSession = false

        // Drain remaining samples synchronously
        processingQueue?.sync { [weak self] in
            self?.drainAndProcess()
        }

        // Stop worker
        processingTimer?.cancel()
        processingTimer = nil

        // Close file and get metadata
        guard let metadata = endCurrentSegmentWithoutCallback() else {
            self.bridgedLog("⚠️ No segment to close in stopRecordingInternal")
            return
        }

        // Process file and fire callback (no trimming for simple recording)
        processAndFireSegmentCallback(metadata: metadata, trimSeconds: 0)

        let endTime = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        self.bridgedLog("🛑 Recording ended at \(formatter.string(from: endTime)) (duration: \(String(format: "%.1f", duration))s, manual: \(wasManualStop))")
    }

    /**
     * Check if recording is currently active
     */
    public func isSegmentRecording() throws -> Promise<Bool> {
        let promise = Promise<Bool>()
        promise.resolve(withResult: self.isRecordingSession)
        return promise
    }

    // MARK: - Worker Queue (RT-Safe Audio Processing)

    /// Start the recording session - activates worker to drain SPSC buffer and write to file
    /// Called when user starts recording (dream recording, day residue, etc.)
    private func startRecordingSession(fileURL: URL) {
        // Create SPSC buffer if not exists
        // samplesPerChunk must be >= actual tap buffer size (iOS gives ~4800 frames at 48kHz)
        if spscBuffer == nil {
            spscBuffer = SPSCRingBuffer(capacity: 64, samplesPerChunk: 8192)
        }
        spscBuffer?.reset()
        workerChunkCounter = 0  // Reset debug counters for new session
        tapCallbackCounter = 0

        // Open file for writing at 16kHz format
        guard let targetFormat = self.targetFormat else {
            bridgedLog("❌ Cannot start recording session: targetFormat is nil")
            return
        }

        do {
            currentSegmentFile = try AVAudioFile(forWriting: fileURL, settings: targetFormat.settings)
            segmentStartTime = Date()
            isRecordingSession = true
            bridgedLog("🎙️ Recording session started: \(fileURL.lastPathComponent)")
        } catch {
            bridgedLog("❌ Failed to create segment file: \(error.localizedDescription)")
            return
        }

        // Start worker queue
        processingQueue = DispatchQueue(label: "com.hypnos.audioProcessing", qos: .userInitiated)
        processingTimer = DispatchSource.makeTimerSource(queue: processingQueue)
        processingTimer?.schedule(deadline: .now(), repeating: .milliseconds(10))
        processingTimer?.setEventHandler { [weak self] in
            self?.drainAndProcess()
        }
        processingTimer?.resume()
    }

    /// Stop the recording session - drains remaining audio and closes file
    private func stopRecordingSession() {
        guard isRecordingSession else { return }

        isRecordingSession = false

        // Drain remaining samples synchronously
        processingQueue?.sync { [weak self] in
            self?.drainAndProcess()
        }

        // Stop worker
        processingTimer?.cancel()
        processingTimer = nil

        // Close file and get metadata
        guard let metadata = endCurrentSegmentWithoutCallback() else {
            bridgedLog("⚠️ No segment to close in stopRecordingSession")
            return
        }

        // Check for overflow during session
        if let spsc = spscBuffer {
            let overflows = spsc.overflows
            if overflows > 0 {
                bridgedLog("⚠️ Recording had \(overflows) buffer overflows (dropped audio)")
            }
        }

        // Process file (resample) and fire callback - no trim for explicit stop
        processAndFireSegmentCallback(metadata: metadata, trimSeconds: 0)
        bridgedLog("🛑 Recording session stopped")
    }

    /// Worker loop - drain SPSC ring buffer, resample, write to file
    /// Called every 10ms by the worker timer
    /// SIMPLIFIED: No VAD or silence detection - just resample and write
    private func drainAndProcess() {
        guard isRecordingSession, let spsc = spscBuffer else { return }

        // Process all available chunks
        while let (samples48k, frameLength) = spsc.read() {
            // Skip empty chunks
            guard frameLength > 0 else { continue }

            // Log every ~1 second (10 chunks at ~100ms each)
            // Safe here: worker thread is NOT RT-constrained
            workerChunkCounter += 1
            if workerChunkCounter % 10 == 1 {
                bridgedLog("🎤 Tap→Worker | tap callbacks: \(tapCallbackCounter) | worker chunks: \(workerChunkCounter) | frames: \(frameLength) | queued: \(spsc.availableChunks)")
            }

            // 1. Resample 48kHz → 16kHz
            guard let samples16k = resampleOnWorker(samples48k, frameLength: frameLength) else {
                continue
            }

            // DISABLED: VAD/silence detection
            // let audioIsLoud = runVADOnWorker(samples16k)
            // handleSilenceDetectionOnWorker(audioIsLoud: audioIsLoud)

            // 2. Write to file
            if isRecordingSession, let segmentFile = currentSegmentFile {
                do {
                    try segmentFile.write(from: samples16k)
                } catch {
                    // Silent fail to avoid log spam
                }
            }
        }
    }

    /// Resample raw 48kHz samples to 16kHz on worker queue
    /// - Parameters:
    ///   - samples48k: Pointer to 48kHz float samples from SPSC buffer
    ///   - frameLength: Number of frames in the buffer
    /// - Returns: AVAudioPCMBuffer at 16kHz or nil on failure
    private func resampleOnWorker(_ samples48k: UnsafePointer<Float>, frameLength: Int) -> AVAudioPCMBuffer? {
        guard let inputFormat = workerInputFormat,
              let converter = audioConverter,
              let targetFormat = targetFormat else {
            return nil
        }

        // Create input buffer wrapper around the raw samples
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameLength)) else {
            return nil
        }
        inputBuffer.frameLength = AVAudioFrameCount(frameLength)

        // Copy samples into input buffer
        if let destPtr = inputBuffer.floatChannelData?[0] {
            memcpy(destPtr, samples48k, frameLength * MemoryLayout<Float>.size)
        }

        // Calculate output frame capacity based on sample rate ratio
        let sampleRateRatio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(frameLength) * sampleRateRatio)

        // Create output buffer at target format (16kHz)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        var error: NSError?
        var inputConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            bridgedLog("⚠️ Worker resample error: \(error.localizedDescription)")
            return nil
        }

        return outputBuffer
    }

    // MARK: - Player Node Helpers

    private func getCurrentPlayerNode() -> AVAudioPlayerNode? {
        // For now, always use player A. Later we can implement switching for crossfading
        switch activePlayer {
        case .playerA:
            return audioPlayerNodeA
        case .playerB:
            return audioPlayerNodeB
        case .playerC:
            return audioPlayerNodeC
        case .none:
            // Default to player A for first use
            activePlayer = .playerA
            return audioPlayerNodeA
        }
    }

    private func getPlayerEnum(for node: AVAudioPlayerNode?) -> ActivePlayer {
        guard let node = node else { return .none }
        if node === audioPlayerNodeA { return .playerA }
        if node === audioPlayerNodeB { return .playerB }
        if node === audioPlayerNodeC { return .playerC }
        return .none
    }

    private func getNodeName(for node: AVAudioPlayerNode?) -> String {
        guard let node = node else { return "NONE" }
        if node === audioPlayerNodeA { return "A" }
        if node === audioPlayerNodeB { return "B" }
        if node === audioPlayerNodeC { return "C" }
        if node === audioPlayerNodeD { return "D (Ambient)" }
        return "UNKNOWN"
    }

    // MARK: - Playback Completion Helpers

    private func handlePlaybackCompletion() {
        if let audioFile = self.currentAudioFile {
            let durationSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            let durationMs = durationSeconds * 1000
            self.emitPlaybackEndEvents(durationMs: durationMs, includePlaybackUpdate: true)
        }

        self.stopPlayTimer()
        self.currentPlayerNode = nil
    }

    private func scheduleMoreLoops(audioFile: AVAudioFile, playerNode: AVAudioPlayerNode) {
        guard self.shouldLoopPlayback else {
            return
        }

        // Schedule 3 more iterations
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            // Recursive scheduling for continuous looping
            self?.scheduleMoreLoops(audioFile: audioFile, playerNode: playerNode)
        }
    }

    private func scheduleMoreAmbientLoops(audioFile: AVAudioFile, playerNode: AVAudioPlayerNode) {
        guard self.isAmbientLoopPlaying else {
            return
        }

        // Schedule 3 more iterations
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            // Recursive scheduling for continuous looping
            self?.scheduleMoreAmbientLoops(audioFile: audioFile, playerNode: playerNode)
        }
    }

    // MARK: - Now Playing (Lock Screen Controls)

    /// Setup remote command center for lock screen controls
    private var remoteCommandsConfigured = false

    private func setupRemoteCommandCenter() {
        // Only setup once
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }

            self.bridgedLog("🎵 Now Playing: Play command received")

            // Resume playback
            if let playerNode = self.currentPlayerNode {
                if !playerNode.isPlaying {
                    playerNode.play()
                    self.updateNowPlayingPlaybackState(isPlaying: true)
                    DispatchQueue.main.async {
                        self.startPlayTimer()
                    }
                    // Notify JS/UI that play was triggered from lock screen
                    self.playCallback?()
                }
            }

            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }

            self.bridgedLog("🎵 Now Playing: Pause command received")

            // Pause playback
            if let playerNode = self.currentPlayerNode {
                if playerNode.isPlaying {
                    playerNode.pause()
                    self.stopPlayTimer()
                    self.updateNowPlayingPlaybackState(isPlaying: false)
                    // Notify JS/UI that pause was triggered from lock screen
                    self.pauseCallback?()
                }
            }

            return .success
        }

        // Toggle play/pause (for headphone controls)
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }

            self.bridgedLog("🎵 Now Playing: Toggle play/pause")

            if let playerNode = self.currentPlayerNode {
                if playerNode.isPlaying {
                    playerNode.pause()
                    self.stopPlayTimer()
                    self.updateNowPlayingPlaybackState(isPlaying: false)
                    // Notify JS/UI that pause was triggered from lock screen/headphones
                    self.pauseCallback?()
                } else {
                    playerNode.play()
                    self.updateNowPlayingPlaybackState(isPlaying: true)
                    DispatchQueue.main.async {
                        self.startPlayTimer()
                    }
                    // Notify JS/UI that play was triggered from lock screen/headphones
                    self.playCallback?()
                }
            }

            return .success
        }

        // Seek command (scrubbing on lock screen)
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            let targetTime = positionEvent.positionTime
            self.bridgedLog("🎵 Now Playing: Seek to \(targetTime)s")

            // Convert to milliseconds and seek
            let targetMs = Double(targetTime * 1000)

            // Call existing seek method
            do {
                _ = try self.seekToPlayer(time: targetMs)

                // Update Now Playing position immediately after seek
                if let audioFile = self.currentAudioFile {
                    let durationSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                    self.updateNowPlayingInfo(
                        title: self.currentTrackTitle,
                        artist: nil,
                        duration: durationSeconds,
                        currentTime: targetTime
                    )
                }

                return .success
            } catch {
                self.bridgedLog("❌ Seek failed: \(error)")
                return .commandFailed
            }
        }

        // Next track command (skip forward)
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }

            self.bridgedLog("⏭️  Now Playing: Next track command")

            // Call the callback if registered
            if let callback = self.nextTrackCallback {
                callback()
                return .success
            }

            return .commandFailed
        }

        // Previous track command (skip backward)
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] event in
            guard let self = self else { return .commandFailed }

            self.bridgedLog("⏮️  Now Playing: Previous track command")

            // Call the callback if registered
            if let callback = self.previousTrackCallback {
                callback()
                return .success
            }

            return .commandFailed
        }
    }

    /// Update Now Playing info on lock screen
    private func updateNowPlayingInfo(
        title: String,
        artist: String? = nil,
        duration: Double,
        currentTime: Double
    ) {
        var nowPlayingInfo = [String: Any]()

        // Track metadata
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        nowPlayingInfo[MPMediaItemPropertyArtist] = artist ?? self.currentTrackArtist

        // Timing
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0

        // CRITICAL: Mark as NOT a live stream to enable lock screen scrubbing
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = false

        // Artwork (optional)
        if let artwork = self.nowPlayingArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        // Update the info center
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo

        // Cache values
        self.currentTrackTitle = title
        if let artist = artist {
            self.currentTrackArtist = artist
        }
        self.currentTrackDuration = duration
    }

    /// Update only playback state (for pause/resume without recalculating everything)
    private func updateNowPlayingPlaybackState(isPlaying: Bool) {
        guard var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            return
        }

        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // Use cached lastValidPosition (in ms) - more reliable than querying paused player
        let currentTimeSeconds = self.lastValidPosition / 1000.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, currentTimeSeconds)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    /// Clear Now Playing info from lock screen
    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        bridgedLog("🎵 Now Playing info cleared")
    }

    // MARK: - File Writing Methods

    private func trimLastSeconds(_ seconds: Double, fromFileAt url: URL) throws {
        guard seconds > 0 else { return }

        // Read the original file
        let originalFile = try AVAudioFile(forReading: url)
        let format = originalFile.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = originalFile.length
        let originalDuration = Double(totalFrames) / sampleRate

        // Calculate frames to keep (remove last N seconds)
        let framesToRemove = AVAudioFramePosition(seconds * sampleRate)
        let framesToKeep = max(0, totalFrames - framesToRemove)

        guard framesToKeep > 0 else {
            bridgedLog("⚠️ Trim would remove entire file, skipping")
            return
        }

        // Create temp file
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("temp_trim_\(UUID().uuidString).wav")
        let trimmedFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)

        // Read and write frames in chunks
        let bufferSize: AVAudioFrameCount = 4096
        var framesRead: AVAudioFramePosition = 0

        while framesRead < framesToKeep {
            let framesToRead = min(bufferSize, AVAudioFrameCount(framesToKeep - framesRead))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw RuntimeError.error(withMessage: "Failed to create buffer for trimming")
            }

            try originalFile.read(into: buffer, frameCount: framesToRead)
            try trimmedFile.write(from: buffer)

            framesRead += AVAudioFramePosition(buffer.frameLength)
        }

        // Replace original with trimmed version
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)

        let trimmedDuration = Double(framesToKeep) / sampleRate
        bridgedLog("✂️ Trim: \(String(format: "%.1f", originalDuration))s original → removed \(String(format: "%.1f", seconds))s silence → \(String(format: "%.1f", trimmedDuration))s final")
    }


    /// Ends the current segment and returns metadata for later callback
    /// Use this when you need to process the audio file before firing the callback
    /// Returns: Tuple with (filename, filePath, fileURL, isManual) or nil if no segment
    private func endCurrentSegmentWithoutCallback() -> (filename: String, filePath: String, fileURL: URL, isManual: Bool)? {
        guard let segmentFile = currentSegmentFile else { return nil }

        // Get file info before closing
        let filename = segmentFile.url.lastPathComponent
        let fileURL = segmentFile.url

        // Get relative path from Documents directory for cross-device compatibility
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let absolutePath = segmentFile.url.path
        let filePath = absolutePath.replacingOccurrences(of: documentsPath + "/", with: "")

        let isManual = self.currentSegmentIsManual

        // Close the file
        currentSegmentFile = nil
        segmentStartTime = nil
        silenceCounter = 0

        return (filename: filename, filePath: filePath, fileURL: fileURL, isManual: isManual)
    }

    /// Process a segment with trim + resample, then fire callback
    /// Use this for ALL manual segments to ensure proper playback speed
    private func processAndFireSegmentCallback(metadata: (filename: String, filePath: String, fileURL: URL, isManual: Bool), trimSeconds: Double) {
        // Trim silence from the end
        do {
            try self.trimLastSeconds(trimSeconds, fromFileAt: metadata.fileURL)
        } catch {
            bridgedLog("⚠️ Failed to trim silence: \(error.localizedDescription)")
        }

        // Note: 16kHz files are kept as-is - expo-av, SFSpeechRecognizer, and Groq all handle 16kHz fine

        // Read the actual processed file duration
        var actualDuration: Double = 0
        do {
            let processedFile = try AVAudioFile(forReading: metadata.fileURL)
            actualDuration = Double(processedFile.length) / processedFile.processingFormat.sampleRate
        } catch {
            bridgedLog("⚠️ Failed to read processed file: \(error.localizedDescription)")
        }

        // Fire callback with processed file info
        if let callback = self.segmentCallback {
            callback(metadata.filename, metadata.filePath, metadata.isManual, actualDuration)
        } else {
            bridgedLog("⚠️ No callback set for segment")
        }
    }

    // MARK: - Playback Methods

    public func startPlayer(uri: String?, httpHeaders: Dictionary<String, String>?) throws -> Promise<String> {
        let promise = Promise<String>()

        // Return immediately and process in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            do {
                try self.setupAudioEngine()

                // Log if engine is not running (diagnostic - no auto-restart)
                if let engine = self.audioEngine, !engine.isRunning {
                    self.bridgedLog("⚠️ ENGINE NOT RUNNING at startPlayer entry")
                }

                // Note: Remote commands are NOT set up here - they're only set up
                // when updateNowPlaying() is explicitly called (evening phases only)

                guard let uri = uri, !uri.isEmpty else {
                    self.bridgedLog("❌ PLAYBACK: No URI provided")
                    promise.reject(withError: RuntimeError.error(withMessage: "URI is required for playback"))
                    return
                }

                self.currentPlaybackURI = uri

                // Handle all URLs the same way with AVAudioFile
                let url: URL
                if uri.hasPrefix("http") {
                    url = URL(string: uri)!
                } else if uri.hasPrefix("file://") {
                    url = URL(string: uri)!
                } else {
                    url = URL(fileURLWithPath: uri)
                }

                // For local files, check if file exists
                if !uri.hasPrefix("http") {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        self.bridgedLog("❌ PLAYBACK: File not found - \(url.lastPathComponent)")
                        promise.reject(withError: RuntimeError.error(withMessage: "Audio file does not exist at path: \(uri)"))
                        return
                    }
                }

                // Load the audio file
                let audioFile: AVAudioFile
                if uri.hasPrefix("http") {
                    let data = try Data(contentsOf: url)
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("temp_audio_\(UUID().uuidString).m4a")
                    try data.write(to: tempURL)
                    audioFile = try AVAudioFile(forReading: tempURL)
                } else {
                    audioFile = try AVAudioFile(forReading: url)
                }

                self.currentAudioFile = audioFile

                // Reset starting frame offset (playing from beginning)
                self.startingFrameOffset = 0

                // Get the current player node (will alternate for crossfading in future)
                guard let playerNode = self.getCurrentPlayerNode() else {
                    promise.reject(withError: RuntimeError.error(withMessage: "Failed to get player node"))
                    return
                }

                self.currentPlayerNode = playerNode

                // Stop any current playback on this node
                playerNode.stop()

                // Set volume (use playbackVolume if set, otherwise default to 1.0)
                playerNode.volume = self.playbackVolume

                // Schedule file for playback
                if self.shouldLoopPlayback {
                    // CRITICAL: Set looping file URI before starting seamless loop
                    self.currentLoopingFileURI = url.absoluteString
                    // Use crossfade looping for seamless M4A loops
                    self.startSeamlessLoop(audioFile: audioFile, url: url)
                } else {
                    // Non-looping: schedule file with completion handler that stops the player
                    playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                        guard let self = self else { return }

                        // Get current position when completion fires
                        var currentPos: Double = 0
                        if let nodeTime = playerNode.lastRenderTime,
                           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                            currentPos = Double(playerTime.sampleTime) / audioFile.fileFormat.sampleRate
                        }

                        // DO NOT call stop() here - this completion handler fires when the buffer is SCHEDULED,
                        // not when playback ends. Calling stop() here causes premature audio cutoff.
                        // The timer-based detection (60ms polling of isPlaying) handles actual playback completion.
                    }
                }

                // Play on main queue
                DispatchQueue.main.async {
                    self.didEmitPlaybackEnd = false
                    self.startPlayTimer()

                    playerNode.play()
                    self.bridgedLog("🎵 PLAYING on Node \(self.getNodeName(for: playerNode)): \(url.lastPathComponent)")

                    // Update Now Playing with track info
                    let filename = url.lastPathComponent
                    let title = filename.replacingOccurrences(of: ".mp3", with: "")
                                       .replacingOccurrences(of: ".m4a", with: "")
                                       .replacingOccurrences(of: ".wav", with: "")
                    let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                    self.updateNowPlayingInfo(
                        title: title,
                        artist: nil,
                        duration: duration,
                        currentTime: 0
                    )

                    promise.resolve(withResult: uri)
                }

            } catch {
                self.bridgedLog("❌ Playback error: \(error.localizedDescription)")
                promise.reject(withError: RuntimeError.error(withMessage: "Playback error: \(error.localizedDescription)"))
            }
        }

        return promise
    }

    // MARK: - Seamless Loop Methods

    private func startSeamlessLoop(audioFile: AVAudioFile, url: URL) {
        guard let primaryNode = self.currentPlayerNode else { return }

        // Schedule first playback
        primaryNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        // Pre-schedule next iteration to prevent gaps (maintains buffer queue)
        primaryNode.scheduleFile(audioFile, at: nil, completionHandler: nil)

        // Calculate when to trigger crossfade (20ms before end)
        let totalDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        let crossfadeStartTime = max(0, totalDuration - self.loopCrossfadeDuration)

        // Schedule crossfade timer
        self.scheduleLoopCrossfade(after: crossfadeStartTime, audioFile: audioFile, url: url)
    }

    private func scheduleLoopCrossfade(after delay: TimeInterval, audioFile: AVAudioFile, url: URL) {
        // Cancel any existing timer
        self.loopCrossfadeTimer?.cancel()
        self.loopCrossfadeTimer = nil

        // Create new timer
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + delay)

        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            // Check if looping is still enabled
            guard self.shouldLoopPlayback else {
                return
            }

            self.triggerSeamlessLoopCrossfade(audioFile: audioFile, url: url)
        }

        self.loopCrossfadeTimer = timer
        timer.resume()
    }

    private func triggerSeamlessLoopCrossfade(audioFile: AVAudioFile, url: URL) {
        bridgedLog("🔄 triggerSeamlessLoopCrossfade ENTER - url: \(url.lastPathComponent)")
        bridgedLog("   shouldLoopPlayback: \(self.shouldLoopPlayback), isLoopCrossfadeActive: \(self.isLoopCrossfadeActive)")
        bridgedLog("   url match: \(url.absoluteString == self.currentLoopingFileURI) (current: \(self.currentLoopingFileURI?.components(separatedBy: "/").last ?? "nil"))")

        guard self.shouldLoopPlayback,
              !self.isLoopCrossfadeActive,
              url.absoluteString == self.currentLoopingFileURI else {
            bridgedLog("🔄 triggerSeamlessLoopCrossfade SKIPPED - guard failed")
            return
        }

        self.isLoopCrossfadeActive = true
        bridgedLog("🔄 triggerSeamlessLoopCrossfade PROCEEDING - crossfade active")

        // Get alternate player node
        let newNode: AVAudioPlayerNode
        let oldNode = self.currentPlayerNode!

        // 3-node rotation: A→B→C→A
        switch self.activePlayer {
        case .playerA:
            newNode = self.audioPlayerNodeB!
        case .playerB:
            newNode = self.audioPlayerNodeC!
        case .playerC:
            newNode = self.audioPlayerNodeA!
        case .none:
            newNode = self.audioPlayerNodeA!
        }

        let totalDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate

        // Prepare new node
        newNode.stop()
        newNode.reset()
        newNode.volume = 0.0
        newNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        // Pre-schedule next iteration to prevent gaps (maintains buffer queue)
        newNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
        newNode.play()

        // Schedule next crossfade IMMEDIATELY (before crossfade completes)
        // This ensures timing is relative to when playback STARTED, not when fade finishes
        let crossfadeStartTime = max(0, totalDuration - self.loopCrossfadeDuration)
        self.scheduleLoopCrossfade(after: crossfadeStartTime, audioFile: audioFile, url: url)

        // Crossfade - use actual node volume, not stored playbackVolume
        self.fadeVolume(node: oldNode, from: oldNode.volume, to: 0.0, duration: self.loopCrossfadeDuration) {
            oldNode.stop()
            oldNode.reset()
        }

        self.fadeVolume(node: newNode, from: 0.0, to: self.playbackVolume, duration: self.loopCrossfadeDuration) { [weak self] in
            guard let self = self else { return }
            // Update current player reference and reset flag
            self.currentPlayerNode = newNode
            self.activePlayer = self.getPlayerEnum(for: newNode)
            self.isLoopCrossfadeActive = false
        }
    }

    public func setLoopEnabled(enabled: Bool) throws -> Promise<String> {
        let promise = Promise<String>()

        let previousState = self.shouldLoopPlayback
        self.shouldLoopPlayback = enabled
        let status = enabled ? "enabled" : "disabled"

        bridgedLog("🔁 setLoopEnabled: \(status) (was: \(previousState ? "enabled" : "disabled"))")
        bridgedLog("   currentPlayerNode: \(self.getNodeName(for: self.currentPlayerNode)), playing: \(self.currentPlayerNode?.isPlaying ?? false)")
        bridgedLog("   currentLoopingFileURI: \(self.currentLoopingFileURI ?? "nil")")

        promise.resolve(withResult: "Loop \(status)")
        return promise
    }

    public func stopPlayer() throws -> Promise<String> {
        let promise = Promise<String>()

        self.bridgedLog("🛑 STOPPING Node \(self.getNodeName(for: self.currentPlayerNode)) (stopPlayer called)")

        // Cancel loop crossfade timer
        self.loopCrossfadeTimer?.cancel()
        self.loopCrossfadeTimer = nil
        self.isLoopCrossfadeActive = false

        // Stop AND RESET both player nodes
        if let playerA = self.audioPlayerNodeA {
            playerA.stop()
            playerA.reset()  // Clear all scheduled buffers and reset state
            playerA.volume = 1.0 // Reset volume
        }

        if let playerB = self.audioPlayerNodeB {
            playerB.stop()
            playerB.reset()  // Clear all scheduled buffers and reset state
            playerB.volume = 1.0 // Reset volume
        }

        // NOTE: Ambient loop (Player D) is NOT stopped here.
        // JS layer manages ambient lifecycle explicitly via stopAmbientLoop()
        // to allow proper fade outs. See NitroSoundManager.stopAmbientLoop()

        self.currentPlayerNode = nil

        // Clear the audio file reference
        self.currentAudioFile = nil

        // Stop the play timer
        self.stopPlayTimer()

        // Reset active player state
        self.activePlayer = .none

        // Clear loop state
        self.shouldLoopPlayback = false
        self.currentPlaybackURI = nil

        // Reset position cache
        self.lastValidPosition = 0.0

        // Clear Now Playing info
        self.clearNowPlayingInfo()

        // Keep the unified engine running for recording or future playback
        promise.resolve(withResult: "Player stopped")

        return promise
    }

    public func pausePlayer() throws -> Promise<String> {
        let promise = Promise<String>()

        if let playerNode = self.currentPlayerNode {
            playerNode.pause()

            // Also pause ambient loop if playing (uses dedicated Player D)
            // Use micro-fade to avoid audio click
            if isAmbientLoopPlaying, let playerD = audioPlayerNodeD {
                let currentVolume = playerD.volume
                self.ambientVolumeBeforePause = currentVolume  // Store for resume

                // Quick fade out (100ms) then pause
                self.fadeVolume(node: playerD, from: currentVolume, to: 0.0, duration: 0.1) {
                    playerD.pause()
                }
            }

            self.stopPlayTimer()
            self.didEmitPlaybackEnd = true  // Prevent native listener from firing while paused
            self.updateNowPlayingPlaybackState(isPlaying: false)
            promise.resolve(withResult: "Player paused")
        } else {
            promise.reject(withError: RuntimeError.error(withMessage: "No active player node"))
        }

        return promise
    }

    public func resumePlayer() throws -> Promise<String> {
        let promise = Promise<String>()

        if let playerNode = self.currentPlayerNode {
            playerNode.play()

            // Also resume ambient loop if it was playing (uses dedicated Player D)
            // Use micro-fade to avoid audio click
            if isAmbientLoopPlaying, let playerD = audioPlayerNodeD {
                let targetVolume = self.ambientVolumeBeforePause ?? 0.3  // Default to 0.3 if not stored
                playerD.volume = 0.0  // Start at 0
                playerD.play()

                // Quick fade in (100ms)
                self.fadeVolume(node: playerD, from: 0.0, to: targetVolume, duration: 0.1, completion: nil)
            }

            self.updateNowPlayingPlaybackState(isPlaying: true)
            DispatchQueue.main.async {
                self.startPlayTimer()
            }
            promise.resolve(withResult: "Player resumed")
        } else {
            promise.reject(withError: RuntimeError.error(withMessage: "No active player node"))
        }

        return promise
    }

    public func seekToPlayer(time: Double) throws -> Promise<String> {
        let promise = Promise<String>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self,
                  let playerNode = self.currentPlayerNode,
                  let audioFile = self.currentAudioFile else {
                promise.reject(withError: RuntimeError.error(withMessage: "No active playback"))
                return
            }

            // Calculate and clamp frame position
            let sampleRate = audioFile.fileFormat.sampleRate
            let totalFrames = audioFile.length
            let timeInSeconds = time / 1000.0  // Convert milliseconds to seconds
            let targetFrame = AVAudioFramePosition(timeInSeconds * sampleRate)
            let clampedFrame = max(0, min(targetFrame, totalFrames))
            let remainingFrames = totalFrames - clampedFrame

            // Guard: If no frames left to play, stop playback
            guard remainingFrames > 0 else {
                playerNode.stop()
                let seekTimeSeconds = Double(clampedFrame) / sampleRate
                promise.resolve(withResult: "Seeked to end (\(String(format: "%.1f", seekTimeSeconds))s)")
                return
            }

            // Preserve state
            let wasPlaying = playerNode.isPlaying
            let volume = playerNode.volume

            // Cancel old crossfade timer (invalidated by seek)
            self.loopCrossfadeTimer?.cancel()
            self.loopCrossfadeTimer = nil
            self.isLoopCrossfadeActive = false

            // Stop and reset
            playerNode.stop()
            playerNode.reset()

            // Save the starting frame offset for getCurrentPosition
            self.startingFrameOffset = clampedFrame

            // Schedule from new position
            if self.shouldLoopPlayback {
                // Use scheduleSegment for precise frame control
                playerNode.scheduleSegment(
                    audioFile,
                    startingFrame: clampedFrame,
                    frameCount: AVAudioFrameCount(remainingFrames),
                    at: nil,
                    completionHandler: nil
                )

                // Calculate remaining duration
                let totalDuration = Double(totalFrames) / sampleRate
                let seekTime = Double(clampedFrame) / sampleRate
                let remainingDuration = totalDuration - seekTime

                // Recalculate crossfade timing
                let crossfadeStartTime = max(0, remainingDuration - self.loopCrossfadeDuration)

                self.bridgedLog("🔍 Seeked to \(String(format: "%.2f", seekTime))s, crossfade in \(String(format: "%.2f", crossfadeStartTime))s")

                // Get URL and reschedule crossfade
                if let uri = self.currentPlaybackURI {
                    let url: URL
                    if uri.hasPrefix("http") {
                        url = URL(string: uri)!
                    } else if uri.hasPrefix("file://") {
                        url = URL(string: uri)!
                    } else {
                        url = URL(fileURLWithPath: uri)
                    }

                    self.scheduleLoopCrossfade(after: crossfadeStartTime, audioFile: audioFile, url: url)
                }

            } else {
                // Non-looping: schedule with completion handler
                playerNode.scheduleSegment(
                    audioFile,
                    startingFrame: clampedFrame,
                    frameCount: AVAudioFrameCount(remainingFrames),
                    at: nil
                ) { [weak self] in
                    DispatchQueue.main.async {
                        playerNode.stop()
                    }
                }
            }

            // Restore state
            playerNode.volume = volume
            if wasPlaying {
                playerNode.play()
            }

            let seekTimeSeconds = Double(clampedFrame) / sampleRate

            // Update position cache to the seeked position (in milliseconds)
            self.lastValidPosition = seekTimeSeconds * 1000.0

            promise.resolve(withResult: "Seeked to \(String(format: "%.1f", seekTimeSeconds))s")
        }

        return promise
    }

    public func setVolume(volume: Double) throws -> Promise<String> {
        let promise = Promise<String>()

        // Store the desired playback volume for crossfades
        self.playbackVolume = Float(volume)

        if let playerNode = self.currentPlayerNode {
            playerNode.volume = Float(volume)
            promise.resolve(withResult: "Volume set to \(volume)")
        } else if let engine = self.audioEngine {
            engine.mainMixerNode.outputVolume = Float(volume)
            promise.resolve(withResult: "Volume set to \(volume)")
        } else {
            promise.reject(withError: RuntimeError.error(withMessage: "No player instance"))
        }

        return promise
    }

    // MARK: - Public Now Playing Methods

    /// Public method to update Now Playing info from TypeScript
    /// This also sets up remote commands (play/pause buttons on lock screen)
    /// Only call this during phases where lock screen controls are wanted (evening)
    public func updateNowPlaying(
        title: String,
        artist: String,
        duration: Double,
        currentTime: Double
    ) throws -> Promise<Void> {
        let promise = Promise<Void>()

        // Setup remote commands when Now Playing is explicitly requested
        // This ensures lock screen controls only appear during evening phases
        setupRemoteCommandCenter()

        updateNowPlayingInfo(
            title: title,
            artist: artist,
            duration: duration,
            currentTime: currentTime
        )

        promise.resolve(withResult: ())
        return promise
    }

    /// Public method to clear Now Playing info from TypeScript
    public func clearNowPlaying() throws -> Promise<Void> {
        let promise = Promise<Void>()

        clearNowPlayingInfo()

        promise.resolve(withResult: ())
        return promise
    }

    /// Completely tear down remote command center - removes all targets and clears Now Playing.
    /// Widget will disappear as if it was never configured.
    public func teardownRemoteCommands() throws -> Promise<Void> {
        let promise = Promise<Void>()

        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove ALL targets with nil (Apple docs: "Specify nil to remove all targets")
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)

        // Disable all commands
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false

        // Clear Now Playing info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        // Reset flag so setupRemoteCommandCenter can run again if needed
        self.remoteCommandsConfigured = false

        bridgedLog("🎛️ Remote command center torn down - widget removed")

        promise.resolve(withResult: ())
        return promise
    }

    /// Set artwork for Now Playing lock screen display
    public func setNowPlayingArtwork(imagePath: String) throws -> Promise<Void> {
        let promise = Promise<Void>()

        // Handle file:// prefix if present
        let cleanPath = imagePath.hasPrefix("file://")
            ? String(imagePath.dropFirst(7))
            : imagePath

        // Load the image from the path
        guard let image = UIImage(contentsOfFile: cleanPath) else {
            bridgedLog("⚠️ Failed to load artwork image from: \(cleanPath)")
            promise.resolve(withResult: ())
            return promise
        }

        // Create MPMediaItemArtwork
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
            return image
        }

        // Store for use in updateNowPlayingInfo
        self.nowPlayingArtwork = artwork

        // Update existing Now Playing info with artwork if already set
        if var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }

        promise.resolve(withResult: ())
        return promise
    }

    public func getCurrentPosition() throws -> Promise<Double> {
        let promise = Promise<Double>()

        guard let playerNode = self.currentPlayerNode,
              let audioFile = self.currentAudioFile,
              playerNode.isPlaying else {
            // Return cached position instead of 0 when player is paused/transitioning
            promise.resolve(withResult: self.lastValidPosition)
            return promise
        }

        // Get last render time to calculate current position
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            // Return cached position instead of 0 when timing info unavailable
            promise.resolve(withResult: self.lastValidPosition)
            return promise
        }

        // Calculate position in milliseconds
        // Add the starting frame offset to account for seeks
        let sampleRate = audioFile.fileFormat.sampleRate
        let totalSampleTime = self.startingFrameOffset + playerTime.sampleTime
        let positionSeconds = Double(totalSampleTime) / sampleRate
        let positionMs = positionSeconds * 1000.0

        // Cache the valid position before returning
        self.lastValidPosition = positionMs

        promise.resolve(withResult: positionMs)
        return promise
    }

    public func getDuration() throws -> Promise<Double> {
        let promise = Promise<Double>()

        guard let audioFile = self.currentAudioFile else {
            promise.resolve(withResult: 0.0)
            return promise
        }

        // Get actual playable duration (uses AVAsset for M4A to exclude AAC padding)
        let durationSeconds = getActualDurationSeconds(audioFile: audioFile)
        let durationMs = durationSeconds * 1000.0

        promise.resolve(withResult: durationMs)
        return promise
    }

    // MARK: - Listeners

    public func addPlayBackListener(callback: @escaping (PlayBackType) -> Void) throws {
        self.playBackListener = callback
    }

    public func removePlayBackListener() throws {
        self.playBackListener = nil
        self.stopPlayTimer()
    }

    public func addPlaybackEndListener(callback: @escaping (PlaybackEndType) -> Void) throws {
        self.playbackEndListener = callback
    }

    public func removePlaybackEndListener() throws {
        self.playbackEndListener = nil
    }

    // MARK: - Logging Methods

    public func setLogCallback(callback: @escaping (String) -> Void) throws {
        self.logCallback = callback
    }

    public func setSegmentCallback(callback: @escaping (String, String, Bool, Double) -> Void) throws {
        self.segmentCallback = callback
    }

    // DISABLED: Manual silence callback removed with simplified recording
    // public func setManualSilenceCallback(callback: @escaping () -> Void) throws {
    //     self.manualSilenceCallback = callback
    // }

    public func setNextTrackCallback(callback: @escaping () -> Void) throws {
        self.nextTrackCallback = callback
        bridgedLog("⏭️  Next track callback registered")
    }

    public func removeNextTrackCallback() throws {
        self.nextTrackCallback = nil
        bridgedLog("⏭️  Next track callback removed")
    }

    public func setPreviousTrackCallback(callback: @escaping () -> Void) throws {
        self.previousTrackCallback = callback
        bridgedLog("⏮️  Previous track callback registered")
    }

    public func removePreviousTrackCallback() throws {
        self.previousTrackCallback = nil
        bridgedLog("⏮️  Previous track callback removed")
    }

    public func setPauseCallback(callback: @escaping () -> Void) throws {
        self.pauseCallback = callback
        bridgedLog("⏸️  Pause callback registered")
    }

    public func removePauseCallback() throws {
        self.pauseCallback = nil
        bridgedLog("⏸️  Pause callback removed")
    }

    public func setPlayCallback(callback: @escaping () -> Void) throws {
        self.playCallback = callback
        bridgedLog("▶️  Play callback registered")
    }

    public func removePlayCallback() throws {
        self.playCallback = nil
        bridgedLog("▶️  Play callback removed")
    }

    private func bridgedLog(_ message: String) {
        // Send to JavaScript - JS Logger will handle console + file logging
        if let callback = self.logCallback {
            DispatchQueue.main.async {
                callback(message)
            }
        }
    }

    public func writeDebugLog(message: String) throws {
        FileLogger.shared.log(message)
    }

    public func getAllDebugLogPaths() throws -> [String] {
        return FileLogger.shared.getAllLogPaths()
    }

    public func readDebugLog(path: String?) throws -> String {
        if let path = path {
            return FileLogger.shared.readLog(at: path) ?? ""
        } else {
            return FileLogger.shared.readCurrentLog() ?? ""
        }
    }

    public func clearDebugLogs() throws -> Promise<Void> {
        let promise = Promise<Void>()

        FileLogger.shared.clearAllLogs()
        promise.resolve(withResult: ())

        return promise
    }

    public func setDebugLogUserIdentifier(identifier: String) throws {
        FileLogger.shared.setUserIdentifier(identifier)
    }

    public func writeDebugLogSummary() throws {
        FileLogger.shared.writeSessionSummary()
    }

    // MARK: - Utility Methods

    public func mmss(secs: Double) throws -> String {
        let totalSeconds = Int(secs)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public func mmssss(milisecs: Double) throws -> String {
        let totalSeconds = Int(milisecs / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let milliseconds = Int(milisecs.truncatingRemainder(dividingBy: 1000)) / 10
        return String(format: "%02d:%02d:%02d", minutes, seconds, milliseconds)
    }

    // MARK: - Speech Recognition Methods
    public func transcribeAudioFile(filePath: String) throws -> Promise<String> {
        let promise = Promise<String>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            // Create recognizer
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
                promise.reject(withError: RuntimeError.error(withMessage: "Speech recognizer unavailable"))
                return
            }

            guard recognizer.isAvailable else {
                promise.reject(withError: RuntimeError.error(withMessage: "Speech recognizer not available"))
                return
            }
            
            // Ensure file:// prefix
            var urlPath = filePath
            if !urlPath.hasPrefix("file://") {
                urlPath = "file://" + urlPath
            }
            
            guard let url = URL(string: urlPath) else {
                self.bridgedLog("ℹ️ Invalid file path: \(filePath)")
                promise.resolve(withResult: "No Speech Detected")
                return
            }

            // Check file exists
            if !FileManager.default.fileExists(atPath: url.path) {
                self.bridgedLog("ℹ️ Audio file not found: \(url.path)")
                promise.resolve(withResult: "No Speech Detected")
                return
            }

            // Create recognition request
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false

            // Start recognition task
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    promise.resolve(withResult: "No Speech Detected")
                    return
                }

                if let result = result, result.isFinal {
                    let transcription = result.bestTranscription.formattedString
                    if transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        promise.resolve(withResult: "No Speech Detected")
                    } else {
                        self.bridgedLog("✅ Transcription complete: \(transcription.prefix(100))...")
                        promise.resolve(withResult: transcription)
                    }
                } else if let result = result {
                    let transcription = result.bestTranscription.formattedString
                    if transcription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        promise.resolve(withResult: "No Speech Detected")
                    } else {
                        promise.resolve(withResult: transcription)
                    }
                } else {
                    self.bridgedLog("ℹ️ No speech detected in audio")
                    promise.resolve(withResult: "No Speech Detected")
                }
            }
        }
        
        return promise
    }

    // MARK: - Crossfade Methods
    public func crossfadeTo(uri: String, duration: Double? = 3.0, targetVolume: Double? = 1.0) throws -> Promise<String> {
        let promise = Promise<String>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            do {
                guard !uri.isEmpty else {
                    promise.reject(withError: RuntimeError.error(withMessage: "URI is required for crossfade"))
                    return
                }

                let fadeDuration = duration ?? 3.0
                let finalVolume = Float(targetVolume ?? 1.0)

                // Ensure audio engine is initialized for crossfading
                try self.setupAudioEngine()

                // Log if engine is not running (diagnostic - no auto-restart)
                if let engine = self.audioEngine, !engine.isRunning {
                    self.bridgedLog("⚠️ ENGINE NOT RUNNING at crossfadeTo entry")
                }

                // Cancel seamless loop timer from previous track
                self.loopCrossfadeTimer?.cancel()
                self.loopCrossfadeTimer = nil
                self.isLoopCrossfadeActive = false

                // Pick next player node (3-node rotation: A→B→C→A)
                let newNode: AVAudioPlayerNode
                switch self.activePlayer {
                case .playerA:
                    newNode = self.audioPlayerNodeB!
                case .playerB:
                    newNode = self.audioPlayerNodeC!
                case .playerC:
                    newNode = self.audioPlayerNodeA!
                case .none:
                    newNode = self.audioPlayerNodeA!
                }

                // Load the audio file
                let url: URL
                if uri.hasPrefix("http") {
                    // Handle RN dev/bundled assets (http://localhost:8081/…)
                    let data = try Data(contentsOf: URL(string: uri)!)

                    // Extract file extension from original URL (before query string)
                    let originalURL = URL(string: uri)!
                    let pathWithoutQuery = originalURL.path  // Gets path before ? query params
                    let fileExtension = (pathWithoutQuery as NSString).pathExtension.isEmpty ? "m4a" : (pathWithoutQuery as NSString).pathExtension

                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("crossfade_temp_\(UUID().uuidString).\(fileExtension)")
                    try data.write(to: tempURL)
                    url = tempURL
                } else if uri.hasPrefix("file://") {
                    url = URL(string: uri)!
                } else {
                    url = URL(fileURLWithPath: uri)
                }

                guard FileManager.default.fileExists(atPath: url.path) else {
                    promise.reject(withError: RuntimeError.error(withMessage: "Audio file does not exist: \(url.path)"))
                    return
                }

                let audioFile = try AVAudioFile(forReading: url)
                let totalDuration = Double(audioFile.length) / audioFile.fileFormat.sampleRate

                // Prepare new node
                newNode.stop()
                newNode.volume = 0.0

                // Reset position tracking for new track (BEFORE updating currentAudioFile)
                // This prevents getCurrentPosition() from using mismatched file/node/offset during crossfade
                self.startingFrameOffset = 0
                self.lastValidPosition = 0.0

                // Store audio file reference early to ensure it's retained for looping
                self.currentAudioFile = audioFile

                // Schedule file for playback (double-buffered for seamless looping)
                if self.shouldLoopPlayback {
                    newNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
                    // Pre-schedule next iteration to prevent gaps (maintains buffer queue)
                    newNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
                } else {
                    newNode.scheduleFile(audioFile, at: nil) { [weak self] in
                        self?.handlePlaybackCompletion()
                    }
                }

                newNode.play()
                let currentNodeName = self.getNodeName(for: self.currentPlayerNode)
                let newNodeName = self.getNodeName(for: newNode)
                self.bridgedLog("🎵 CROSSFADE: Node \(currentNodeName) → Node \(newNodeName): \(url.lastPathComponent)")

                // DON'T schedule loop timer here - defer until after crossfade completes
                // This prevents race conditions between main and loop crossfades

                // Start fading
                if let currentNode = self.currentPlayerNode {
                    self.fadeVolume(node: currentNode, from: currentNode.volume, to: 0.0, duration: fadeDuration) {
                        // Stop old node when fade out completes
                        currentNode.stop()
                        currentNode.volume = 0.0  // Ensure volume stays at 0
                    }
                }

                // BUGFIX: Update playbackVolume to match target for subsequent loop iterations
                self.playbackVolume = finalVolume
                self.fadeVolume(node: newNode, from: 0.0, to: finalVolume, duration: fadeDuration) {
                    // Swap references after new node fades in
                    self.currentPlayerNode = newNode
                    self.activePlayer = self.getPlayerEnum(for: newNode)
                    self.currentLoopingFileURI = uri

                    // NOW schedule loop timer AFTER crossfade completes (prevents race condition)
                    if self.shouldLoopPlayback {
                        let crossfadeStartTime = max(0, totalDuration - self.loopCrossfadeDuration)
                        self.scheduleLoopCrossfade(after: crossfadeStartTime, audioFile: audioFile, url: url)
                        self.bridgedLog("🎵 MAIN TRACK TRANSITION: Scheduled first loop in \(String(format: "%.1f", crossfadeStartTime))s")
                    }
                    self.bridgedLog("🎵 MAIN TRACK TRANSITION: Complete ✓")
                    self.bridgedLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                }

                // Resolve immediately (crossfade started)
                self.bridgedLog("🔀 CROSSFADE PROMISE RESOLVED: Crossfade initiated successfully")
                promise.resolve(withResult: uri)

            } catch {
                promise.reject(withError: RuntimeError.error(withMessage: error.localizedDescription))
            }
        }

        return promise
    }

    // MARK: - Volume Fade Methods

    /// Smoothly fade the main player's volume to a target value using native equal-power curve.
    /// This eliminates the jitter and clicking that occurs with JS-based volume stepping.
    public func fadeVolumeTo(targetVolume: Double, duration: Double) throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            guard let playerNode = self.currentPlayerNode else {
                // No player node - resolve immediately (nothing to fade)
                self.bridgedLog("⚠️ fadeVolumeTo: No current player node, resolving immediately")
                promise.resolve(withResult: ())
                return
            }

            let currentVolume = playerNode.volume
            let target = Float(max(0.0, min(1.0, targetVolume)))  // Clamp to 0-1

            self.bridgedLog("🔊 fadeVolumeTo: \(currentVolume) → \(target) over \(duration)s")

            self.fadeVolume(node: playerNode, from: currentVolume, to: target, duration: duration) {
                // BUGFIX: Update playbackVolume to match target for seamless loop iterations
                self.playbackVolume = target
                self.bridgedLog("🔊 fadeVolumeTo: Complete ✓ (playbackVolume updated to \(target))")
                promise.resolve(withResult: ())
            }
        }

        return promise
    }

    // MARK: - Ambient Loop Methods
    public func startAmbientLoop(uri: String, volume: Double, fadeDuration: Double?) throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            do {
                // Initialize audio engine if needed
                try self.setupAudioEngine()

                // Log if engine is not running (diagnostic - no auto-restart)
                if let engine = self.audioEngine, !engine.isRunning {
                    self.bridgedLog("⚠️ ENGINE NOT RUNNING at startAmbientLoop entry")
                }

                guard let playerD = self.audioPlayerNodeD else {
                    promise.reject(withError: RuntimeError.error(withMessage: "Ambient player not initialized"))
                    return
                }

                // Load audio file
                let url: URL
                if uri.hasPrefix("http") {
                    let data = try Data(contentsOf: URL(string: uri)!)
                    let pathWithoutQuery = URL(string: uri)!.path
                    let fileExtension = (pathWithoutQuery as NSString).pathExtension.isEmpty ? "wav" : (pathWithoutQuery as NSString).pathExtension
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ambient_\(UUID().uuidString).\(fileExtension)")
                    try data.write(to: tempURL)
                    url = tempURL
                } else if uri.hasPrefix("file://") {
                    url = URL(string: uri)!
                } else {
                    url = URL(fileURLWithPath: uri)
                }

                let audioFile = try AVAudioFile(forReading: url)
                self.currentAmbientFile = audioFile

                // Stop if already playing
                if self.isAmbientLoopPlaying {
                    playerD.stop()
                    playerD.reset()
                }

                // Determine if we should fade in
                let shouldFadeIn = fadeDuration != nil && fadeDuration! > 0

                // Set initial volume (0 if fading in, target if not)
                playerD.volume = shouldFadeIn ? 0.0 : Float(volume)

                // Schedule for looping (pre-schedule 3 iterations)
                playerD.scheduleFile(audioFile, at: nil, completionHandler: nil)
                playerD.scheduleFile(audioFile, at: nil, completionHandler: nil)
                playerD.scheduleFile(audioFile, at: nil) { [weak self] in
                    self?.scheduleMoreAmbientLoops(audioFile: audioFile, playerNode: playerD)
                }

                // Play
                playerD.play()
                self.isAmbientLoopPlaying = true

                // Fade in if requested
                if shouldFadeIn {
                    self.bridgedLog("🎵 AMBIENT on Node D: \(url.lastPathComponent) - fading in to \(Int(volume * 100))% over \(fadeDuration!)s")
                    self.fadeVolume(node: playerD, from: 0.0, to: Float(volume), duration: fadeDuration!) {
                        // Fade complete
                    }
                } else {
                    self.bridgedLog("🎵 AMBIENT on Node D: \(url.lastPathComponent) at \(Int(volume * 100))% volume (instant)")
                }

                promise.resolve(withResult: ())

            } catch {
                self.bridgedLog("❌ Failed to start ambient loop: \(error.localizedDescription)")
                promise.reject(withError: RuntimeError.error(withMessage: error.localizedDescription))
            }
        }

        return promise
    }

    public func stopAmbientLoop(fadeDuration: Double?) throws -> Promise<Void> {
        let promise = Promise<Void>()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                promise.reject(withError: RuntimeError.error(withMessage: "Self is nil"))
                return
            }

            guard let playerD = self.audioPlayerNodeD else {
                promise.resolve(withResult: ())
                return
            }

            if !self.isAmbientLoopPlaying {
                promise.resolve(withResult: ())
                return
            }

            let duration = fadeDuration ?? 5.0
            self.bridgedLog("🔇 STOPPING Ambient (Node D) - fade: \(duration)s")

            if duration > 0 {
                // Fade out
                self.fadeVolume(node: playerD, from: playerD.volume, to: 0.0, duration: duration) {
                    playerD.stop()
                    playerD.reset()
                    self.isAmbientLoopPlaying = false
                    self.currentAmbientFile = nil
                    self.bridgedLog("🔇 STOPPED Ambient (Node D) - faded")
                    promise.resolve(withResult: ())
                }
            } else {
                // Immediate stop
                playerD.stop()
                playerD.reset()
                self.isAmbientLoopPlaying = false
                self.currentAmbientFile = nil
                self.bridgedLog("🔇 STOPPED Ambient (Node D) - immediate")
                promise.resolve(withResult: ())
            }
        }

        return promise
    }

    // MARK: - Volume Fade Helper
    private func fadeVolume(
        node: AVAudioPlayerNode,
        from startVolume: Float,
        to targetVolume: Float,
        duration: Double,
        completion: (() -> Void)? = nil
    ) {
        let steps = 60
        let stepDuration = duration / Double(steps)

        var currentStep = 0
        node.volume = startVolume

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: stepDuration)

        timer.setEventHandler {
            guard node.engine != nil else {
                timer.cancel()
                return
            }

            // Calculate progress (0.0 to 1.0)
            let progress = Float(currentStep) / Float(steps)

            // Equal-power crossfade curve
            let newVolume: Float
            if startVolume > targetVolume {
                // Fading out: sqrt(1 - progress) * startVolume
                newVolume = sqrt(1.0 - progress) * startVolume
            } else {
                // Fading in: sqrt(progress) * targetVolume
                newVolume = sqrt(progress) * targetVolume
            }

            DispatchQueue.main.async {
                node.volume = newVolume
            }

            currentStep += 1
            if currentStep > steps {
                timer.cancel()
                DispatchQueue.main.async {
                    node.volume = targetVolume
                    completion?()
                }
            }
        }

        timer.resume()
    }

    // MARK: - Private Methods



    // MARK: - Timer Management

    // Removed startRecordTimer - only needed for AVAudioRecorder metering

    // Removed stopRecordTimer - only needed for AVAudioRecorder

    /// Get actual playable duration in seconds for the current audio file
    /// For M4A files, uses AVAsset (respects iTunSMPB, excludes padding)
    /// For other formats, uses AVAudioFile
    private func getActualDurationSeconds(audioFile: AVAudioFile) -> Double {
        let fileURL = audioFile.url
        if fileURL.pathExtension.lowercased() == "m4a" {
            let asset = AVAsset(url: fileURL)
            return CMTimeGetSeconds(asset.duration)
        } else {
            return Double(audioFile.length) / audioFile.fileFormat.sampleRate
        }
    }

    private func startPlayTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }


            self.didEmitPlaybackEnd = false

            self.playTimer = Timer.scheduledTimer(withTimeInterval: self.subscriptionDuration, repeats: true) { [weak self] timer in
                guard let self = self else { return }

                // Check if we have a player node and audio file
                guard let playerNode = self.currentPlayerNode,
                      let audioFile = self.currentAudioFile else {
                    self.stopPlayTimer()
                    return
                }

                // Continue running timer if EITHER listener is registered
                // This allows playback end detection even without progress updates
                guard self.playBackListener != nil || self.playbackEndListener != nil else {
                    return
                }

                // Calculate actual playable duration (uses AVAsset for M4A to exclude padding)
                let durationSeconds = self.getActualDurationSeconds(audioFile: audioFile)
                let durationMs = durationSeconds * 1000

                // Get current playback position from audio hardware
                var currentTimeSeconds: Double = 0
                if let nodeTime = playerNode.lastRenderTime,
                   let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                    currentTimeSeconds = Double(playerTime.sampleTime) / audioFile.fileFormat.sampleRate
                }

                // Check if we've reached the end of the audio file
                // Use a small tolerance (0.05s) to account for timing precision
                if playerNode.isPlaying && currentTimeSeconds >= (durationSeconds - 0.05) {
                    self.bridgedLog("🎯 Timer detected playback reached end at \(String(format: "%.2f", currentTimeSeconds))s / \(String(format: "%.2f", durationSeconds))s")
                    playerNode.stop()
                    // Next timer tick (60ms) will detect !isPlaying and fire completion
                }

                // Check if playback has finished (ALWAYS check, even if no playBackListener)
                if !playerNode.isPlaying {
                    // GUARD: Prevent infinite logging if we've already handled playback end
                    guard !self.didEmitPlaybackEnd else {
                        return
                    }

                    // Get position when timer detected stop
                    var stopPos: Double = 0
                    if let nodeTime = playerNode.lastRenderTime,
                       let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                        stopPos = Double(playerTime.sampleTime) / audioFile.fileFormat.sampleRate
                    }

                    // Emit playback end events (will emit to both listeners if registered)
                    self.emitPlaybackEndEvents(durationMs: durationMs, includePlaybackUpdate: true)
                    self.stopPlayTimer()
                    return
                }

                // Emit progress updates ONLY if playBackListener is registered
                if let listener = self.playBackListener {
                    // Get the player node's current time
                    var currentTimeMs: Double = 0
                    if let nodeTime = playerNode.lastRenderTime,
                       let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
                        // Use audio file's sample rate, not hardware output rate
                        let sampleRate = audioFile.fileFormat.sampleRate
                        currentTimeMs = Double(playerTime.sampleTime) / sampleRate * 1000
                    }

                    let playBack = PlayBackType(
                        isMuted: false,
                        duration: durationMs,
                        currentPosition: currentTimeMs
                    )

                    listener(playBack)

                    // Update Now Playing position (convert ms to seconds)
                    self.updateNowPlayingInfo(
                        title: self.currentTrackTitle,
                        artist: nil,
                        duration: durationSeconds,
                        currentTime: currentTimeMs / 1000.0
                    )
                }
            }

        }
    }

    private func stopPlayTimer() {
        stopTimer(for: \.playTimer)
    }

    private func stopTimer(for keyPath: ReferenceWritableKeyPath<HybridSound, Timer?>) {
        if Thread.isMainThread {
            self[keyPath: keyPath]?.invalidate()
            self[keyPath: keyPath] = nil
        } else {
            DispatchQueue.main.sync {
                self[keyPath: keyPath]?.invalidate()
                self[keyPath: keyPath] = nil
            }
        }
    }

    private func emitPlaybackEndEvents(durationMs: Double, includePlaybackUpdate: Bool) {
        guard !self.didEmitPlaybackEnd else {
            return
        }
        self.didEmitPlaybackEnd = true

        if includePlaybackUpdate, let listener = self.playBackListener {
            let finalPlayBack = PlayBackType(
                isMuted: false,
                duration: durationMs,
                currentPosition: durationMs
            )
            listener(finalPlayBack)
        }

        if let endListener = self.playbackEndListener {
            let endEvent = PlaybackEndType(
                duration: durationMs,
                currentPosition: durationMs
            )
            endListener(endEvent)
        }
    }

    // MARK: - AVAudioPlayerDelegate via proxy
    deinit {
        playTimer?.invalidate()
        crossfadeTimer?.invalidate()
        loopCrossfadeTimer?.cancel()

        // Cleanup unified audio engine if needed
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            stopTapMonitor()
            // Don't stop the engine here as it might be used by other instances
        }
        // No callback to clear - using event emitting
    }

    private class AudioPlayerDelegateProxy: NSObject, AVAudioPlayerDelegate {
        weak var owner: HybridSound?
        init(owner: HybridSound) { self.owner = owner }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            guard let owner = owner else { return }
            let finalDurationMs = player.duration * 1000
            owner.emitPlaybackEndEvents(durationMs: finalDurationMs, includePlaybackUpdate: true)
            owner.stopPlayTimer()
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            NSLog("AVAudioPlayer decode error: \(String(describing: error))")
        }
    }

    private var playerDelegateProxy: AudioPlayerDelegateProxy?
    private func ensurePlayerDelegate() {
        if playerDelegateProxy == nil { playerDelegateProxy = AudioPlayerDelegateProxy(owner: self) }
        else { playerDelegateProxy?.owner = self }
    }
}

// MARK: - Audio Level Detection (Replacing SNResultsObserving)
extension HybridSound {
    // COMMENTED OUT - RMS detection replaced with VAD (kept for reference/fallback)
    // Simple audio level detection using RMS-based threshold
    private func isAudioLoudEnough(_ buffer: AVAudioPCMBuffer) -> Bool {
        // VAD is now the primary detection method - RMS used only as fallback
        // when VAD initialization fails
        guard let channelData = buffer.floatChannelData else { return false }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return false }

        // Calculate RMS (Root Mean Square) for audio level
        var sum: Float = 0.0
        let samples = channelData.pointee

        for i in 0..<frameLength {
            let sample = samples[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        let db = 20 * log10(max(rms, 0.000001))

        // Fixed threshold -25dB (since audioLevelThreshold property is commented out)
        return db > -25.0  // HARDCODED fallback threshold
    }

    // SNResultsObserving stub methods (keeping for protocol conformance if needed)
    func request(_ request: SNRequest, didProduce result: SNResult) {
        // No longer used - using audio level detection instead
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        // No longer used
    }

    func requestDidComplete(_ request: SNRequest) {
        // No longer used
    }
}
