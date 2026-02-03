import Foundation
import AVFoundation

/// Lock-free Single-Producer Single-Consumer ring buffer for raw 48kHz audio.
///
/// Producer: render thread (tap callback) - calls write()
/// Consumer: worker queue - calls read()
///
/// Design: Pre-allocated contiguous memory with atomic indices using C11 atomics.
/// Capacity of 64 slots × 8192 samples = ~10 seconds buffer at 48kHz.
/// samplesPerChunk must be >= actual tap buffer size (iOS gives ~4800 frames).
///
/// Uses C11 atomics (SPSCAtomic.c) for proper memory ordering without SPM dependencies.
final class SPSCRingBuffer {
    private let capacity: Int
    private let samplesPerChunk: Int

    // Pre-allocated contiguous memory
    private let sampleStorage: UnsafeMutablePointer<Float>
    private let frameLengths: UnsafeMutablePointer<Int32>

    // Atomic indices using C11 atomics (opaque pointers)
    // writeIndex: Only tap (producer) writes, worker reads
    // readIndex: Only worker (consumer) writes, tap reads
    private let writeIndex: OpaquePointer
    private let readIndex: OpaquePointer
    private let overflowCount: OpaquePointer

    /// Initialize the ring buffer
    /// - Parameters:
    ///   - capacity: Number of slots (power of 2 recommended). Default 64.
    ///   - samplesPerChunk: Samples per buffer chunk (matches tap buffer size). Default 1024.
    init(capacity: Int = 64, samplesPerChunk: Int = 1024) {
        self.capacity = capacity
        self.samplesPerChunk = samplesPerChunk

        // Allocate contiguous memory for all slots
        self.sampleStorage = .allocate(capacity: capacity * samplesPerChunk)
        self.sampleStorage.initialize(repeating: 0, count: capacity * samplesPerChunk)

        self.frameLengths = .allocate(capacity: capacity)
        self.frameLengths.initialize(repeating: 0, count: capacity)

        // Create atomic indices (heap allocated, once at init - not in render thread)
        guard let w = spsc_atomic_i64_create(0),
              let r = spsc_atomic_i64_create(0),
              let o = spsc_atomic_i64_create(0) else {
            fatalError("SPSCRingBuffer: Failed to allocate atomic indices")
        }
        self.writeIndex = w
        self.readIndex = r
        self.overflowCount = o
    }

    deinit {
        sampleStorage.deallocate()
        frameLengths.deallocate()
        spsc_atomic_i64_destroy(writeIndex)
        spsc_atomic_i64_destroy(readIndex)
        spsc_atomic_i64_destroy(overflowCount)
    }

    // MARK: - Producer (Render Thread)

    /// Write a buffer to the ring. Called from render thread - must not block or allocate.
    /// - Parameter buffer: The audio buffer to copy
    /// - Returns: true if successful, false if ring is full (overflow)
    @inline(__always)
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        let writeIdx = Int(spsc_load_relaxed_i64(writeIndex))
        let readIdx = Int(spsc_load_acquire_i64(readIndex))

        // Check if full (producer ahead by capacity means buffer is full)
        guard (writeIdx - readIdx) < capacity else {
            _ = spsc_fetch_add_relaxed_i64(overflowCount, 1)
            return false
        }

        let slot = writeIdx % capacity
        let dest = sampleStorage.advanced(by: slot * samplesPerChunk)

        // Copy audio data
        if let src = buffer.floatChannelData?[0] {
            let frameCount = min(Int(buffer.frameLength), samplesPerChunk)
            memcpy(dest, src, frameCount * MemoryLayout<Float>.size)
            frameLengths[slot] = Int32(frameCount)
        } else {
            frameLengths[slot] = 0
        }

        // Release: ensure data is written before index update is visible
        spsc_store_release_i64(writeIndex, Int64(writeIdx + 1))
        return true
    }

    // MARK: - Consumer (Worker Queue)

    /// Read a chunk from the ring. Called from worker queue.
    /// - Returns: Tuple of (pointer to samples, frame count) or nil if empty
    func read() -> (UnsafePointer<Float>, Int)? {
        let readIdx = Int(spsc_load_relaxed_i64(readIndex))
        let writeIdx = Int(spsc_load_acquire_i64(writeIndex))

        // Check if empty
        guard readIdx < writeIdx else { return nil }

        let slot = readIdx % capacity
        let src = UnsafePointer(sampleStorage.advanced(by: slot * samplesPerChunk))
        let frameLength = Int(frameLengths[slot])

        // Release: ensure we've read data before updating index
        spsc_store_release_i64(readIndex, Int64(readIdx + 1))

        return (src, frameLength)
    }

    /// Check how many chunks are available to read
    var availableChunks: Int {
        let writeIdx = Int(spsc_load_acquire_i64(writeIndex))
        let readIdx = Int(spsc_load_relaxed_i64(readIndex))
        return writeIdx - readIdx
    }

    /// Check if buffer is empty
    var isEmpty: Bool {
        return availableChunks == 0
    }

    /// Get overflow count (number of dropped buffers due to full ring)
    var overflows: Int {
        return Int(spsc_load_relaxed_i64(overflowCount))
    }

    // MARK: - Lifecycle

    /// Reset indices. Call when restarting after audio interruption.
    /// WARNING: Only call when both producer and consumer are stopped.
    func reset() {
        spsc_store_relaxed_i64(writeIndex, 0)
        spsc_store_relaxed_i64(readIndex, 0)
        spsc_store_relaxed_i64(overflowCount, 0)
    }
}
