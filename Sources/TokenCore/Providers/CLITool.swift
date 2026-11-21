import Foundation

/// Finds provider CLIs the way a login shell would, from an app launched with a bare PATH.
enum CLITool {
    /// Where CLIs get installed: their own installers' homes, then Homebrew and npm, then PATH.
    static var searchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
                 "/opt/homebrew/bin", "/usr/local/bin"] + path)
            .filter { seen.insert($0).inserted }
    }

    static func find(_ name: String) -> URL? {
        for directory in self.searchPath {
            let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }

    /// Our environment with the search path, so a CLI that is a Node script finds `node`.
    static func environment(removing prefix: String? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let prefix { environment = environment.filter { !$0.key.hasPrefix(prefix) } }
        environment["PATH"] = self.searchPath.joined(separator: ":")
        return environment
    }
}
