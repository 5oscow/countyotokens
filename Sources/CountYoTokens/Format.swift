import Foundation

enum Format {
    private static let cents: FloatingPointFormatStyle<Double>.Currency =
        .currency(code: "USD").precision(.fractionLength(2)).locale(Locale(identifier: "en_US"))
    private static let dollars: FloatingPointFormatStyle<Double>.Currency =
        .currency(code: "USD").precision(.fractionLength(0)).locale(Locale(identifier: "en_US"))

    /// `$152.36`, `$1,052.07`.
    static func money(_ value: Double) -> String { value.formatted(self.cents) }

    /// `$6,166`: whole dollars for multi-day totals, where cents are noise.
    static func wholeMoney(_ value: Double) -> String {
        value > 0 && value < 1 ? self.money(value) : value.rounded().formatted(self.dollars)
    }

    /// Three significant digits: `980`, `12.3K`, `166M`, `2.72B`, `15.4B`.
    static func tokens(_ value: Int) -> String {
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        let number = Double(value)
        for (scale, suffix) in units where number >= scale * 0.9995 {
            let scaled = number / scale
            let digits = scaled >= 99.95 ? 0 : scaled >= 9.995 ? 1 : 2
            return String(format: "%.\(digits)f", scaled) + suffix
        }
        return "\(value)"
    }

    /// `claude-opus-5-5` → `Opus 5.5`; `gpt-5.5-codex` → `GPT-5.5 Codex`; `deepseek-v4.1-flash` → `DeepSeek V4.1 Flash`.
    static func model(_ id: String) -> String {
        // `provider/model` ids keep only the model; brands keep their own capitals.
        let brands = ["deepseek": "DeepSeek", "glm": "GLM", "minimax": "MiniMax", "qwen": "Qwen", "kimi": "Kimi",
                      "gemini": "Gemini", "grok": "Grok", "gpt": "GPT", "oss": "OSS"]
        func words(_ parts: some Sequence<Substring>) -> [String] {
            parts.map { brands[$0.lowercased()] ?? $0.prefix(1).uppercased() + $0.dropFirst() }
        }
        let name = id.split(separator: "/").last.map(String.init) ?? id
        if name.lowercased().hasPrefix("gpt-") {
            // `GPT-5.5` stays hyphenated; anything after it is words.
            let parts = name.split(separator: "-").dropFirst()
            guard let version = parts.first else { return "GPT" }
            return (["GPT-" + words([version])[0]] + words(parts.dropFirst())).joined(separator: " ")
        }
        guard name.hasPrefix("claude-") else { return words(name.split(separator: "-")).joined(separator: " ") }
        var parts = name.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return name }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count < 3 }
        return ([family.capitalized] + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
    }

    /// `14–21 Nov`, `31 Oct – 7 Nov` (or `Nov 14 – 21` in US English). Ends are shown inclusive.
    static func range(_ start: Date, _ end: Date) -> String {
        (start ..< max(start, end.addingTimeInterval(-1))).formatted(.interval.month(.abbreviated).day())
    }

    static func day(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

    /// `8h 2m`, `2d 5h`, `14m`.
    static func countdown(to date: Date, from now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(max(1, minutes))m"
    }

    /// `resets in 2h 5m`, or with the clock style `resets 14:30`, `resets Fri 09:00`, `resets 2 Dec`.
    static func reset(_ date: Date, now: Date, style: ResetStyle, verb: String = "resets") -> String {
        switch style {
        case .countdown:
            return "\(verb) in \(self.countdown(to: date, from: now))"
        case .clock:
            let calendar = Calendar.current
            let time = date.formatted(date: .omitted, time: .shortened)
            if calendar.isDate(date, inSameDayAs: now) { return "\(verb) \(time)" }
            if date.timeIntervalSince(now) < 6 * 86_400 {
                return "\(verb) \(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
            }
            return "\(verb) \(date.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }

    /// `18:47` today, `Sat 18:47` this week, `2 Nov` before that.
    static func asOf(_ date: Date, now: Date = Date()) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDate(date, inSameDayAs: now) { return time }
        if now.timeIntervalSince(date) < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func updated(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not scanned yet" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Updated just now" }
        if seconds < 3600 { return "Updated \(Int(seconds / 60)) min ago" }
        return "Updated " + date.formatted(date: .omitted, time: .shortened)
    }
}
