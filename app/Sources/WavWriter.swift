import Foundation
import Darwin

// =====================================================================================
// WavWriter: streaming 16-bit PCM little-endian mono WAV file writer.
//
// Design (SPEC 4.2):
//  * The 44-byte canonical header is written at open with sizes = 0 and then refreshed with pwrite()
//    every 4 s (only when new data arrived; 100 ms timer leeway) and once more on close(). If the process
//    dies, the file is therefore "nearly valid": the header under-reports the length by at most ~4.1 s,
//    inside the SPEC 4.2 bound of 5 s.
//    The Python side (and `WavFileInfo.read` below) recover the true length from the file size,
//    because the data chunk is always the last chunk of the file.
//  * The descriptor is opened with O_CLOEXEC: the app spawns Process children (the Python pipeline of the
//    previous meeting, `say`, claude...) and they must never inherit a live WAV descriptor.
//  * Callers (audio threads!) never touch the disk: every append hands the samples to a private
//    serial queue. Pending memory is capped (see maxPendingBytes) so a stalled disk cannot grow RAM
//    without bound; overflowing buffers are dropped and reported through `onError`.
//  * `framesWritten` counts frames *accepted* (queued + already on disk). Recorder uses it as the
//    file timeline position when deciding whether to insert silence for a gap.
// =====================================================================================

final class WavWriter {
    let url: URL
    let sampleRate: Int
    /// Called at most once per distinct problem (disk full, queue overflow...). Set before the first append.
    var onError: ((String) -> Void)?

    static let headerSize = 44
    private static let maxPendingBytes = 64 * 1024 * 1024        // ~11 min of 48 kHz mono backlog
    /// SPEC 4.2: header at most 5 s stale. Staleness is bounded by interval + leeway (4.1 s here).
    static let headerRefreshInterval: TimeInterval = 4
    private static let headerRefreshLeeway: DispatchTimeInterval = .milliseconds(100)
    /// RIFF/data sizes are 32-bit. 4 GiB = ~12 h at 48 kHz mono, longer than MAX_RECORDING_HOURS.
    private static let maxDataBytes: UInt64 = 0xFFFF_FFFF - 36

    private let queue: DispatchQueue
    private let lock = NSLock()                     // guards the fields right below (touched from any thread)
    private var acceptedFrames: Int64 = 0
    private var droppedFrames: Int64 = 0
    private var pendingBytes = 0
    private var closed = false
    private var overflowReported = false

    // Everything below is confined to `queue` (or to init before the writer is shared).
    private var fd: Int32 = -1
    private var dataBytes: UInt64 = 0
    private var headerDirty = false
    private var headerTimer: DispatchSourceTimer?
    private var dead = false                        // set after an unrecoverable write error
    private var silenceChunk: [Int16]               // 1 s of zeros, reused by appendSilence

    init(url: URL, sampleRate: Int) throws {
        guard sampleRate >= 8000, sampleRate <= 192_000 else {
            throw RecorderError.failed("unsupported WAV sample rate \(sampleRate)")
        }
        self.url = url
        self.sampleRate = sampleRate
        self.silenceChunk = [Int16](repeating: 0, count: sampleRate)
        self.queue = DispatchQueue(label: "\(AppInfo.bundleID).wav.\(url.lastPathComponent)", qos: .utility)

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handle = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard handle >= 0 else {
            throw RecorderError.failed("cannot create \(url.path): \(String(cString: strerror(errno)))")
        }
        self.fd = handle
        // The initial header goes through write() (not pwrite) so the file offset ends up at byte 44.
        let header = Self.makeHeader(sampleRate: sampleRate, dataBytes: 0)
        let ok = header.withUnsafeBytes { Darwin.write(handle, $0.baseAddress, Self.headerSize) == Self.headerSize }
        guard ok else {
            let msg = String(cString: strerror(errno))
            Darwin.close(handle)
            self.fd = -1
            throw RecorderError.failed("cannot write WAV header to \(url.path): \(msg)")
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.headerRefreshInterval, repeating: Self.headerRefreshInterval, leeway: Self.headerRefreshLeeway)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.headerDirty else { return }
            self.writeHeader()
        }
        timer.resume()
        self.headerTimer = timer
    }

    deinit {
        headerTimer?.cancel()
        if fd >= 0 { Darwin.close(fd) }
    }

    // MARK: Public API

    /// Frames accepted so far (queued or written). Updated synchronously by every append.
    var framesWritten: Int64 {
        lock.lock(); defer { lock.unlock() }
        return acceptedFrames
    }

    /// Frames dropped because the write queue overflowed (should always be 0).
    var framesDropped: Int64 {
        lock.lock(); defer { lock.unlock() }
        return droppedFrames
    }

    var secondsWritten: Double { Double(framesWritten) / Double(sampleRate) }

    func appendSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        enqueue(frames: samples.count, bytes: samples.count * 2) { [self] in
            writePCM(samples)
        }
    }

    /// Float samples in [-1, 1] (clipped); converted to Int16 on the writer queue, not on the caller's thread.
    func appendSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        enqueue(frames: samples.count, bytes: samples.count * 2) { [self] in
            var pcm = [Int16](repeating: 0, count: samples.count)
            for i in 0..<samples.count { pcm[i] = Self.int16(from: samples[i]) }
            writePCM(pcm)
        }
    }

    /// Appends `frames` frames of digital silence (used to keep the timeline continuous across gaps).
    func appendSilence(frames: Int) {
        guard frames > 0 else { return }
        enqueue(frames: frames, bytes: 0) { [self] in
            var left = frames
            while left > 0 {
                let n = min(left, silenceChunk.count)
                silenceChunk.withUnsafeBufferPointer { writeRaw(UnsafeRawPointer($0.baseAddress!), n * 2) }
                left -= n
            }
            headerDirty = true
        }
    }

    /// Drains the queue, writes the final header and closes the file. Idempotent; safe from any thread
    /// except the writer's own queue. Returns the total frames in the file.
    @discardableResult
    func close() -> Int64 { finish(finalizeHeader: true) }

    /// TEST HOOK (crash simulation): flush queued data and close the descriptor WITHOUT refreshing the header,
    /// leaving the file exactly as a killed process would (header sizes stale).
    @discardableResult
    func abandonWithoutFinalizing() -> Int64 { finish(finalizeHeader: false) }

    // MARK: Internals

    private func finish(finalizeHeader: Bool) -> Int64 {
        lock.lock()
        closed = true                   // later appends are ignored; already queued work still runs first
        let frames = acceptedFrames
        lock.unlock()
        queue.sync {
            headerTimer?.cancel()
            headerTimer = nil
            guard fd >= 0 else { return }
            if finalizeHeader {
                writeHeader()
                _ = fsync(fd)
            }
            Darwin.close(fd)
            fd = -1
        }
        return frames
    }

    private func enqueue(frames: Int, bytes: Int, _ work: @escaping () -> Void) {
        lock.lock()
        if closed { lock.unlock(); return }
        if bytes > 0 && pendingBytes + bytes > Self.maxPendingBytes {
            droppedFrames += Int64(frames)
            let first = !overflowReported
            overflowReported = true
            lock.unlock()
            if first { report("WAV write queue overflow (disk too slow?): dropping audio for \(url.lastPathComponent)") }
            return
        }
        acceptedFrames += Int64(frames)
        pendingBytes += bytes
        lock.unlock()
        queue.async { [self] in
            work()
            if bytes > 0 {
                lock.lock(); pendingBytes -= bytes; lock.unlock()
            }
        }
    }

    private func writePCM(_ pcm: [Int16]) {
        pcm.withUnsafeBytes { writeRaw($0.baseAddress!, $0.count) }
        headerDirty = true
    }

    /// Writes all bytes, handling partial writes and EINTR. On error: reports once and stops writing.
    private func writeRaw(_ base: UnsafeRawPointer, _ count: Int) {
        guard !dead, fd >= 0, count > 0 else { return }
        if dataBytes + UInt64(count) > Self.maxDataBytes {
            dead = true
            report("WAV file \(url.lastPathComponent) reached the 4 GiB limit; further audio is discarded")
            return
        }
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, base + offset, count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                dead = true
                report("write to \(url.lastPathComponent) failed: \(String(cString: strerror(errno)))")
                return
            }
            offset += n
        }
        dataBytes += UInt64(count)
    }

    private func writeHeader() {
        guard fd >= 0 else { return }
        let header = Self.makeHeader(sampleRate: sampleRate, dataBytes: dataBytes)
        _ = header.withUnsafeBytes { pwrite(fd, $0.baseAddress, Self.headerSize, 0) }
        headerDirty = false
    }

    private func report(_ message: String) {
        Log.error(message)
        onError?(message)
    }

    static func int16(from x: Float) -> Int16 {
        guard x.isFinite else { return 0 }
        let clipped = max(-1, min(1, x))
        return Int16((clipped * 32767).rounded())
    }

    /// Canonical 44-byte PCM header (RIFF/WAVE, fmt chunk of 16 bytes, data chunk header).
    static func makeHeader(sampleRate: Int, dataBytes: UInt64) -> [UInt8] {
        let data = UInt32(min(dataBytes, maxDataBytes))
        var h = [UInt8]()
        h.reserveCapacity(headerSize)
        func tag(_ s: String) { h.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { for i in 0..<4 { h.append(UInt8((v >> UInt32(8 * i)) & 0xFF)) } }
        func u16(_ v: UInt16) { h.append(UInt8(v & 0xFF)); h.append(UInt8(v >> 8)) }
        tag("RIFF"); u32(36 + data); tag("WAVE")
        // Clamped, never trapping: this also runs on values parsed from a (possibly corrupt) file by repairHeader.
        let rate = UInt32(clamping: sampleRate)
        tag("fmt "); u32(16); u16(1); u16(1)                        // PCM, mono
        u32(rate); u32(UInt32(clamping: Int(rate) * 2))              // rate, byte rate
        u16(2); u16(16)                                              // block align, bits per sample
        tag("data"); u32(data)
        return h
    }
}

// MARK: - Lenient reader / repair (for crash recovery and for tests)

/// What can be recovered from a WAV file even if its header sizes are stale (killed process).
struct WavFileInfo {
    var sampleRate: Int
    var channels: Int
    var bitsPerSample: Int
    var dataOffset: Int
    var headerDataBytes: UInt64      // what the header claims
    var actualDataBytes: UInt64      // what the file length says (data is the last chunk)
    var frames: Int64 { Int64(actualDataBytes) / Int64(max(1, channels * bitsPerSample / 8)) }
    var seconds: Double { sampleRate > 0 ? Double(frames) / Double(sampleRate) : 0 }
    var headerIsConsistent: Bool { headerDataBytes == actualDataBytes }

    /// Parses RIFF chunks; returns nil if the file is not a WAV or has no fmt/data chunk. Never throws, never traps.
    static func read(_ url: URL) -> WavFileInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 4096), head.count >= 12 else { return nil }
        let b = [UInt8](head)
        func tag(_ o: Int) -> String { String(decoding: b[o..<o + 4], as: UTF8.self) }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var pos = 12
        var rate = 0, channels = 0, bits = 0
        var haveFmt = false
        while pos + 8 <= b.count {
            let id = tag(pos)
            let size = Int(u32(pos + 4))
            if id == "fmt " && pos + 8 + 16 <= b.count {
                channels = u16(pos + 10)
                rate = Int(u32(pos + 12))
                bits = u16(pos + 22)
                haveFmt = true
            } else if id == "data" {
                guard haveFmt, channels > 0, bits > 0 else { return nil }
                let offset = pos + 8
                let actual = fileSize > UInt64(offset) ? fileSize - UInt64(offset) : 0
                return WavFileInfo(sampleRate: rate, channels: channels, bitsPerSample: bits, dataOffset: offset,
                                   headerDataBytes: UInt64(size), actualDataBytes: actual)
            }
            pos += 8 + size + (size & 1)
        }
        return nil
    }
}

extension WavWriter {
    /// Rewrites the header of a (crashed) file so RIFF/data sizes match the file length. Returns false if it
    /// could not be parsed or looks corrupt (sample rate outside 8..192 kHz: such a file is left untouched).
    /// Only touches the 44 header bytes.
    @discardableResult
    static func repairHeader(at url: URL) -> Bool {
        guard let info = WavFileInfo.read(url), info.dataOffset == headerSize, info.channels == 1, info.bitsPerSample == 16,
              (8000...192_000).contains(info.sampleRate) else {
            return false
        }
        let fd = Darwin.open(url.path, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        // Drop a trailing odd byte (a torn final sample) so the data chunk holds whole frames.
        let usable = info.actualDataBytes & ~UInt64(1)
        let header = makeHeader(sampleRate: info.sampleRate, dataBytes: usable)
        let ok = header.withUnsafeBytes { pwrite(fd, $0.baseAddress, headerSize, 0) == headerSize }
        if ok && usable != info.actualDataBytes { _ = ftruncate(fd, off_t(headerSize) + off_t(usable)) }
        return ok
    }
}
