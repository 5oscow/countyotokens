import Foundation

private enum CodexHome {
    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = JSONValue.string(environment["CODEX_HOME"]) { return URL(fileURLWithPath: home) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
}

/// Incrementally scans Codex CLI sessions (`~/.codex/sessions`, `archived_sessions`) and prices each
/// response at OpenAI list prices.
///
/// Each `event_msg` / `token_count` line carries the response's own usage (`last_token_usage`) and
/// the session's running total (`total_token_usage`); `turn_context` lines say which model ran.
/// A re-emitted running total is skipped so a repeated line never counts twice. Files remember
/// how far they were read, so a refresh only parses appended lines.
public final class CodexScanner: SpendSource, @unchecked Sendable {
    struct Totals: Equatable {
        var input = 0
        var cached = 0
        var output = 0
    }

    struct FileState {
        var size: Int64
        var modified: TimeInterval
        var parsed: Int64
        var model: String?
        var lastTotal: Totals?
        var rows: [UsageRow]
    }

    private let lock = NSLock()
    private var prices: PriceBook
    private var files: [String: FileState] = [:]
    private var lastKey: String?
    private var lastSnapshot: UsageSnapshot?
    private let roots: [URL]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, prices: PriceBook = PriceCatalog.load()) {
        let home = CodexHome.url(environment: environment)
        self.roots = [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
        self.prices = prices
    }

    public var watchedPaths: [String] { self.roots.map(\.path) }

    public static func hasSessions(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let root = CodexHome.url(environment: environment).appendingPathComponent("sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walker where url.pathExtension == "jsonl" { return true }
        return false
    }

    public func updatePrices(_ newer: [String: ModelPrice]) {
        self.lock.withLock {
            self.prices.overlay(newer)
            self.files.removeAll()
            self.lastSnapshot = nil
        }
    }

    public func spend(now: Date, settings: WindowSettings, calendar: Calendar) -> UsageSnapshot {
        self.lock.withLock {
            let horizon = UsageSnapshot.horizon(now: now, settings: settings, calendar: calendar).timeIntervalSince1970
            var seen = Set<String>()
            var byName: [String: String] = [:] // rollout file name → chosen path (live copy beats archived)
            var changed = false
            for (index, root) in self.roots.enumerated() {
                guard let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles])
                else { continue }
                for case let url as URL in walker where url.pathExtension == "jsonl" {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    guard modified >= horizon else { continue }
                    let name = url.lastPathComponent
                    if index > 0, byName[name] != nil { continue }
                    byName[name] = url.path
                    seen.insert(url.path)
                    let size = Int64(values?.fileSize ?? 0)
                    if let state = self.files[url.path], state.size == size, state.modified == modified { continue }
                    self.parse(url, size: size, modified: modified)
                    changed = true
                }
            }
            let before = self.files.count
            self.files = self.files.filter { seen.contains($0.key) }
            changed = changed || before != self.files.count

            let key = UsageSnapshot.bucketKey(now: now, settings: settings, calendar: calendar)
            if !changed, key == self.lastKey, var snapshot = self.lastSnapshot {
                snapshot.generatedAt = now
                return snapshot
            }
            let snapshot = UsageSnapshot.build(now: now, settings: settings, calendar: calendar) { visit in
                for state in self.files.values { state.rows.forEach(visit) }
            }
            self.lastKey = key
            self.lastSnapshot = snapshot
            return snapshot
        }
    }

    /// Reads appended complete lines; a shrunk or replaced file is read again from the start.
    private func parse(_ url: URL, size: Int64, modified: TimeInterval) {
        var state = self.files[url.path] ?? FileState(size: 0, modified: 0, parsed: 0, rows: [])
        if size < state.parsed { state = FileState(size: 0, modified: 0, parsed: 0, rows: []) }
        defer {
            state.size = size
            state.modified = modified
            self.files[url.path] = state
        }
        guard size > state.parsed, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(state.parsed))
        guard let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex ... lastNewline]
        state.parsed += Int64(complete.count)
        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            autoreleasepool { self.ingest(Data(line), into: &state) }
        }
    }

    private static let tokenCount = Data("\"token_count\"".utf8)
    private static let turnContext = Data("\"turn_context\"".utf8)

    private func ingest(_ line: Data, into state: inout FileState) {
        let isTokens = line.range(of: Self.tokenCount) != nil
        guard isTokens || line.range(of: Self.turnContext) != nil,
              let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = root["payload"] as? [String: Any]
        else { return }

        if root["type"] as? String == "turn_context" {
            state.model = JSONValue.string(payload["model"]) ?? JSONValue.string(payload["model_name"])
            return
        }
        guard root["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let stamp = root["timestamp"] as? String, let timestampMs = Timestamp.parseMs(stamp)
        else { return }

        let last = Self.totals(info["last_token_usage"])
        let total = Self.totals(info["total_token_usage"])
        if let total, total == state.lastTotal { return } // Same running total re-emitted.
        var delta = last
        if delta == nil, let total {
            let previous = state.lastTotal ?? Totals()
            delta = Totals(input: max(0, total.input - previous.input),
                           cached: max(0, total.cached - previous.cached),
                           output: max(0, total.output - previous.output))
        }
        if let total { state.lastTotal = total }
        guard let usage = delta, usage.input + usage.output > 0 else { return }

        let model = state.model ?? JSONValue.string(info["model"]) ?? JSONValue.string(payload["model"]) ?? "unknown"
        let cached = min(usage.cached, usage.input)
        let cost = self.prices.price(for: Self.normalize(model))?.cost(
            input: usage.input - cached, output: usage.output, cacheRead: cached, cacheWrite: 0, cacheWrite1h: 0)
        state.rows.append(UsageRow(timestampMs: timestampMs, model: model, tokens: usage.input + usage.output, cost: cost, rank: 0))
    }

    /// `input_tokens` includes cached input; reasoning is part of `output_tokens`.
    private static func totals(_ value: Any?) -> Totals? {
        guard let usage = value as? [String: Any] else { return nil }
        let input = Int(JSONValue.number(usage["input_tokens"]) ?? 0)
        let cached = Int(max(JSONValue.number(usage["cached_input_tokens"]) ?? 0, JSONValue.number(usage["cache_read_input_tokens"]) ?? 0))
        let output = Int(JSONValue.number(usage["output_tokens"]) ?? 0)
        return Totals(input: max(0, input), cached: max(0, cached), output: max(0, output))
    }

    /// `openai/gpt-5.5-2026-01-01` → `gpt-5.5`.
    static func normalize(_ raw: String) -> String {
        var model = raw.trimmingCharacters(in: .whitespaces)
        if model.hasPrefix("openai/") { model.removeFirst("openai/".count) }
        if let range = model.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) { model.removeSubrange(range) }
        return model
    }
}

/// Codex plan limits from ChatGPT, with the sign-in the Codex CLI keeps in `~/.codex/auth.json`.
/// Never refreshed here: an expired sign-in waits for Codex to renew it.
public enum CodexLimits {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// The saved sign-in first (one request); when it's missing or lapsed, the Codex CLI itself,
    /// which also renews the sign-in (or reads one kept in the Keychain).
    public static func fetch() async throws(LimitsError) -> PlanLimits {
        do {
            return try await self.fetchDirect()
        } catch {
            guard error == .expired || error == .signedOut,
                  let limits = await CodexAppServer.shared.rateLimits()
            else { throw error }
            return limits
        }
    }

    static func fetchDirect() async throws(LimitsError) -> PlanLimits {
        let url = CodexHome.url().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw .signedOut }

        var token: String?
        var account: String?
        if let apiKey = JSONValue.string(json["OPENAI_API_KEY"]) {
            token = apiKey
        } else if let tokens = json["tokens"] as? [String: Any] {
            token = JSONValue.string(tokens["access_token"]) ?? JSONValue.string(tokens["accessToken"])
            account = JSONValue.string(tokens["account_id"]) ?? JSONValue.string(tokens["accountId"])
                ?? self.claims(JSONValue.string(tokens["id_token"])).flatMap(self.accountID)
                ?? self.claims(token).flatMap(self.accountID)
            if let expiry = self.claims(token).flatMap({ JSONValue.number($0["exp"]) }),
               Date(timeIntervalSince1970: expiry) < Date()
            {
                throw .expired
            }
        }
        guard let token else { throw .signedOut }
        var headers = ["Authorization": "Bearer \(token)", "User-Agent": "countyotokens"]
        if let account { headers["ChatGPT-Account-Id"] = account }
        let response = try await HTTP.json(self.endpoint, headers: headers)
        guard let limits = self.parse(response, now: Date()) else { throw .failed }
        return limits
    }

    static func parse(_ json: [String: Any], now: Date) -> PlanLimits? {
        func window(_ value: Any?, prefix: String) -> PlanLimits.Limit? {
            guard let entry = value as? [String: Any], let used = JSONValue.number(entry["used_percent"]) else { return nil }
            let seconds = JSONValue.number(entry["limit_window_seconds"])
            let (id, title): (String, String) = switch seconds.map(Int.init) {
            case 18_000: ("session", "Session")
            case 604_800: ("weekly", "Weekly")
            case let value?: ("\(value)", value % 86_400 == 0 ? "\(value / 86_400)-day" : "\(value / 3600)-hour")
            case nil: ("window", "Limit")
            }
            return .init(
                id: prefix.isEmpty ? id : "\(prefix)-\(id)",
                title: prefix.isEmpty ? title : "\(prefix) \(title.lowercased())",
                usedPercent: min(100, max(0, used)),
                resetsAt: JSONValue.number(entry["reset_at"]).map { Date(timeIntervalSince1970: $0) },
                duration: seconds)
        }
        func windows(_ rateLimit: Any?, prefix: String) -> [PlanLimits.Limit] {
            guard let rateLimit = rateLimit as? [String: Any] else { return [] }
            return [window(rateLimit["primary_window"], prefix: prefix), window(rateLimit["secondary_window"], prefix: prefix)]
                .compactMap(\.self)
                .sorted { ($0.duration ?? 0) < ($1.duration ?? 0) }
        }
        var items = windows(json["rate_limit"], prefix: "")
        for case let extra as [String: Any] in json["additional_rate_limits"] as? [Any] ?? [] {
            guard let name = JSONValue.string(extra["limit_name"]) ?? JSONValue.string(extra["metered_feature"]) else { continue }
            items += windows(extra["rate_limit"], prefix: name)
        }
        guard !items.isEmpty else { return nil }
        let plan = JSONValue.string(json["plan_type"]).map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        return PlanLimits(items: items, plan: plan, fetchedAt: now)
    }

    /// The JSON payload of a JWT, unverified (only used to read non-secret claims).
    static func claims(_ jwt: String?) -> [String: Any]? {
        let parts = jwt?.split(separator: ".") ?? []
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func accountID(_ claims: [String: Any]) -> String? {
        JSONValue.string(claims["chatgpt_account_id"])
            ?? JSONValue.string((claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"])
    }
}
