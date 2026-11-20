import Foundation

enum Timestamp {
    /// Parses `2026-11-20T18:59:53.123Z` without a formatter (hot path: one call per usage row).
    /// Falls back to ISO8601DateFormatter for offsets or unusual shapes.
    static func parseMs(_ text: String) -> Int64? {
        var text = text
        if let fast = text.withUTF8({ Self.fastParse($0) }) { return fast }
        return Self.slowParse(text)
    }

    private static func fastParse(_ b: UnsafeBufferPointer<UInt8>) -> Int64? {
        // YYYY-MM-DDTHH:MM:SS[.fff…]Z
        guard b.count >= 20, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A,
              b[b.count - 1] == 0x5A
        else { return nil }
        func num(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start ..< start + length {
                let digit = Int(b[index]) - 48
                guard digit >= 0, digit <= 9 else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
              (1 ... 12).contains(month), (1 ... 31).contains(day)
        else { return nil }
        var millis = 0
        if b[19] == 0x2E {
            var scale = 100
            var index = 20
            while index < b.count - 1 {
                let digit = Int(b[index]) - 48
                guard digit >= 0, digit <= 9 else { return nil }
                millis += digit * scale
                scale /= 10
                index += 1
            }
        } else if b.count != 20 {
            return nil
        }
        // Days from civil (Howard Hinnant).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = Int64(days) * 86400 + Int64(hour * 3600 + minute * 60 + second)
        return seconds * 1000 + Int64(millis)
    }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter = ISO8601DateFormatter()
    private static let formatterLock = NSLock()

    private static func slowParse(_ text: String) -> Int64? {
        self.formatterLock.withLock {
            guard let date = Self.formatter.date(from: text) ?? Self.plainFormatter.date(from: text) else { return nil }
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
    }
}
