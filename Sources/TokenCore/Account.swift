import Foundation

/// Signed-in Claude account, read from Claude Code's own `~/.claude.json`.
/// No network, no Keychain.
public struct Account: Sendable, Equatable, Codable {
    public var email: String?
    public var plan: String?

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> Account? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0).appendingPathComponent(".claude.json") }
            ?? home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }
        let tier = account["userRateLimitTier"] as? String ?? account["organizationRateLimitTier"] as? String
        return Account(
            email: account["emailAddress"] as? String,
            plan: Self.planName(tier: tier, organizationType: account["organizationType"] as? String))
    }

    /// `default_claude_max_5x` → "Max 5x", `claude_pro` → "Pro".
    static func planName(tier: String?, organizationType: String?) -> String? {
        let source = (tier ?? organizationType ?? "").lowercased()
        if source.contains("max") {
            if let range = source.range(of: #"\d+x"#, options: .regularExpression) {
                return "Max \(source[range])"
            }
            return "Max"
        }
        if source.contains("pro") { return "Pro" }
        if source.contains("team") { return "Team" }
        if source.contains("enterprise") { return "Enterprise" }
        return nil
    }
}
