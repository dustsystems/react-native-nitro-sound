import Foundation
import AVFoundation

/// The recorder's audio pipeline for one tap install: the ring buffer the
/// real-time tap writes, the hardware input format, the 16 kHz target format
/// and the converter between them (DUS-3299).
///
/// Immutable on purpose. `Sound` replaces the whole object on every recorder
/// tap install instead of mutating fields, so a reader that took a snapshot
/// keeps a consistent set, and the converter it is using stays alive until it
/// lets go. Nothing here may be swapped in place.
final class TapPipeline {
    /// Written only by the tap block that captured it (single producer).
    /// Read only on the consumer side: the worker on processingQueue, or a
    /// stale-chunk discard while no worker drains it (single consumer).
    let ring: SPSCRingBuffer
    /// Hardware format the tap delivers (typically 48 kHz).
    let inputFormat: AVAudioFormat
    /// 16 kHz mono float, used for segment files and speech recognition.
    let targetFormat: AVAudioFormat
    let converter: AVAudioConverter

    /// Builds a fresh pipeline for `inputFormat`. Returns nil when the target
    /// format or the converter cannot be created. Allocates, so never call it
    /// on the real-time thread.
    init?(inputFormat: AVAudioFormat) {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: target) else {
            return nil
        }
        // samplesPerChunk must be >= the actual tap buffer size
        // (iOS gives ~4800 frames at 48 kHz).
        self.ring = SPSCRingBuffer(capacity: 64, samplesPerChunk: 8192)
        self.inputFormat = inputFormat
        self.targetFormat = target
        self.converter = converter
    }

    /// Consumer-side discard of everything queued so far, so a new sink starts
    /// from "now". Only safe while no other consumer reads this ring.
    func discardQueuedChunks() {
        while ring.read() != nil {}
    }
}
