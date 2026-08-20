import Foundation
import Synchronization

enum BenchmarkPhase: String, Equatable, Sendable {
    case idle           = "Idle"
    case preparing      = "Preparing"
    case sequentialWrite = "Sequential write"
    case sequentialRead  = "Sequential read"
    case sequentialReadQD = "Sequential read (4 at once)"
    case randomWrite     = "Random 4K write"
    case randomRead      = "Random 4K read"
    case finishing       = "Flushing"
    case done            = "Done"
    case cancelled       = "Cancelled"
    case failed          = "Failed"

    var isTerminal: Bool { self == .done || self == .cancelled || self == .failed }
    var isRunning: Bool { !isTerminal && self != .idle }
}

struct BenchmarkProgress: Equatable, Sendable {
    var phase: BenchmarkPhase = .idle
    var fraction: Double = 0
    /// Throughput over the last progress window, not a running average — this is
    /// what makes an SLC-cache cliff show up as a cliff.
    var instantMBps: Double = 0
    var message: String = ""
}

struct BenchmarkResults: Equatable, Sendable {
    var volumeName: String = ""
    var testBytes: Int64 = 0

    /// Rate while data was being handed to the kernel.
    var sequentialWriteMBps: Double?
    /// Rate including the final `F_FULLFSYNC`. On a drive with a big write
    /// cache this is the honest number and the streaming figure is a fiction.
    var sequentialWriteSustainedMBps: Double?
    var sequentialReadMBps: Double?

    var randomWriteIOPS: Double?
    var randomReadIOPS: Double?
    /// Sequential read with four requests in flight.
    ///
    /// Every other figure here is queue depth 1, which is what a Finder copy
    /// of one big file looks like. NVMe-in-USB enclosures are throttled by
    /// per-command latency rather than bandwidth at QD1 and can read two to
    /// three times faster once a few requests overlap, so reporting only QD1
    /// makes a fast enclosure look broken.
    var sequentialReadQD4MBps: Double?

    /// False when the drive's filesystem rejected `F_FULLFSYNC` (common on
    /// exFAT and FAT, which is what most USB sticks ship formatted as), so the
    /// sustained figure could not be confirmed against media.
    var sustainedIsVerified: Bool = true

    /// (seconds, MB/s) through the sequential write — the shape that reveals a
    /// cache cliff.
    var writeCurve: [(Double, Double)] = []
    var readCurve: [(Double, Double)] = []

    var error: String?

    static func == (a: BenchmarkResults, b: BenchmarkResults) -> Bool {
        a.volumeName == b.volumeName && a.testBytes == b.testBytes
            && a.sequentialWriteMBps == b.sequentialWriteMBps
            && a.sequentialWriteSustainedMBps == b.sequentialWriteSustainedMBps
            && a.sequentialReadMBps == b.sequentialReadMBps
            && a.randomWriteIOPS == b.randomWriteIOPS
            && a.sequentialReadQD4MBps == b.sequentialReadQD4MBps
            && a.sustainedIsVerified == b.sustainedIsVerified
            && a.randomReadIOPS == b.randomReadIOPS
            && a.writeCurve.count == b.writeCurve.count
            && a.readCurve.count == b.readCurve.count
            && a.error == b.error
    }
}

/// Active speed test: writes and reads a scratch file on the target volume with
/// the unified buffer cache disabled, so the numbers describe the drive rather
/// than the Mac's RAM.
final class BenchmarkRunner: Sendable {

    /// 1 MiB sequential blocks. Large enough to amortise per-transfer overhead
    /// on USB, small enough to give a responsive progress curve.
    private static let sequentialBlock = 1 << 20
    private static let randomBlock = 4096
    /// Apple Silicon pages are 16 KiB. Aligning the buffer avoids a bounce copy
    /// on the uncached path.
    private static let pageAlignment = 16384
    private static let randomOpsCap = 4000
    /// Progress fires on whichever comes first: 100 ms elapsed, or this much
    /// data moved. Time alone is not enough — a fast drive can finish a short
    /// test inside one window, leaving the graph empty and the phase label
    /// stuck on "Preparing".
    private static let reportInterval: UInt64 = 100_000_000
    private static let reportBytes: Int64 = 32 << 20
    private static let randomTimeCapSeconds = 5.0
    /// Never fill a drive. A flat margin is wrong at both ends — 512 MB is a
    /// 200% cushion on a 256 MB test and a 3% cushion on a 16 GB one — so the
    /// requirement scales with the test and has a floor.
    private static func requiredFreeBytes(for testBytes: Int64) -> Int64 {
        max(512_000_000, testBytes / 10) + testBytes
    }

    private let queue = DispatchQueue(label: "com.ahmed.conduit.benchmark", qos: .userInitiated)
    /// `Mutex` rather than a lock plus a bare `var`: it makes the whole runner
    /// genuinely `Sendable` under Swift 6 with no unchecked annotation, which
    /// matters because the cancel flag is read from the worker queue and
    /// written from the main actor.
    private let cancelled = Mutex(false)

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    func cancel() { cancelled.withLock { $0 = true } }

    /// Removes scratch files left behind by a crash or a force-quit.
    static func sweepStaleFiles(on mountPath: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: mountPath) else { return }
        for entry in entries where entry.hasPrefix(".conduit-speedtest-") {
            try? fm.removeItem(atPath: (mountPath as NSString).appendingPathComponent(entry))
        }
    }

    func run(volume: VolumeRef,
             testBytes: Int64,
             onProgress: @escaping @Sendable (BenchmarkProgress) -> Void,
             onFinish: @escaping @Sendable (BenchmarkResults) -> Void) {

        cancelled.withLock { $0 = false }

        queue.async {
            var results = BenchmarkResults(volumeName: volume.name, testBytes: testBytes)

            @Sendable func report(_ p: BenchmarkProgress) { onProgress(p) }
            @Sendable func finish(_ r: BenchmarkResults, _ phase: BenchmarkPhase) {
                onProgress(BenchmarkProgress(phase: phase, fraction: 1, instantMBps: 0,
                                             message: r.error ?? ""))
                onFinish(r)
            }

            // MARK: Guards
            if volume.isBootVolume {
                results.error = "Refusing to benchmark a system volume."
                finish(results, .failed); return
            }
            if !volume.isWritable {
                results.error = "\(volume.name) is mounted read-only."
                finish(results, .failed); return
            }
            // Re-read the filesystem rather than trusting the snapshot taken
            // when the volume was picked, which may be minutes stale.
            let freeNow = Volumes.current()
                .first { $0.mountPath == volume.mountPath }?.freeBytes ?? volume.freeBytes
            let required = Self.requiredFreeBytes(for: testBytes)
            if freeNow < required {
                // Decimal GB, matching every other size this app prints.
                results.error = String(format: "Not enough free space — needs %.1f GB free, has %.1f GB.",
                                       Double(required) / 1_000_000_000,
                                       Double(freeNow) / 1_000_000_000)
                finish(results, .failed); return
            }

            report(BenchmarkProgress(phase: .preparing, message: "Creating scratch file"))
            Self.sweepStaleFiles(on: volume.mountPath)

            let path = (volume.mountPath as NSString)
                .appendingPathComponent(".conduit-speedtest-\(UUID().uuidString).bin")
            defer { unlink(path) }

            // MARK: Aligned scratch buffer
            var raw: UnsafeMutableRawPointer?
            guard posix_memalign(&raw, Self.pageAlignment, Self.sequentialBlock) == 0,
                  let buffer = raw else {
                results.error = "Could not allocate an aligned I/O buffer."
                finish(results, .failed); return
            }
            defer { free(buffer) }
            // Incompressible data: a controller that compresses or dedupes zeroes
            // would otherwise report a fantasy write speed.
            arc4random_buf(buffer, Self.sequentialBlock)

            // MARK: Sequential write
            do {
                let outcome = try Self.sequentialWrite(path: path, buffer: buffer,
                                                       totalBytes: testBytes,
                                                       isCancelled: { self.isCancelled },
                                                       report: report)
                results.sequentialWriteMBps = outcome.streamingMBps
                results.sequentialWriteSustainedMBps = outcome.sustainedMBps
                results.writeCurve = outcome.curve
                results.sustainedIsVerified = outcome.flushVerified
            } catch let error as BenchmarkError {
                if case .cancelled = error { finish(results, .cancelled); return }
                results.error = error.description
                finish(results, .failed); return
            } catch {
                results.error = error.localizedDescription
                finish(results, .failed); return
            }
            if self.isCancelled { finish(results, .cancelled); return }

            // MARK: Sequential read
            do {
                let outcome = try Self.sequentialRead(path: path, buffer: buffer,
                                                      totalBytes: testBytes,
                                                      isCancelled: { self.isCancelled },
                                                      report: report)
                results.sequentialReadMBps = outcome.streamingMBps
                results.readCurve = outcome.curve
            } catch let error as BenchmarkError {
                if case .cancelled = error { finish(results, .cancelled); return }
                results.error = error.description
                finish(results, .failed); return
            } catch {
                results.error = error.localizedDescription
                finish(results, .failed); return
            }
            if self.isCancelled { finish(results, .cancelled); return }

            // These were once wrapped in `try?`, which turned EIO from a dying
            // drive — and ENOSPC from the random-write pass — into a blank cell
            // on an otherwise successful-looking report.
            do {
                results.sequentialReadQD4MBps = try Self.concurrentRead(
                    path: path, totalBytes: testBytes, queueDepth: 4,
                    isCancelled: { self.isCancelled }, report: report)
                if self.isCancelled { finish(results, .cancelled); return }

                results.randomReadIOPS = try Self.randomIO(path: path, write: false,
                                                           fileBytes: testBytes,
                                                           isCancelled: { self.isCancelled },
                                                           report: report)
                if self.isCancelled { finish(results, .cancelled); return }

                results.randomWriteIOPS = try Self.randomIO(path: path, write: true,
                                                            fileBytes: testBytes,
                                                            isCancelled: { self.isCancelled },
                                                            report: report)
                if self.isCancelled { finish(results, .cancelled); return }
            } catch let error as BenchmarkError {
                if case .cancelled = error { finish(results, .cancelled); return }
                results.error = error.description
                finish(results, .failed); return
            } catch {
                results.error = error.localizedDescription
                finish(results, .failed); return
            }

            finish(results, .done)
        }
    }

    // MARK: - Phases

    private struct Outcome {
        var streamingMBps: Double
        var sustainedMBps: Double
        var curve: [(Double, Double)]
        var flushVerified: Bool = true
    }

    private enum BenchmarkError: Error, CustomStringConvertible {
        case cancelled
        case open(String, Int32)
        case io(String, Int32)
        case diskFull

        var description: String {
            switch self {
            case .cancelled:            return "Cancelled"
            case .open(let what, let e): return "Could not open \(what): \(String(cString: strerror(e)))"
            case .io(let what, let e):   return "\(what) failed: \(String(cString: strerror(e)))"
            case .diskFull:              return "The drive filled up during the test."
            }
        }
    }

    private static func sequentialWrite(path: String,
                                        buffer: UnsafeMutableRawPointer,
                                        totalBytes: Int64,
                                        isCancelled: () -> Bool,
                                        report: (BenchmarkProgress) -> Void) throws -> Outcome {
        let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw BenchmarkError.open("scratch file for writing", errno) }
        defer { close(fd) }

        // The single most important line in this file. Without F_NOCACHE the
        // first gigabyte lands in RAM and the app reports the speed of the
        // Mac's memory bus, not the drive's.
        _ = fcntl(fd, F_NOCACHE, 1)

        var written: Int64 = 0
        var curve: [(Double, Double)] = []
        let start = monotonicNanos()
        var windowStart = start
        var windowBytes: Int64 = 0
        var blockIndex: UInt64 = 0

        while written < totalBytes {
            if isCancelled() { throw BenchmarkError.cancelled }

            // Vary each block so nothing downstream can dedupe them away.
            buffer.storeBytes(of: blockIndex, toByteOffset: 0, as: UInt64.self)
            blockIndex &+= 1

            let want = Int(min(Int64(sequentialBlock), totalBytes - written))
            var offset = 0
            while offset < want {
                let n = write(fd, buffer.advanced(by: offset), want - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == ENOSPC { throw BenchmarkError.diskFull }
                    throw BenchmarkError.io("Write", errno)
                }
                offset += n
            }
            written += Int64(want)
            windowBytes += Int64(want)

            let now = monotonicNanos()
            let windowNanos = now &- windowStart
            if windowNanos >= reportInterval || windowBytes >= reportBytes {
                let mbps = Double(windowBytes) / (Double(windowNanos) / 1_000_000_000) / 1_000_000
                curve.append((Double(now &- start) / 1_000_000_000, mbps))
                report(BenchmarkProgress(phase: .sequentialWrite,
                                         fraction: Double(written) / Double(totalBytes),
                                         instantMBps: mbps,
                                         message: "Writing"))
                windowStart = now
                windowBytes = 0
            }
        }

        let streamEnd = monotonicNanos()
        // Never leave the curve empty: a test short enough to fit inside one
        // reporting window still deserves a data point.
        if curve.isEmpty {
            let seconds = Double(streamEnd &- start) / 1_000_000_000
            if seconds > 0 {
                curve.append((seconds, Double(totalBytes) / seconds / 1_000_000))
            }
        }
        report(BenchmarkProgress(phase: .finishing, fraction: 1, instantMBps: 0,
                                 message: "Flushing to the drive"))

        // fsync() only pushes to the drive's cache; F_FULLFSYNC tells the drive
        // to commit to media. On a device with a large write buffer the two
        // numbers can differ by an order of magnitude, so both are reported.
        //
        // exFAT and FAT — what most USB sticks arrive formatted as — can reject
        // F_FULLFSYNC outright. Falling back silently would present a
        // cache-buffered number as a committed one, so the result is flagged.
        var flushVerified = true
        if fcntl(fd, F_FULLFSYNC, 0) == -1 {
            flushVerified = false
            _ = fsync(fd)
        }
        let flushEnd = monotonicNanos()

        let mb = Double(totalBytes) / 1_000_000
        return Outcome(
            streamingMBps: mb / (Double(streamEnd &- start) / 1_000_000_000),
            sustainedMBps: mb / (Double(flushEnd &- start) / 1_000_000_000),
            curve: curve,
            flushVerified: flushVerified
        )
    }

    private static func sequentialRead(path: String,
                                       buffer: UnsafeMutableRawPointer,
                                       totalBytes: Int64,
                                       isCancelled: () -> Bool,
                                       report: (BenchmarkProgress) -> Void) throws -> Outcome {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw BenchmarkError.open("scratch file for reading", errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var readBytes: Int64 = 0
        var curve: [(Double, Double)] = []
        let start = monotonicNanos()
        var windowStart = start
        var windowBytes: Int64 = 0

        while readBytes < totalBytes {
            if isCancelled() { throw BenchmarkError.cancelled }

            let want = Int(min(Int64(sequentialBlock), totalBytes - readBytes))
            var offset = 0
            while offset < want {
                let n = read(fd, buffer.advanced(by: offset), want - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw BenchmarkError.io("Read", errno)
                }
                if n == 0 { break }                  // short file; stop cleanly
                offset += n
            }
            if offset == 0 { break }
            readBytes += Int64(offset)
            windowBytes += Int64(offset)

            let now = monotonicNanos()
            let windowNanos = now &- windowStart
            if windowNanos >= reportInterval || windowBytes >= reportBytes {
                let mbps = Double(windowBytes) / (Double(windowNanos) / 1_000_000_000) / 1_000_000
                curve.append((Double(now &- start) / 1_000_000_000, mbps))
                report(BenchmarkProgress(phase: .sequentialRead,
                                         fraction: Double(readBytes) / Double(totalBytes),
                                         instantMBps: mbps,
                                         message: "Reading"))
                windowStart = now
                windowBytes = 0
            }
        }

        let end = monotonicNanos()
        let mb = Double(readBytes) / 1_000_000
        let seconds = Double(end &- start) / 1_000_000_000
        if curve.isEmpty, seconds > 0 { curve.append((seconds, mb / seconds)) }
        return Outcome(streamingMBps: seconds > 0 ? mb / seconds : 0,
                       sustainedMBps: seconds > 0 ? mb / seconds : 0,
                       curve: curve)
    }

    /// Sequential read with `queueDepth` requests in flight at once.
    ///
    /// Each worker owns a disjoint, contiguous slice of the file, so the access
    /// pattern stays sequential per worker while the device sees several
    /// outstanding commands. `concurrentPerform` blocks until all slices finish,
    /// which is what we want to time.
    private static func concurrentRead(path: String,
                                       totalBytes: Int64,
                                       queueDepth: Int,
                                       isCancelled: @Sendable () -> Bool,
                                       report: @Sendable (BenchmarkProgress) -> Void) throws -> Double {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw BenchmarkError.open("scratch file", errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        report(BenchmarkProgress(phase: .sequentialReadQD, fraction: 0, instantMBps: 0,
                                 message: "Reading with \(queueDepth) requests in flight"))

        let sliceBytes = totalBytes / Int64(queueDepth)
        let readBytes = Mutex<Int64>(0)
        let failed = Mutex(false)
        let start = monotonicNanos()

        DispatchQueue.concurrentPerform(iterations: queueDepth) { worker in
            var buffer: UnsafeMutableRawPointer?
            guard posix_memalign(&buffer, pageAlignment, sequentialBlock) == 0,
                  let buffer else { failed.withLock { $0 = true }; return }
            defer { free(buffer) }

            let base = Int64(worker) * sliceBytes
            var offset: Int64 = 0
            while offset < sliceBytes {
                if isCancelled() { return }
                let want = Int(min(Int64(sequentialBlock), sliceBytes - offset))
                let n = pread(fd, buffer, want, off_t(base + offset))
                if n < 0 {
                    if errno == EINTR { continue }
                    failed.withLock { $0 = true }
                    return
                }
                if n == 0 { break }
                offset += Int64(n)
                readBytes.withLock { $0 += Int64(n) }
            }
        }

        if isCancelled() { throw BenchmarkError.cancelled }
        if failed.withLock({ $0 }) { throw BenchmarkError.io("Concurrent read", EIO) }

        let seconds = Double(monotonicNanos() &- start) / 1_000_000_000
        let moved = readBytes.withLock { $0 }
        return seconds > 0 ? Double(moved) / seconds / 1_000_000 : 0
    }

    /// Queue depth 1, which is what a Finder copy of many small files actually
    /// looks like — and where cheap USB sticks fall apart.
    private static func randomIO(path: String,
                                 write doWrite: Bool,
                                 fileBytes: Int64,
                                 isCancelled: @Sendable () -> Bool,
                                 report: @Sendable (BenchmarkProgress) -> Void) throws -> Double {
        let fd = open(path, doWrite ? O_RDWR : O_RDONLY)
        guard fd >= 0 else { throw BenchmarkError.open("scratch file", errno) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        var raw: UnsafeMutableRawPointer?
        guard posix_memalign(&raw, pageAlignment, randomBlock) == 0, let buffer = raw else {
            throw BenchmarkError.io("Buffer allocation", ENOMEM)
        }
        defer { free(buffer) }
        arc4random_buf(buffer, randomBlock)

        let blocks = max(Int64(1), fileBytes / Int64(randomBlock))
        let phase: BenchmarkPhase = doWrite ? .randomWrite : .randomRead
        let start = monotonicNanos()
        var ops = 0

        while ops < randomOpsCap {
            if isCancelled() { throw BenchmarkError.cancelled }
            let offset = Int64(arc4random_uniform(UInt32(min(blocks, Int64(UInt32.max))))) * Int64(randomBlock)

            let n = doWrite
                ? pwrite(fd, buffer, randomBlock, off_t(offset))
                : pread(fd, buffer, randomBlock, off_t(offset))
            if n < 0 {
                if errno == EINTR { continue }
                throw BenchmarkError.io(doWrite ? "Random write" : "Random read", errno)
            }
            ops += 1

            if ops % 64 == 0 {
                let elapsed = Double(monotonicNanos() &- start) / 1_000_000_000
                report(BenchmarkProgress(phase: phase,
                                         fraction: min(1, elapsed / randomTimeCapSeconds),
                                         instantMBps: Double(ops) / max(elapsed, 0.001)
                                             * Double(randomBlock) / 1_000_000,
                                         message: doWrite ? "Random writes" : "Random reads"))
                if elapsed >= randomTimeCapSeconds { break }
            }
        }

        if doWrite { _ = fcntl(fd, F_FULLFSYNC, 0) }
        let seconds = Double(monotonicNanos() &- start) / 1_000_000_000
        return seconds > 0 ? Double(ops) / seconds : 0
    }
}
