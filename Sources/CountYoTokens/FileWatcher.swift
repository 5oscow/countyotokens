import CoreServices
import Foundation

/// FSEvents on the log roots: a refresh fires within a second of Claude writing a line.
@MainActor
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(paths: [String], latency: CFTimeInterval = 0.75, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            nonisolated(unsafe) let pointer = info
            MainActor.assumeIsolated {
                Unmanaged<FileWatcher>.fromOpaque(pointer).takeUnretainedValue().onChange()
            }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
