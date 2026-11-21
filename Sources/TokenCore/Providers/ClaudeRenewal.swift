import Darwin
import Foundation

/// Gets Claude Code to renew its own expired sign-in, the way CodexBar does: start `claude` on a
/// private terminal in a folder of ours, type `/status`, and wait for its Keychain item to change.
/// Claude Code checks and renews its token itself, so we never touch the refresh token (rotating it
/// from here could sign Claude Code out), and no message is sent to a model.
actor ClaudeRenewal {
    static let shared = ClaudeRenewal()

    private var lastAttempt = Date.distantPast
    private var cooldown: TimeInterval = 0
    private var running: Task<Bool, Never>?

    /// True when the Keychain now holds a sign-in that hasn't expired.
    func renew() async -> Bool {
        if let running { return await running.value }
        guard Date().timeIntervalSince(self.lastAttempt) >= self.cooldown else { return false }
        self.lastAttempt = Date()
        let task = Task.detached(priority: .utility) { Self.attempt(timeout: 10) }
        self.running = task
        let renewed = await task.value
        self.running = nil
        // CodexBar's cooldowns: wait 5 minutes after a renewal, 20 seconds after a miss.
        self.cooldown = renewed ? 5 * 60 : 20
        return renewed
    }

    // MARK: The attempt

    private static func attempt(timeout: TimeInterval) -> Bool {
        guard let binary = self.claudeBinary() else { return false }
        let baseline = ClaudeLimits.keychainItem()
        guard let directory = try? self.probeDirectory() else { return false }
        defer { self.removeProbeTranscripts(directory) }

        var primary: Int32 = -1
        var secondary: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &secondary, nil, nil, &size) == 0 else { return false }
        _ = fcntl(primary, F_SETFL, O_NONBLOCK)
        let primaryHandle = FileHandle(fileDescriptor: primary, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
        defer {
            try? primaryHandle.close()
            try? secondaryHandle.close()
        }

        let process = Process()
        process.executableURL = binary
        // No tools, no MCP servers, no hooks, no Remote Control: this session only shows /status.
        process.arguments = [
            "--allowed-tools", "", "--strict-mcp-config",
            "--settings", #"{"remoteControlAtStartup":false,"disableAllHooks":true}"#,
        ]
        process.currentDirectoryURL = directory
        process.environment = self.environment(directory: directory)
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        do { try process.run() } catch { return false }
        let pid = process.processIdentifier
        let group: pid_t? = setpgid(pid, pid) == 0 || getpgid(pid) == pid ? pid : nil
        defer { self.stop(process, group: group) }

        let started = Date()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var screen = Screen()
        var trustSeenAt: Date?
        var trustAnsweredAt: Date?
        var lastKey = Date.distantPast
        var sentStatus = false
        while Date().timeIntervalSince(started) < timeout, process.isRunning {
            // Keep the terminal drained so Claude Code never blocks on a full buffer.
            while true {
                let count = read(primary, &buffer, buffer.count)
                guard count > 0 else { break }
                screen.append(buffer[0 ..< count])
            }
            if self.renewed(from: baseline) { return true }
            let now = Date()
            if trustAnsweredAt == nil, screen.showsTrustQuestion {
                // Claude Code asks once whether to trust a new folder, with "No, exit" selected. Answer
                // Yes for our own folder, only once Yes is actually highlighted.
                let seen = trustSeenAt ?? now
                trustSeenAt = seen
                if screen.trustYesSelected, now.timeIntervalSince(lastKey) > 0.3 {
                    self.write(primary, "\r")
                    trustAnsweredAt = now
                    lastKey = now
                    screen.clear()
                } else if !screen.trustYesSelected, now.timeIntervalSince(seen) > 0.6, now.timeIntervalSince(lastKey) > 0.5 {
                    self.write(primary, "\u{1b}[B")
                    lastKey = now
                }
            } else if !sentStatus {
                let ready = trustAnsweredAt.map { now.timeIntervalSince($0) > 1.5 }
                    ?? (trustSeenAt == nil && now.timeIntervalSince(started) > 2.5)
                if ready {
                    self.write(primary, "/status\r")
                    sentStatus = true
                    lastKey = now
                }
            } else if now.timeIntervalSince(lastKey) >= 0.8, !screen.showsTrustQuestion {
                // CodexBar presses Enter every 0.8 s to keep /status moving.
                self.write(primary, "\r")
                lastKey = now
            }
            usleep(100_000)
        }
        // The item can land just as the process exits.
        for _ in 0 ..< 10 {
            if self.renewed(from: baseline) { return true }
            usleep(200_000)
        }
        return false
    }

    /// The terminal's recent output with escape codes and whitespace removed, lowercased.
    struct Screen {
        private var bytes: [UInt8] = []

        mutating func append(_ chunk: ArraySlice<UInt8>) {
            self.bytes.append(contentsOf: chunk)
            if self.bytes.count > 24_000 { self.bytes.removeFirst(self.bytes.count - 20_000) }
        }

        mutating func clear() { self.bytes.removeAll() }

        var text: String {
            var plain: [UInt8] = []
            var index = 0
            let bytes = self.bytes
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x1B, index + 1 < bytes.count {
                    let next = bytes[index + 1]
                    index += 2
                    if next == UInt8(ascii: "[") {
                        while index < bytes.count, !(0x40 ... 0x7E).contains(bytes[index]) { index += 1 }
                        index += 1
                    } else if next == UInt8(ascii: "]") {
                        while index < bytes.count, bytes[index] != 0x07, bytes[index] != 0x1B { index += 1 }
                        index += 1
                    }
                    continue
                }
                if byte > 0x20 { plain.append(byte) }
                index += 1
            }
            return String(decoding: plain, as: UTF8.self).lowercased()
        }

        var showsTrustQuestion: Bool { self.text.contains("yes,itrustthisfolder") }

        /// The last-drawn selection marker sits on the Yes option.
        var trustYesSelected: Bool {
            let text = self.text
            guard let marker = text.range(of: "❯", options: .backwards) else { return false }
            return text[marker.upperBound...].hasPrefix("yes,itrust")
        }
    }

    private static func renewed(from baseline: Data?) -> Bool {
        guard let data = ClaudeLimits.keychainItem(), data != baseline,
              let credentials = ClaudeLimits.parseCredentials(data)
        else { return false }
        return credentials.expiresAt.map { $0 > Date() } ?? true
    }

    private static func write(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    private static func stop(_ process: Process, group: pid_t?) {
        guard process.isRunning else { return }
        let target = group.map { -$0 } ?? process.processIdentifier
        kill(target, SIGTERM)
        for _ in 0 ..< 10 where process.isRunning { usleep(100_000) }
        if process.isRunning { kill(target, SIGKILL) }
    }

    // MARK: Setup

    /// Claude Code's own install places first, then the login PATH's usual homes.
    static func claudeBinary() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"] + path
        for directory in candidates {
            let file = URL(fileURLWithPath: directory).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: file.path) { return file.resolvingSymlinksInPath() }
        }
        return nil
    }

    private static func environment(directory: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ANTHROPIC_") }
        environment["PWD"] = directory.path
        environment["TERM"] = "xterm-256color"
        // A status check must never update the user's Claude Code install.
        environment["DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    /// Our own folder, so Claude Code's folder-trust answer and session files stay out of real projects.
    private static func probeDirectory() throws -> URL {
        let directory = AppPaths.support.appendingPathComponent("claude-probe", isDirectory: true)
        let settings = directory.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let file = settings.appendingPathComponent("settings.local.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data(#"{"disableDeepLinkRegistration":"disable"}"#.utf8).write(to: file, options: .atomic)
        }
        return directory
    }

    /// Claude Code files sessions under ~/.claude/projects/<folder path with every other character
    /// as "-">. Ours never hold anything worth keeping.
    private static func removeProbeTranscripts(_ directory: URL) {
        let name = String(directory.path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let folder = root.appendingPathComponent("projects").appendingPathComponent(name)
        guard folder.lastPathComponent.contains("claude-probe") else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
