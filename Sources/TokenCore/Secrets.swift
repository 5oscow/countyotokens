import Foundation

/// Credentials pasted into Settings (Devin token, Factory API key), kept in the login Keychain.
///
/// Items go through `/usr/bin/security`, the way Claude Code stores its own sign-in: the item then
/// trusts that tool rather than this app's signature, so an updated build (ad-hoc signed, new
/// identity every time) reads them back without a Keychain prompt. Values travel over stdin, never
/// on a command line where other processes could see them.
public enum Secrets {
    public enum Key: String, Sendable {
        case devinToken = "devin.token"
        case droidAPIKey = "droid.apiKey"
    }

    static let service = "com.sirrayi.countyotokens"

    public static func get(_ key: Key) -> String? {
        let output = self.run(["find-generic-password", "-s", self.service, "-a", key.rawValue, "-w"])
        return output.status == 0 ? JSONValue.string(String(data: output.data, encoding: .utf8)) : nil
    }

    /// Saves, or removes when `value` is empty. Returns false when the value can't be stored.
    @discardableResult
    public static func set(_ key: Key, _ value: String?) -> Bool {
        guard let value = JSONValue.string(value) else {
            _ = self.run(["delete-generic-password", "-s", self.service, "-a", key.rawValue])
            return true
        }
        // Tokens are printable ASCII without quotes or backslashes; anything else is a paste mistake.
        guard value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 && $0 != "\"" && $0 != "\\" }) else { return false }
        let command = "add-generic-password -U -s \"\(self.service)\" -a \"\(key.rawValue)\" -l \"count yo tokens\" -w \"\(value)\"\n"
        return self.run(["-i"], input: Data(command.utf8)).status == 0
    }

    private static func run(_ arguments: [String], input: Data? = nil) -> (status: Int32, data: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = stdin
        do { try process.run() } catch { return (-1, Data()) }
        if let input { stdin.fileHandleForWriting.write(input) }
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
