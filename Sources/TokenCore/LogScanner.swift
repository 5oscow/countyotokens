import Darwin
import Foundation

/// One priced model response.
struct UsageRow: Sendable {
    var timestampMs: Int64
    var model: String
    var tokens: Int
    /// Nil when the model has no known price.
    var cost: Double?
    /// Lower wins when the same response is logged in more than one file:
    /// incomplete (4), then sidechain (2), then subagent transcript (1).
    var rank: UInt8
    var isIncomplete: Bool { self.rank >= 4 }
}

/// Incrementally scans Claude Code transcripts (`~/.claude/projects`) and pi/omp agent sessions
/// (`~/.pi/agent/sessions`, `~/.omp/agent/sessions`) for Anthropic usage.
///
/// Each file keeps its rows and the byte offset it has read up to, so a refresh is one `fts`
/// walk plus parsing whatever was appended. Files untouched since the horizon are never opened.
/// Cold scans parse files in parallel, biggest first.
public final class LogScanner: @unchecked Sendable {
    public enum Format: Sendable { case claudeCode, pi }

    public struct Root: Sendable {
        public var url: URL
        public var format: Format
        public init(_ url: URL, _ format: Format) {
            self.url = url
            self.format = format
        }
    }

    private struct FileState: Sendable {
        var inode: UInt64
        var size: Int64
        var mtime: Int64
        var parsedBytes: Int64
        var format: Format
        var isSubagent: Bool
        var sessionId: String?
        /// Final row per response.
        var keyed: [String: UsageRow] = [:]
        var unkeyed: [UsageRow] = []
    }

    public struct Stats: Sendable, CustomStringConvertible {
        public var files = 0
        public var parsedFiles = 0
        public var parsedBytes: Int64 = 0
        public var rows = 0
        public var inventoryMs = 0.0
        public var parseMs = 0.0
        public var aggregateMs = 0.0
        public var totalMs: Double { self.inventoryMs + self.parseMs + self.aggregateMs }

        public var description: String {
            String(
                format: "%7.1f ms (walk %.1f, parse %.1f, aggregate %.1f) · %d files, %d parsed, %.1f MB, %d rows",
                self.totalMs, self.inventoryMs, self.parseMs, self.aggregateMs,
                self.files, self.parsedFiles, Double(self.parsedBytes) / 1e6, self.rows)
        }
    }

    private struct Winner {
        var row: UsageRow
        var path: String
    }

    private var files: [String: FileState] = [:]
    /// Cross-file dedupe, maintained incrementally while files only grow.
    private var winners: [String: Winner] = [:]
    private var unkeyedCount = 0
    private var winnersAreStale = true
    private var lastSnapshot: UsageSnapshot?
    private var lastBucket: String?
    private var prices: PriceBook
    private let roots: [Root]
    private let lock = NSLock()

    public init(roots: [Root] = LogScanner.defaultRoots(), prices: PriceBook = PriceCatalog.load()) {
        self.roots = roots
        self.prices = prices
    }

    public static func defaultRoots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [Root] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [Root] = []
        if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            roots += custom.split(separator: ",").map {
                Root(URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces)).appendingPathComponent("projects"),
                     .claudeCode)
            }
        } else {
            roots.append(Root(home.appendingPathComponent(".config/claude/projects"), .claudeCode))
            roots.append(Root(home.appendingPathComponent(".claude/projects"), .claudeCode))
        }
        roots.append(Root(home.appendingPathComponent(".pi/agent/sessions"), .pi))
        roots.append(Root(home.appendingPathComponent(".omp/agent/sessions"), .pi))
        return roots
    }

    public var watchedPaths: [String] { self.roots.map(\.url.path) }

    /// New prices invalidate every parsed row, so the next scan re-reads from the start.
    public func updatePrices(_ newer: [String: ModelPrice]) {
        self.lock.withLock {
            self.prices.overlay(newer)
            self.files.removeAll()
            self.winnersAreStale = true
            self.lastSnapshot = nil
        }
    }

    public func scan(now: Date = Date(), settings: WindowSettings, calendar: Calendar = .current) -> (UsageSnapshot, Stats) {
        self.lock.withLock { self.scanLocked(now: now, settings: settings, calendar: calendar) }
    }

    private func scanLocked(now: Date, settings: WindowSettings, calendar: Calendar) -> (UsageSnapshot, Stats) {
        var stats = Stats()
        let horizonMs = Int64(UsageSnapshot.horizon(now: now, settings: settings, calendar: calendar)
            .timeIntervalSince1970 * 1000)

        // 1. Walk: one fts pass per root, stat info included.
        var clock = ContinuousClock.now
        let inventory = self.inventory(horizonMs: horizonMs)
        stats.files = inventory.count
        stats.inventoryMs = clock.lapMs()

        // 2. Parse appended bytes, in parallel.
        var jobs: [(path: String, stamp: Stamp, offset: Int64, state: FileState?)] = []
        for (path, stamp) in inventory {
            let existing = self.files[path]
            if let existing, existing.inode == stamp.inode, existing.size == stamp.size, existing.mtime == stamp.mtime {
                continue
            }
            if let existing, existing.inode == stamp.inode, stamp.size >= existing.size {
                jobs.append((path, stamp, existing.parsedBytes, existing))
            } else {
                // Rewritten or replaced: previously counted rows may be gone.
                if existing != nil { self.winnersAreStale = true }
                jobs.append((path, stamp, 0, nil))
            }
        }
        jobs.sort { $0.stamp.size - $0.offset > $1.stamp.size - $1.offset }
        let results = UnsafeMutableBufferPointer<FileState?>.allocate(capacity: jobs.count)
        results.initialize(repeating: nil)
        defer { results.deinitialize().deallocate() }
        let prices = self.prices
        let frozenJobs = jobs
        nonisolated(unsafe) let output = results
        DispatchQueue.concurrentPerform(iterations: frozenJobs.count) { index in
            let job = frozenJobs[index]
            var state = job.state ?? FileState(
                inode: job.stamp.inode, size: 0, mtime: 0, parsedBytes: 0, format: job.stamp.format,
                isSubagent: job.path.contains("/subagents/"))
            Self.parse(path: job.path, from: job.offset, into: &state, horizonMs: horizonMs, prices: prices)
            state.inode = job.stamp.inode
            state.size = job.stamp.size
            state.mtime = job.stamp.mtime
            output[index] = state
        }
        for (index, job) in jobs.enumerated() {
            guard let state = results[index] else { continue }
            stats.parsedBytes += job.stamp.size - job.offset
            if !self.winnersAreStale {
                self.mergeWinners(path: job.path, old: job.state, new: state)
            }
            self.files[job.path] = state
        }
        stats.parsedFiles = jobs.count
        for path in self.files.keys where inventory[path] == nil {
            self.files.removeValue(forKey: path)
            self.winnersAreStale = true
        }
        // A cold scan churns through gigabytes; hand the freed heap back instead of keeping it resident.
        if stats.parsedBytes > 64_000_000 { malloc_zone_pressure_relief(nil, 0) }
        stats.parseMs = clock.lapMs()

        // 3. Dedupe and aggregate. Nothing new on the same day and window: reuse the last result.
        let changed = !jobs.isEmpty || self.winnersAreStale || self.lastSnapshot == nil
        if self.winnersAreStale { self.rebuildWinners() }
        stats.rows = self.winners.count + self.unkeyedCount
        let bucket = UsageSnapshot.bucketKey(now: now, settings: settings, calendar: calendar)
        var snapshot: UsageSnapshot
        if !changed, let last = self.lastSnapshot, self.lastBucket == bucket {
            snapshot = last
            snapshot.generatedAt = now
        } else {
            snapshot = UsageSnapshot.build(now: now, settings: settings, calendar: calendar) { visit in
                for winner in self.winners.values where !winner.row.isIncomplete { visit(winner.row) }
                for file in self.files.values { file.unkeyed.forEach(visit) }
            }
        }
        self.lastSnapshot = snapshot
        self.lastBucket = bucket
        stats.aggregateMs = clock.lapMs()
        return (snapshot, stats)
    }

    // MARK: - Walk

    private struct Stamp {
        var inode: UInt64
        var size: Int64
        var mtime: Int64
        var format: Format
    }

    private func inventory(horizonMs: Int64) -> [String: Stamp] {
        var result: [String: Stamp] = [:]
        result.reserveCapacity(self.files.count + 64)
        for root in self.roots {
            let rootPath = root.url.resolvingSymlinksInPath().path
            rootPath.withCString { cPath in
                var paths: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
                defer { free(paths[0]) }
                guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
                defer { fts_close(fts) }
                while let entry = fts_read(fts) {
                    let info = Int32(entry.pointee.fts_info)
                    if info == FTS_D, entry.pointee.fts_level > 0, entry.pointee.fts_name == 0x2E { // hidden dir
                        fts_set(fts, entry, FTS_SKIP)
                        continue
                    }
                    guard info == FTS_F, let stat = entry.pointee.fts_statp?.pointee else { continue }
                    let nameLength = Int(entry.pointee.fts_namelen)
                    guard nameLength > 6 else { continue }
                    let path = String(cString: entry.pointee.fts_path)
                    guard path.hasSuffix(".jsonl") else { continue }
                    let mtimeMs = Int64(stat.st_mtimespec.tv_sec) * 1000 + Int64(stat.st_mtimespec.tv_nsec / 1_000_000)
                    // A file last written before the horizon cannot hold a row inside it.
                    guard mtimeMs >= horizonMs else { continue }
                    result[path] = Stamp(inode: UInt64(stat.st_ino), size: Int64(stat.st_size), mtime: mtimeMs,
                                         format: root.format)
                }
            }
        }
        return result
    }

    // MARK: - Parse

    private static let claudeMarker = Array(#""type":"assistant""#.utf8)
    private static let usageMarker = Array(#""usage""#.utf8)
    private static let piMessageMarker = Array(#""role":"assistant""#.utf8)
    private static let piSessionMarker = Array(#""type":"session""#.utf8)

    private static func parse(path: String, from offset: Int64, into state: inout FileState, horizonMs: Int64, prices: PriceBook) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        let size = Int64(info.st_size)
        guard size > offset else { return }
        let length = Int(size - offset)
        // Map only the unread tail; mmap wants a page-aligned offset.
        let pageSize = Int64(getpagesize())
        let alignedOffset = offset - offset % pageSize
        let slack = Int(offset - alignedOffset)
        guard let map = mmap(nil, length + slack, PROT_READ, MAP_PRIVATE, fd, off_t(alignedOffset)),
              map != MAP_FAILED
        else { return }
        defer { munmap(map, length + slack) }
        madvise(map, length + slack, MADV_SEQUENTIAL)
        let base = UnsafePointer<UInt8>(map.assumingMemoryBound(to: UInt8.self)) + slack

        var cursor = 0
        while cursor < length {
            guard let newline = memchr(base + cursor, 0x0A, length - cursor) else { break }
            let end = UnsafePointer<UInt8>(newline.assumingMemoryBound(to: UInt8.self)) - base
            let line = UnsafeBufferPointer(start: base + cursor, count: end - cursor)
            // Each decoded line is a tree of autoreleased Foundation objects; drain them per line
            // or a cold scan of gigabytes of transcripts balloons resident memory.
            autoreleasepool {
                switch state.format {
                case .claudeCode:
                    if Self.contains(line, Self.claudeMarker), Self.contains(line, Self.usageMarker) {
                        Self.ingestClaudeCode(line: line, into: &state, horizonMs: horizonMs, prices: prices)
                    }
                case .pi:
                    if Self.contains(line, Self.piMessageMarker), Self.contains(line, Self.usageMarker) {
                        Self.ingestPi(line: line, into: &state, horizonMs: horizonMs, prices: prices)
                    } else if state.sessionId == nil, Self.contains(line, Self.piSessionMarker) {
                        state.sessionId = Self.object(line)?["id"] as? String
                    }
                }
            }
            cursor = end + 1
        }
        // A trailing line without a newline is still being written; it is read next time.
        state.parsedBytes = offset + Int64(cursor)
    }

    @inline(__always)
    private static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBufferPointer { memmem(base, haystack.count, $0.baseAddress, $0.count) != nil }
    }

    private static func object(_ line: UnsafeBufferPointer<UInt8>) -> [String: Any]? {
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line.baseAddress!), count: line.count,
                        deallocator: .none)
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func int(_ value: Any?) -> Int { max(0, (value as? NSNumber)?.intValue ?? 0) }

    private static func ingestClaudeCode(line: UnsafeBufferPointer<UInt8>, into state: inout FileState, horizonMs: Int64, prices: PriceBook) {
        guard let object = Self.object(line),
              object["type"] as? String == "assistant",
              let timestampMs = (object["timestamp"] as? String).flatMap(Timestamp.parseMs),
              timestampMs >= horizonMs,
              let message = object["message"] as? [String: Any],
              let model = message["model"] as? String,
              let usage = message["usage"] as? [String: Any]
        else { return }

        let input = Self.int(usage["input_tokens"])
        let output = Self.int(usage["output_tokens"])
        let cacheRead = Self.int(usage["cache_read_input_tokens"])
        let cacheWrite = Self.int(usage["cache_creation_input_tokens"])
        guard input + output + cacheRead + cacheWrite > 0 else { return }
        // Proxies can log a cache-unaware estimate at message start; it is not real usage.
        let isIncomplete = message["stop_reason"] is NSNull && input > 0 && output == 0
            && usage["cache_read_input_tokens"] == nil && usage["cache_creation_input_tokens"] == nil
        let oneHour = Self.int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"])
        let normalized = PriceBook.normalize(model)
        let isSidechain = (object["isSidechain"] as? Bool) ?? false
        let row = UsageRow(
            timestampMs: timestampMs,
            model: normalized,
            tokens: input + output + cacheRead + cacheWrite,
            cost: prices.price(for: normalized)?.cost(
                input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, cacheWrite1h: oneHour),
            rank: (isIncomplete ? 4 : 0) + (isSidechain ? 2 : 0) + (state.isSubagent ? 1 : 0))

        let messageId = message["id"] as? String
        let requestId = object["requestId"] as? String ?? object["request_id"] as? String
        let sessionId = object["sessionId"] as? String ?? object["session_id"] as? String
        let key: String? = if let messageId, let requestId {
            messageId + "|" + requestId
        } else if let messageId, !messageId.isEmpty, let sessionId, !sessionId.isEmpty {
            // Proxies can omit requestId while repeating usage for the same message.
            "s|" + sessionId + "|" + messageId
        } else {
            nil
        }
        guard let key else {
            if !isIncomplete { state.unkeyed.append(row) }
            return
        }
        // Streaming writes one line per content block; keep the last complete one.
        if !isIncomplete || state.keyed[key]?.isIncomplete != false {
            state.keyed[key] = row
        }
    }

    private static func ingestPi(line: UnsafeBufferPointer<UInt8>, into state: inout FileState, horizonMs: Int64, prices: PriceBook) {
        guard let object = Self.object(line),
              object["type"] as? String == "message",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              ((message["provider"] ?? object["provider"]) as? String)?.lowercased() == "anthropic",
              let model = (message["model"] ?? object["model"]) as? String,
              let usage = message["usage"] as? [String: Any]
        else { return }
        let timestampMs: Int64? = if let ms = message["timestamp"] as? NSNumber {
            ms.int64Value > 1_000_000_000_000 ? ms.int64Value : ms.int64Value * 1000
        } else {
            (object["timestamp"] as? String).flatMap(Timestamp.parseMs)
        }
        guard let timestampMs, timestampMs >= horizonMs else { return }

        let input = Self.int(usage["input"])
        let output = Self.int(usage["output"])
        let cacheRead = Self.int(usage["cacheRead"])
        let cacheWrite = Self.int(usage["cacheWrite"])
        let oneHour = Self.int(usage["cacheWrite1h"] ?? (usage["cttl"] as? [String: Any])?["ephemeral1h"])
        let derived = input + output + cacheRead + cacheWrite
        let total = max(Self.int(usage["totalTokens"]), derived)
        guard total > 0 else { return }
        let normalized = PriceBook.normalize(model)
        // A reported total that disagrees with its parts cannot be priced honestly.
        let row = UsageRow(
            timestampMs: timestampMs,
            model: normalized,
            tokens: total,
            cost: total == derived ? prices.price(for: normalized)?.cost(
                input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, cacheWrite1h: oneHour) : nil,
            rank: 0)
        if let sessionId = state.sessionId, let entryId = object["id"] as? String {
            state.keyed["pi|" + sessionId + "|" + entryId] = row
        } else {
            state.unkeyed.append(row)
        }
    }

    // MARK: - Cross-file dedupe

    /// The same response can be logged in a parent transcript and in a subagent or resumed copy.
    /// The lowest rank wins, then the lexically first path.
    @inline(__always)
    private static func beats(_ row: UsageRow, _ path: String, _ other: Winner) -> Bool {
        (row.rank, path) < (other.row.rank, other.path)
    }

    private func rebuildWinners() {
        self.winners.removeAll(keepingCapacity: true)
        self.unkeyedCount = 0
        for (path, file) in self.files {
            self.unkeyedCount += file.unkeyed.count
            for (key, row) in file.keyed {
                if let existing = self.winners[key], !Self.beats(row, path, existing) { continue }
                self.winners[key] = Winner(row: row, path: path)
            }
        }
        self.winnersAreStale = false
    }

    /// Folds a grown file into the winners without revisiting other files.
    private func mergeWinners(path: String, old: FileState?, new: FileState) {
        self.unkeyedCount += new.unkeyed.count - (old?.unkeyed.count ?? 0)
        for (key, row) in new.keyed {
            if let oldRow = old?.keyed[key], oldRow.rank == row.rank, oldRow.timestampMs == row.timestampMs,
               oldRow.tokens == row.tokens
            {
                continue
            }
            if let existing = self.winners[key] {
                if existing.path == path {
                    // Our own row changed; if it got worse, another file may now win.
                    if row.rank > existing.row.rank {
                        self.winnersAreStale = true
                        return
                    }
                } else if !Self.beats(row, path, existing) {
                    continue
                }
            }
            self.winners[key] = Winner(row: row, path: path)
        }
    }

}

extension ContinuousClock.Instant {
    /// Milliseconds since `self`, then moves `self` to now.
    mutating func lapMs() -> Double {
        let now = ContinuousClock.now
        let elapsed = self.duration(to: now)
        self = now
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
}
