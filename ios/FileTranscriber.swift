import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Transcribe a recorded audio file on Apple's SpeechAnalyzer/SpeechTranscriber
/// (iOS 26+), the same engine LiveTranscriber uses for journal dictation.
///
/// Overnight and morning captures are files, so they used to go through the
/// older SFSpeech file recognizer even on phones where journal dictation runs
/// on SpeechAnalyzer. The two engines punctuate very differently: the same
/// audio came back with full sentences from the journal and largely
/// unpunctuated from a night recording (DUS-3011). This gives the file path
/// the journal's engine.
///
/// - Reads the file only: no AVAudioEngine, no microphone, and it never
///   touches the shared AVAudioSession, so it cannot disturb the overnight
///   engine or a live dictation session.
/// - Same transcriber settings as LiveTranscriber minus the volatile/fast
///   reporting options, which only matter for live partials: a file needs
///   only the finalized text.
/// - Fully on-device; the caller checks the locale model is installed
///   (LiveTranscriber.ensureAssets) before calling.
@available(iOS 26.0, macOS 26.0, *)
enum FileTranscriber {

    /// The file's finalized text, segments joined by a single space.
    /// Resolves "" when the file has no words. Throws when the model is not
    /// installed, the file cannot be opened, or the analyzer fails.
    static func transcribe(filePath: String, localeIdentifier: String) async throws -> String {
        let locale = Locale(identifier: localeIdentifier)
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw RuntimeErrorShim.message("Speech model for \(localeIdentifier) is not installed")
        }

        let url: URL
        if filePath.hasPrefix("file://"), let parsed = URL(string: filePath) {
            url = parsed
        } else {
            url = URL(fileURLWithPath: filePath)
        }
        let audioFile = try AVAudioFile(forReading: url)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect results BEFORE feeding audio so nothing is dropped.
        let collector = Task { () throws -> [String] in
            var segments: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { segments.append(text) }
            }
            return segments
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                // No audio in the file: end the session so the results stream closes.
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        return try await collector.value.joined(separator: " ")
    }
}
