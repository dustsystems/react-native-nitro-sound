import type { HybridObject } from 'react-native-nitro-modules';

// Enums
export enum AudioSourceAndroidType {
  DEFAULT = 0,
  MIC = 1,
  VOICE_UPLINK = 2,
  VOICE_DOWNLINK = 3,
  VOICE_CALL = 4,
  CAMCORDER = 5,
  VOICE_RECOGNITION = 6,
  VOICE_COMMUNICATION = 7,
  REMOTE_SUBMIX = 8,
  UNPROCESSED = 9,
  RADIO_TUNER = 1998,
  HOTWORD = 1999,
}

export enum OutputFormatAndroidType {
  DEFAULT = 0,
  THREE_GPP = 1,
  MPEG_4 = 2,
  AMR_NB = 3,
  AMR_WB = 4,
  AAC_ADIF = 5,
  AAC_ADTS = 6,
  OUTPUT_FORMAT_RTP_AVP = 7,
  MPEG_2_TS = 8,
  WEBM = 9,
}

export enum AudioEncoderAndroidType {
  DEFAULT = 0,
  AMR_NB = 1,
  AMR_WB = 2,
  AAC = 3,
  HE_AAC = 4,
  AAC_ELD = 5,
  VORBIS = 6,
}


export interface PlayBackType {
  isMuted?: boolean;
  duration: number;
  currentPosition: number;
}

export interface PlaybackEndType {
  duration: number;
  currentPosition: number;
}

export type PlayBackListener = (playbackMeta: PlayBackType) => void;
export type PlaybackEndListener = (playbackEndMeta: PlaybackEndType) => void;

export interface Sound
  extends HybridObject<{ ios: 'swift'; android: 'kotlin' }> {
  // Recording methods (unified AVAudioEngine with speech detection)
  startRecorder(): Promise<void>;
  stopRecorder(): Promise<void>;
  /**
   * End the engine session and completely destroy all audio resources.
   * This performs a full teardown:
   * - Ends any active recording segments
   * - Stops all playback
   * - Stops the audio engine
   * - Deactivates the audio session (removes microphone indicator)
   * - Destroys the engine instance (forces clean re-initialization)
   *
   * Call this when stopping a sleep session to ensure the microphone
   * indicator disappears and all audio resources are released.
   */
  endEngineSession(): Promise<void>;

  // Simple fixed-duration recording API

  /**
   * Begin recording with a maximum duration.
   * Recording automatically stops when the duration is reached.
   * Can be stopped early with endRecording().
   *
   * @param maxDurationSeconds Maximum recording duration (e.g., 90 seconds)
   */
  beginRecording(maxDurationSeconds: number): Promise<void>;

  /**
   * End recording early (before max duration is reached).
   * If no recording is active, this is a no-op.
   */
  endRecording(): Promise<void>;

  /**
   * Check if recording is currently active.
   * @returns true if actively recording, false otherwise
   */
  isSegmentRecording(): Promise<boolean>;

  // Playback methods
  startPlayer(
    uri?: string,
    httpHeaders?: Record<string, string>
  ): Promise<string>;
  stopPlayer(): Promise<string>;
  pausePlayer(): Promise<string>;
  resumePlayer(): Promise<string>;
  seekToPlayer(time: number): Promise<string>;
  setVolume(volume: number): Promise<string>;

  // Now Playing (lock screen controls)
  /**
   * Update Now Playing info on lock screen
   * @param title Track title to display
   * @param artist Artist name (optional)
   * @param duration Total duration in seconds
   * @param currentTime Current playback position in seconds
   */
  updateNowPlaying(
    title: string,
    artist: string,
    duration: number,
    currentTime: number
  ): Promise<void>;

  /**
   * Clear Now Playing info from lock screen
   */
  clearNowPlaying(): Promise<void>;

  /**
   * Set artwork for Now Playing lock screen display
   * @param imagePath Path to the image file (local file path)
   */
  setNowPlayingArtwork(imagePath: string): Promise<void>;

  // Position/duration query methods (milliseconds)
  getCurrentPosition(): Promise<number>;
  getDuration(): Promise<number>;

  // Loop control methods
  setLoopEnabled(enabled: boolean): Promise<string>;

  // Crossfade methods
  crossfadeTo(uri: string, duration?: number, targetVolume?: number): Promise<string>;

  // Volume fade (smooth native fade using equal-power curve)
  fadeVolumeTo(targetVolume: number, duration: number): Promise<void>;

  // Ambient loop methods
  startAmbientLoop(uri: string, volume: number, fadeDuration?: number): Promise<void>;
  stopAmbientLoop(fadeDuration?: number): Promise<void>;

  // Listeners
  addPlayBackListener(callback: (playbackMeta: PlayBackType) => void): void;
  removePlayBackListener(): void;
  addPlaybackEndListener(
    callback: (playbackEndMeta: PlaybackEndType) => void
  ): void;
  removePlaybackEndListener(): void;

  // Logging methods
  setLogCallback(callback: (message: string) => void): void;

  // Speech segment callback (called when a new segment file is written)
  setSegmentCallback(callback: (filename: string, filePath: string, isManual: boolean, duration: number) => void): void;

  // Lock screen track navigation callbacks
  setNextTrackCallback(callback: () => void): void;
  removeNextTrackCallback(): void;
  setPreviousTrackCallback(callback: () => void): void;
  removePreviousTrackCallback(): void;

  // Lock screen pause/play callbacks (to sync UI with lock screen controls)
  setPauseCallback(callback: () => void): void;
  removePauseCallback(): void;
  setPlayCallback(callback: () => void): void;
  removePlayCallback(): void;

  /**
   * Completely tear down remote command center - removes all targets and clears Now Playing.
   * Widget will disappear as if it was never configured.
   * Call this when transitioning to night phase to hide lock screen controls.
   */
  teardownRemoteCommands(): Promise<void>;

  // Debug logging methods
  writeDebugLog(message: string): void;
  getAllDebugLogPaths(): string[];
  readDebugLog(path?: string): string;
  clearDebugLogs(): Promise<void>;
  setDebugLogUserIdentifier(identifier: string): void;

  /**
   * Write session summary to the debug log file.
   * Includes error/warning counts and session duration.
   * Call this before generating bug reports or when app backgrounds.
   */
  writeDebugLogSummary(): void;

  // Utility methods
  mmss(secs: number): string;
  mmssss(milisecs: number): string;

  /**
   * Transcribe an audio file to text using iOS Speech Recognition
   * @param filePath Path to audio file (with or without file:// prefix)
   * @returns Promise resolving to transcribed text
   * @throws Error if file not found or speech recognition unavailable
   */
  transcribeAudioFile(filePath: string): Promise<string>;

  /**
   * Concatenate audio files end-to-end into a single M4A (AAC) file using
   * AVMutableComposition. Inputs may be any AVFoundation-readable audio
   * format; they are laid out in array order and exported as one track.
   *
   * Used by the dream journal "continue recording" flow to stitch a second
   * recording slice onto the first instead of discarding it.
   *
   * @param inputPaths Ordered audio file paths (with or without file:// prefix)
   * @param outputPath Destination .m4a path (with or without file:// prefix).
   *                   An existing file at this path is overwritten.
   * @returns Promise resolving to the combined duration in MILLISECONDS
   * @throws Error if fewer than 2 inputs, an input is missing/unreadable,
   *         or the export fails (output is cleaned up on failure)
   */
  concatAudioFiles(inputPaths: string[], outputPath: string): Promise<number>;

  // Live voice-command recognition (alarm "snooze"/"wake"/"record")
  //
  // Runs SFSpeechRecognizer INSIDE this engine, fed by the existing input tap
  // (via the SPSC ring buffer + worker), instead of spinning up a second
  // AVAudioEngine. This avoids the dual-engine microphone conflict that breaks
  // recognition while the alarm audio is playing. See
  // docs/voice-command-dual-engine-fix-implementation-plan.md.

  /**
   * Begin live recognition of short voice commands using the already-running
   * engine + input tap. No-op-rejects if no engine/tap is active (i.e. before
   * Start Journey) or while a fixed-duration recording is in progress.
   */
  startCommandRecognition(): Promise<void>;

  /**
   * Stop live command recognition. Leaves the engine, tap, and SPSC buffer
   * intact (they are owned by the recording/session lifecycle).
   */
  stopCommandRecognition(): Promise<void>;

  /**
   * Register a callback invoked on partial + final recognition results.
   * @param callback (text: best transcription so far, isFinal: whether this is a final result)
   */
  setCommandResultCallback(callback: (text: string, isFinal: boolean) => void): void;
  removeCommandResultCallback(): void;

  // Live journal dictation via SpeechAnalyzer/SpeechTranscriber (iOS 26+).
  //
  // Unlike command recognition above, this does NOT run inside the overnight
  // engine — LiveTranscriber (ios/LiveTranscriber.swift) owns its own small
  // AVAudioEngine and joins the shared AVAudioSession as a second client
  // beside the expo-audio recorder, exactly like expo-speech-recognition's
  // dictation engine does today. It never re-modes or deactivates the session.
  //
  // The model is a per-locale system asset managed by iOS (AssetInventory);
  // recognition is fully on-device with no duration cap — the long-form
  // replacement for the SFSpeech path that degrades past ~1 minute.

  /**
   * Whether SpeechAnalyzer live transcription can run on this device
   * (iOS 26+). Does NOT check whether the locale model is installed —
   * call ensureLiveTranscriptionAssets() for that.
   */
  liveTranscriptionSupported(): boolean;

  /**
   * Check/provision the on-device model for the given locale.
   * @returns 'ready' (model installed), 'downloading' (install kicked off in
   *          the background — fall back to the legacy engine this session),
   *          'download-failed' (provisioning request failed outright — see
   *          os_log for the cause), or 'unsupported' (OS < 26 or locale not
   *          supported).
   */
  ensureLiveTranscriptionAssets(locale: string): Promise<string>;

  /**
   * Start live mic transcription. Volatile (in-flight) results arrive with
   * isFinal=false; finalized segments with isFinal=true. Rejects below iOS 26,
   * when the model is missing, or if a session is already running.
   */
  startLiveTranscription(locale: string): Promise<void>;

  /**
   * Stop live transcription. Flushes the final result (delivered via the
   * result callback with isFinal=true) before resolving. Safe to call when
   * not running. Leaves the shared audio session untouched.
   */
  stopLiveTranscription(): Promise<void>;

  /** Result callback: (segment text, isFinal). Set before startLiveTranscription. */
  setLiveTranscriptionResultCallback(callback: (text: string, isFinal: boolean) => void): void;
  removeLiveTranscriptionResultCallback(): void;

  /** Error callback: (code, message). Codes: 'unsupported' | 'assets-missing' | 'audio-engine' | 'analyzer'. */
  setLiveTranscriptionErrorCallback(callback: (code: string, message: string) => void): void;
  removeLiveTranscriptionErrorCallback(): void;
}
