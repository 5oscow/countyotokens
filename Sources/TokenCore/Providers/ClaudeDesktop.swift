import CommonCrypto
import Foundation
import Security

/// The Claude desktop app's own sign-in, for Macs where Claude runs through the app rather than the
/// CLI. Sessions the app starts leave only a short-lived token in Claude Code's Keychain item (no
/// scopes, nothing the CLI will renew), so limits stall a few hours after the app launches. The app
/// itself stays signed in and keeps its tokens in `config.json`, encrypted the way every Electron
/// app does it: AES-128-CBC under a key in the Keychain item "Claude Safe Storage".
///
/// Reading that item asks the user (macOS's own prompt, naming this app), and macOS offers no
/// dependable way to try the read without the prompt. So the Keychain is only opened when the user
/// asked for it, or when this very build has been let in before (in the background: only once a
/// read has gone through unprompted); everything else runs on the token that last worked. Only an access token is taken, only to ask api.anthropic.com for usage; nothing
/// is renewed or written back.
public enum ClaudeDesktop {
    /// How far a fetch may go for the desktop app's sign-in.
    public enum Access: Sendable {
        /// Don't use it.
        case off
        /// Only the token that last worked: never opens the Keychain.
        case cachedOnly
        /// Opens the Keychain only if this build's last read went through without macOS asking,
        /// which is what Always Allow looks like from here (background refreshes).
        case ifSilent
        /// Opens the Keychain if this build has been let in before (the user opened the menu).
        case ifApproved
        /// The user just asked for it: macOS may show its Keychain prompt.
        case ask
    }

    enum Outcome {
        case tokens([String])
        /// No desktop app, or it's signed out.
        case unavailable
        /// The Keychain read needs the user's OK (or they said no).
        case needsApproval
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/config.json")
    }

    /// The desktop app has signed in on this Mac at some point.
    public static var isAvailable: Bool {
        guard let data = try? Data(contentsOf: self.configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return self.cacheKeys.contains { config[$0] is String }
    }

    private static let cacheKeys = ["oauth:tokenCacheV2", "oauth:tokenCache"]

    /// Access tokens the desktop app holds that haven't expired, most promising first.
    static func accessTokens(_ access: Access, now: Date = Date()) -> Outcome {
        guard let data = try? Data(contentsOf: self.configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unavailable }
        let caches = self.cacheKeys.compactMap { (config[$0] as? String).flatMap { Data(base64Encoded: $0) } }
        guard !caches.isEmpty else { return .unavailable }
        let mayRead = switch access {
        case .ask: true
        case .ifApproved: self.isApproved
        case .ifSilent: self.isApproved && self.readsSilently
        case .off, .cachedOnly: false
        }
        let started = Date()
        guard mayRead, let password = self.safeStoragePassword() else {
            // Refused, or the prompt was dismissed: nothing in the background until it's allowed.
            if mayRead { UserDefaults.standard.removeObject(forKey: self.silentKey) }
            return .needsApproval
        }
        UserDefaults.standard.set(self.buildID, forKey: self.approvedKey)
        // A prompt takes a person seconds; a read macOS lets straight through takes milliseconds.
        if Date().timeIntervalSince(started) < 0.5 {
            UserDefaults.standard.set(self.buildID, forKey: self.silentKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.silentKey)
        }
        var found: [Candidate] = []
        for cache in caches {
            guard let plain = self.decrypt(cache, password: password),
                  let json = try? JSONSerialization.jsonObject(with: plain, options: [.fragmentsAllowed])
            else { continue }
            self.collect(json, path: "", into: &found)
        }
        let live = found.filter { $0.expiry.map { $0 > now.addingTimeInterval(30) } ?? true }
        // The usage endpoint wants the profile scope; after that, whichever lasts longest.
        let ranked = live.sorted { one, other in
            if one.hasProfileScope != other.hasProfileScope { return one.hasProfileScope }
            return (one.expiry ?? .distantFuture) > (other.expiry ?? .distantFuture)
        }
        var seen = Set<String>()
        let tokens = ranked.map(\.token).filter { seen.insert($0).inserted }
        return tokens.isEmpty ? .unavailable : .tokens(tokens)
    }

    /// What a fetch would find, without the tokens themselves (tokbench).
    public static func describe(_ access: Access) -> String {
        switch self.accessTokens(access) {
        case .unavailable: "no desktop sign-in found"
        case .needsApproval: "the Keychain read needs approving"
        case let .tokens(tokens): "\(tokens.count) usable token(s)"
        }
    }

    /// Decrypts a cache blob with a known password and lists what it holds (tokbench's self-check).
    public static func describe(cache: Data, password: Data) -> [String] {
        guard let plain = self.decrypt(cache, password: password),
              let json = try? JSONSerialization.jsonObject(with: plain, options: [.fragmentsAllowed])
        else { return ["could not decrypt"] }
        var found: [Candidate] = []
        self.collect(json, path: "", into: &found)
        return found.map { "token …\($0.token.suffix(4)) expiry \($0.expiry.map { "\($0)" } ?? "none") profile \($0.hasProfileScope)" }.sorted()
    }

    // MARK: Token cache

    struct Candidate {
        var token: String
        var expiry: Date?
        var hasProfileScope: Bool
    }

    /// The cache's layout is the desktop app's business and has changed before (V1, V2), so this
    /// doesn't depend on it: any object holding an OAuth access token counts, with whatever expiry
    /// and scope sit beside it or in the keys leading to it.
    static func collect(_ value: Any, path: String, into found: inout [Candidate]) {
        if let object = value as? [String: Any] {
            let strings = object.compactMapValues { $0 as? String }
            if let token = strings.values.first(where: { $0.hasPrefix("sk-ant-oat") }) {
                let expiry = object.first { $0.key.lowercased().contains("expir") }.flatMap { self.date($0.value) }
                let scopes = object.filter { $0.key.lowercased().contains("scope") }.map { "\($0.value)" }.joined(separator: " ")
                found.append(Candidate(token: token, expiry: expiry, hasProfileScope: (path + " " + scopes).contains("user:profile")))
            }
            for (key, child) in object { self.collect(child, path: path + " " + key, into: &found) }
        } else if let array = value as? [Any] {
            for child in array { self.collect(child, path: path, into: &found) }
        } else if let string = value as? String, string.hasPrefix("{") || string.hasPrefix("["),
                  let nested = try? JSONSerialization.jsonObject(with: Data(string.utf8))
        {
            // A JSON document stored as a string.
            self.collect(nested, path: path, into: &found)
        }
    }

    /// Unix seconds or milliseconds, or an ISO 8601 string.
    private static func date(_ value: Any) -> Date? {
        if let string = value as? String, let number = Double(string) {
            return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        }
        return JSONValue.date(value)
    }

    // MARK: Electron safeStorage

    /// `v10` + AES-128-CBC, key = PBKDF2-SHA1(password, "saltysalt", 1003 rounds), IV = 16 spaces.
    static func decrypt(_ blob: Data, password: Data) -> Data? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let cipher = blob.dropFirst(3)
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derived = password.withUnsafeBytes { bytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.bindMemory(to: CChar.self).baseAddress, password.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var plain = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var length = 0
        let status = cipher.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, bytes.baseAddress, cipher.count, &plain, plain.count, &length)
        }
        return status == kCCSuccess ? Data(plain.prefix(length)) : nil
    }

    /// The key Electron keeps for the desktop app. Read in-process, so macOS names this app in its
    /// prompt and remembers Always Allow for this build of it alone.
    private static func safeStoragePassword() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, !data.isEmpty
        else { return nil }
        return data
    }

    // MARK: Approval

    private static let approvedKey = "claudeDesktop.approvedBuild"

    /// This build has read the Keychain item before. macOS ties Always Allow to the exact build, so
    /// an update starts over (and must be asked for again, never sprung on the user).
    public static var isApproved: Bool { UserDefaults.standard.string(forKey: self.approvedKey) == self.buildID }

    private static let silentKey = "claudeDesktop.silentBuild"

    /// This build's last read needed no prompt, so one from the background won't raise one either.
    static var readsSilently: Bool { UserDefaults.standard.string(forKey: self.silentKey) == self.buildID }

    private static let buildID: String = {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(Int(modified))-\(attributes?[.size] as? Int ?? 0)"
    }()
}
