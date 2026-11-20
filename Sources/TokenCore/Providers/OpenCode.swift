import Foundation
import SQLite3

/// OpenCode keeps everything in one SQLite database. It is opened read-only, never written.
enum OpenCodeDB {
    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let explicit = environment["OPENCODE_DB"], explicit.hasPrefix("/") { return URL(fileURLWithPath: explicit) }
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return dataHome.appendingPathComponent("opencode/opencode.db")
    }

    /// Runs `body` with a read-only connection, or returns nil when the database can't be opened.
    static func read<T>(_ body: (OpaquePointer) -> T) -> T? {
        let path = self.url().path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        return body(db)
    }

    /// Identity of the database and its WAL: unchanged identity means unchanged rows.
    static func fingerprint() -> String {
        let path = self.url().path
        return [path, path + "-wal"].map { file in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file) else { return "-" }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size)@\(modified)"
        }.joined(separator: "|")
    }

    /// The credential OpenCode's CLI holds for Go: the `opencode-go` integration first, then the
    /// general `opencode` login. API keys as stored; OAuth logins only while unexpired.
    static func goCredential() -> String? {
        self.read { db -> String? in
            var statement: OpaquePointer?
            let sql = """
            SELECT value FROM credential
            WHERE active = 1 AND integration_id IN ('opencode-go', 'opencode')
            ORDER BY CASE integration_id WHEN 'opencode-go' THEN 0 ELSE 1 END, time_updated DESC
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0),
                      let json = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any]
                else { continue }
                switch json["type"] as? String {
                case "key":
                    if let key = JSONValue.string(json["key"]) { return key }
                case "oauth":
                    if let access = JSONValue.string(json["access"]),
                       let expires = JSONValue.number(json["expires"]), expires / 1000 > Date().timeIntervalSince1970
                    {
                        return access
                    }
                default: continue
                }
            }
            return nil
        } ?? nil
    }
}

/// OpenCode Go subscription limits: rolling 5-hour, weekly and monthly, from opencode.ai with the
/// key the OpenCode CLI already holds (or `OPENCODE_API_KEY`).
public enum OpenCodeGoLimits {
    static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    public static func fetch() async throws(LimitsError) -> PlanLimits {
        let key = JSONValue.string(ProcessInfo.processInfo.environment["OPENCODE_API_KEY"]) ?? OpenCodeDB.goCredential()
        guard let key else { throw .signedOut }
        let json = try await HTTP.json(self.endpoint, headers: [
            "Authorization": "Bearer \(key)",
            "User-Agent": "countyotokens",
        ])
        guard let limits = self.parse(json, now: Date()) else { throw .failed }
        return limits
    }

    static func parse(_ json: [String: Any], now: Date) -> PlanLimits? {
        guard let usage = json["usage"] as? [String: Any] else { return nil }
        let percentKeys = ["usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent", "used_percent", "utilization"]
        let resetInKeys = ["resetInSec", "resetInSeconds", "resetSeconds", "reset_in_sec", "resetsInSec"]
        let resetAtKeys = ["resetAt", "resetsAt", "reset_at", "resets_at", "nextReset", "renewAt"]
        func window(_ key: String, id: String, title: String, duration: TimeInterval) -> PlanLimits.Limit? {
            guard let entry = usage[key] as? [String: Any],
                  let used = percentKeys.lazy.compactMap({ JSONValue.number(entry[$0]) }).first
            else { return nil }
            let reset = resetInKeys.lazy.compactMap { JSONValue.number(entry[$0]) }.first.map { now.addingTimeInterval($0) }
                ?? resetAtKeys.lazy.compactMap { JSONValue.date(entry[$0]) }.first
            return PlanLimits.Limit(id: id, title: title, usedPercent: used, resetsAt: reset, duration: duration)
        }
        let items = [
            window("rolling", id: "session", title: "5-hour", duration: PlanLimits.Window.session),
            window("weekly", id: "weekly", title: "Weekly", duration: PlanLimits.Window.week),
            window("monthly", id: "monthly", title: "Monthly", duration: PlanLimits.Window.month),
        ].compactMap(\.self)
        return items.isEmpty ? nil : PlanLimits(items: items, fetchedAt: now)
    }
}

/// Spend recorded by OpenCode for one family of its providers: `opencode-go` (the Go subscription)
/// or `opencode` (Zen, pay as you go). Costs are OpenCode's own recorded dollars, never re-priced.
public final class OpenCodeSpend: SpendSource, @unchecked Sendable {
    private let providerIDs: Set<String>
    private let lock = NSLock()
    private var lastKey: String?
    private var lastSnapshot: UsageSnapshot?

    public init(providerIDs: Set<String>) {
        self.providerIDs = providerIDs
    }

    public static let go = OpenCodeSpend(providerIDs: ["opencode-go"])
    public static let zen = OpenCodeSpend(providerIDs: ["opencode"])

    public var watchedPaths: [String] { [OpenCodeDB.url().deletingLastPathComponent().path] }

    public func spend(now: Date, settings: WindowSettings, calendar: Calendar) -> UsageSnapshot {
        self.lock.withLock {
            let key = OpenCodeDB.fingerprint() + "|" + UsageSnapshot.bucketKey(now: now, settings: settings, calendar: calendar)
            if key == self.lastKey, var snapshot = self.lastSnapshot {
                snapshot.generatedAt = now
                return snapshot
            }
            let horizon = UsageSnapshot.horizon(now: now, settings: settings, calendar: calendar)
            let rows = self.rows(sinceMs: Int64(horizon.timeIntervalSince1970 * 1000))
            let snapshot = UsageSnapshot.build(now: now, settings: settings, calendar: calendar) { visit in
                rows.forEach(visit)
            }
            self.lastKey = key
            self.lastSnapshot = snapshot
            return snapshot
        }
    }

    /// One row per assistant message (OpenCode's v2 `session_message` table).
    private func rows(sinceMs: Int64) -> [UsageRow] {
        OpenCodeDB.read { db -> [UsageRow] in
            let sql = """
            SELECT time_created,
                   json_extract(data, '$.model.providerID'),
                   json_extract(data, '$.model.id'),
                   json_extract(data, '$.cost'),
                   json_extract(data, '$.tokens.total'),
                   json_extract(data, '$.tokens.input'),
                   json_extract(data, '$.tokens.output'),
                   json_extract(data, '$.tokens.reasoning'),
                   json_extract(data, '$.tokens.cache.read'),
                   json_extract(data, '$.tokens.cache.write')
            FROM session_message
            WHERE type = 'assistant' AND time_created >= ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, sinceMs)
            var rows: [UsageRow] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let provider = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                      self.providerIDs.contains(provider)
                else { continue }
                let model = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "unknown"
                let cost: Double? = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
                var tokens = Int(sqlite3_column_int64(statement, 4))
                if tokens == 0 {
                    tokens = (5 ... 9).reduce(0) { $0 + Int(sqlite3_column_int64(statement, Int32($1))) }
                }
                rows.append(UsageRow(
                    timestampMs: sqlite3_column_int64(statement, 0),
                    model: model, tokens: tokens, cost: cost ?? 0, rank: 0))
            }
            return rows
        } ?? []
    }
}
