import Foundation

/// Per-token USD rates for one model. Rates come from the models.dev `anthropic` catalog,
/// which is what the upstream app priced Claude logs with.
public struct ModelPrice: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    /// Prompt size (input + cache read + cache write) above which `above` rates apply.
    public var threshold: Int?
    public var above: Rates?

    public struct Rates: Codable, Sendable, Equatable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite: Double
    }

    /// Rates per million tokens, as models.dev publishes them.
    init(_ input: Double, _ output: Double, read: Double, write: Double, threshold: Int? = nil, above: Rates? = nil) {
        self.input = input / 1e6
        self.output = output / 1e6
        self.cacheRead = read / 1e6
        self.cacheWrite = write / 1e6
        self.threshold = threshold
        self.above = above.map { Rates(input: $0.input / 1e6, output: $0.output / 1e6,
                                      cacheRead: $0.cacheRead / 1e6, cacheWrite: $0.cacheWrite / 1e6) }
    }

    func cost(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int) -> Double {
        var rates = Rates(input: self.input, output: self.output, cacheRead: self.cacheRead, cacheWrite: self.cacheWrite)
        if let threshold, let above, input + cacheRead + cacheWrite > threshold { rates = above }
        let oneHour = min(max(0, cacheWrite1h), cacheWrite)
        // One-hour cache writes bill at twice the base input rate; five-minute writes at the cache-write rate.
        return Double(input) * rates.input
            + Double(cacheRead) * rates.cacheRead
            + Double(cacheWrite - oneHour) * rates.cacheWrite
            + Double(oneHour) * rates.input * 2
            + Double(output) * rates.output
    }
}

public struct PriceBook: Sendable {
    public private(set) var prices: [String: ModelPrice]

    public init(prices: [String: ModelPrice] = PriceBook.bundled) {
        self.prices = prices
    }

    public func price(for model: String) -> ModelPrice? {
        self.prices[model] ?? self.prices[Self.normalize(model)]
    }

    /// Strips Bedrock/Vertex decoration and dated suffixes so `anthropic.claude-opus-4-5-20251101-v1:0`
    /// and `claude-opus-4-5@20251101` price as `claude-opus-4-5`.
    public static func normalize(_ raw: String) -> String {
        var model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.hasPrefix("anthropic.") { model.removeFirst("anthropic.".count) }
        if let dot = model.lastIndex(of: "."), model[model.index(after: dot)...].hasPrefix("claude-") {
            model = String(model[model.index(after: dot)...])
        }
        if let at = model.firstIndex(of: "@") { model = String(model[..<at]) }
        if let range = model.range(of: #"-v\d+:\d+$"#, options: .regularExpression) { model.removeSubrange(range) }
        if let range = model.range(of: #"-\d{8}$"#, options: .regularExpression),
           PriceBook.bundled[String(model[..<range.lowerBound])] != nil
        {
            model.removeSubrange(range)
        }
        return model
    }

    /// Merges a newer models.dev catalog over the bundled snapshot.
    public mutating func overlay(_ newer: [String: ModelPrice]) {
        self.prices.merge(newer) { _, new in new }
    }

    // USD per million tokens.
    // models.dev `anthropic` provider, snapshot 2026-11-20.
    public static let bundled: [String: ModelPrice] = [
        "claude-fable-5": .init(10, 50, read: 1, write: 12.5),
        "claude-fable-5-1": .init(10, 50, read: 0.25, write: 12.5),
        "claude-fable-5-2": .init(8, 40, read: 0.2, write: 10),
        "claude-opus-5-5": .init(4, 20, read: 0.2, write: 5),
        "claude-opus-5": .init(5, 25, read: 0.5, write: 6.25),
        "claude-opus-4-8": .init(5, 25, read: 0.5, write: 6.25),
        "claude-opus-4-7": .init(5, 25, read: 0.5, write: 6.25),
        "claude-opus-4-6": .init(5, 25, read: 0.5, write: 6.25),
        "claude-opus-4-5": .init(5, 25, read: 0.5, write: 6.25),
        "claude-opus-4-1": .init(15, 75, read: 1.5, write: 18.75),
        "claude-opus-4": .init(15, 75, read: 1.5, write: 18.75),
        "claude-sonnet-5-5": .init(2, 10, read: 0.1, write: 2.5),
        "claude-sonnet-5": .init(2, 10, read: 0.2, write: 2.5),
        "claude-sonnet-4-6": .init(3, 15, read: 0.3, write: 3.75),
        "claude-sonnet-4-5": .init(3, 15, read: 0.3, write: 3.75),
        "claude-sonnet-4": .init(3, 15, read: 0.3, write: 3.75),
        "claude-haiku-5-5": .init(0.1, 0.5, read: 0.01, write: 0.125, threshold: 100_000,
                                  above: .init(input: 0.5, output: 2.5, cacheRead: 0.05, cacheWrite: 0.625)),
        "claude-haiku-4-5": .init(1, 5, read: 0.1, write: 1.25),

        // models.dev `openai` provider, snapshot 2026-11-20. Long context above 272k input tokens.
        "gpt-5": .init(1.25, 10, read: 0.125, write: 1.25),
        "gpt-5-mini": .init(0.25, 2, read: 0.025, write: 0.25),
        "gpt-5.1": .init(1.25, 10, read: 0.125, write: 1.25),
        "gpt-5.2": .init(1.75, 14, read: 0.175, write: 1.75),
        "gpt-5.3-codex": .init(1.75, 14, read: 0.175, write: 1.75),
        "gpt-5.4": .init(2.5, 15, read: 0.25, write: 2.5, threshold: 272_000,
                         above: .init(input: 5, output: 22.5, cacheRead: 0.5, cacheWrite: 5)),
        "gpt-5.4-mini": .init(0.75, 4.5, read: 0.075, write: 0.75),
        "gpt-5.5": .init(5, 30, read: 0.5, write: 5, threshold: 272_000,
                         above: .init(input: 10, output: 45, cacheRead: 1, cacheWrite: 10)),
        "gpt-5.6": .init(4, 20, read: 0.4, write: 5, threshold: 272_000,
                         above: .init(input: 8, output: 30, cacheRead: 0.8, cacheWrite: 10)),
        "gpt-5.6-sol": .init(4, 20, read: 0.4, write: 5, threshold: 272_000,
                             above: .init(input: 8, output: 30, cacheRead: 0.8, cacheWrite: 10)),
        "gpt-5.6-terra": .init(2, 12, read: 0.2, write: 2.5, threshold: 272_000,
                               above: .init(input: 4, output: 18, cacheRead: 0.4, cacheWrite: 5)),
        "gpt-5.6-luna": .init(0.2, 1.2, read: 0.02, write: 0.25, threshold: 272_000,
                              above: .init(input: 0.4, output: 1.8, cacheRead: 0.04, cacheWrite: 0.5)),
        "gpt-6-sol": .init(2, 10, read: 0.2, write: 2.5, threshold: 272_000,
                           above: .init(input: 4, output: 15, cacheRead: 0.4, cacheWrite: 5)),
        "gpt-6.1-sol": .init(2, 10, read: 0.1, write: 2.5, threshold: 272_000,
                             above: .init(input: 4, output: 15, cacheRead: 0.2, cacheWrite: 5)),
        "gpt-6.2-sol": .init(2, 10, read: 0.1, write: 2.5, threshold: 272_000,
                             above: .init(input: 4, output: 15, cacheRead: 0.2, cacheWrite: 5)),
    ]
}

// MARK: - models.dev refresh

public enum PriceCatalog {
    static let endpoint = URL(string: "https://models.dev/api.json")!

    /// v2: Anthropic and OpenAI models (the first version held Anthropic only).
    public static var cacheURL: URL { AppPaths.support.appendingPathComponent("prices-v2.json") }

    /// Bundled rates overlaid with the last downloaded catalog, if any.
    public static func load() -> PriceBook {
        var book = PriceBook()
        if let data = try? Data(contentsOf: self.cacheURL),
           let cached = try? JSONDecoder().decode([String: ModelPrice].self, from: data)
        {
            book.overlay(cached)
        }
        return book
    }

    /// Downloads models.dev at most once a day so newly released models get priced.
    /// Returns nil when the cache is fresh or the download fails.
    public static func refreshIfStale(maxAge: TimeInterval = 86_400) async -> [String: ModelPrice]? {
        let modified = (try? self.cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let modified, Date().timeIntervalSince(modified) < maxAge { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: self.endpoint),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let prices = self.parse(data), !prices.isEmpty,
              let encoded = try? JSONEncoder().encode(prices)
        else { return nil }
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? encoded.write(to: self.cacheURL, options: .atomic)
        return prices
    }

    static func parse(_ data: Data) -> [String: ModelPrice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var prices: [String: ModelPrice] = [:]
        for name in ["openai", "anthropic"] {
            guard let models = (root[name] as? [String: Any])?["models"] as? [String: Any] else { continue }
            prices.merge(self.parse(models: models, preferTiers: name == "openai")) { _, new in new }
        }
        return prices.isEmpty ? nil : prices
    }

    /// OpenAI's long-context rates start at the tier's size (272k); its `context_over_200k` block is
    /// only a label. Anthropic keeps the reading this app has always used.
    static func parse(models: [String: Any], preferTiers: Bool) -> [String: ModelPrice] {
        var prices: [String: ModelPrice] = [:]
        for (id, value) in models {
            guard let cost = (value as? [String: Any])?["cost"] as? [String: Any],
                  let input = cost["input"] as? Double, let output = cost["output"] as? Double
            else { continue }
            let read = cost["cache_read"] as? Double ?? input
            let write = cost["cache_write"] as? Double ?? input
            var threshold: Int?
            var above: ModelPrice.Rates?
            let tier = (cost["tiers"] as? [[String: Any]])?.first {
                ($0["tier"] as? [String: Any])?["type"] as? String == "context"
            }
            if let over = preferTiers ? tier ?? cost["context_over_200k"] as? [String: Any]
                : cost["context_over_200k"] as? [String: Any] ?? tier
            {
                threshold = ((over["tier"] as? [String: Any])?["size"] as? Int) ?? 200_000
                above = .init(
                    input: over["input"] as? Double ?? input,
                    output: over["output"] as? Double ?? output,
                    cacheRead: over["cache_read"] as? Double ?? read,
                    cacheWrite: over["cache_write"] as? Double ?? write)
            }
            prices[id] = ModelPrice(input, output, read: read, write: write, threshold: threshold, above: above)
        }
        return prices
    }
}

public enum AppPaths {
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("countyotokens", isDirectory: true)
    }
}
