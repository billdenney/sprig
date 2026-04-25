import ArgumentParser
import Foundation
import PlatformKit
import WatcherKit

/// `sprigctl watch <path> [--json] [--duration SECONDS] [--polling-interval SECS]`
/// — stream filesystem events for a directory.
///
/// On macOS, uses ``WatcherKit/FSEventsWatcher`` for kernel-level FSEvents
/// notifications. On Linux/Windows (or anywhere ``--polling`` is forced),
/// falls back to ``WatcherKit/PollingFileWatcher`` which rescans paths at
/// ``pollingInterval`` and diffs the snapshots.
struct WatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Stream filesystem change events for a directory."
    )

    @Flag(name: .long, help: "Emit JSON lines instead of a human-readable summary.")
    var json: Bool = false

    @Option(
        name: .long,
        help: "Stop after SECONDS. Omit to run until interrupted with Ctrl-C."
    )
    var duration: Double?

    @Flag(
        name: .long,
        help: "Force the portable polling watcher even on macOS (useful for network volumes)."
    )
    var polling: Bool = false

    @Option(
        name: .long,
        help: "Polling interval in seconds when the polling watcher is in use. Default 1.0."
    )
    var pollingInterval: Double = 1.0

    @Argument(help: "Directory to watch (defaults to the current directory).")
    var path: String?

    func run() async throws {
        let rootURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)

        #if os(macOS)
            if polling {
                try await watch(root: rootURL, with: PollingFileWatcher(pollInterval: pollingInterval))
            } else {
                try await watch(root: rootURL, with: FSEventsWatcher())
            }
        #else
            // Non-macOS: there's no FSEvents, so polling is the only option.
            try await watch(root: rootURL, with: PollingFileWatcher(pollInterval: pollingInterval))
        #endif
    }

    /// Drive an arbitrary ``FileWatcher`` — factored out so tests (and a
    /// future portable polling impl) can share the streaming + rendering
    /// path without duplicating it under an extra `#if`.
    func watch(root: URL, with watcher: some FileWatcher) async throws {
        let stream = watcher.start(paths: [root])

        // Auto-stop task, if --duration was passed.
        let stopTask: Task<Void, Never>? = duration.map { secs in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                await watcher.stop()
            }
        }
        defer { stopTask?.cancel() }

        if !json {
            var err = StderrStream()
            print("# watching: \(root.path)", to: &err)
        }

        for await event in stream {
            if json {
                try emitJSON(event)
            } else {
                emitHuman(event)
            }
        }

        stopTask?.cancel()
    }

    // MARK: rendering

    private func emitHuman(_ event: WatchEvent) {
        let kind = humanKind(event.kind)
        print("\(kind)  \(event.path.path)")
    }

    private func humanKind(_ kind: WatchEventKind) -> String {
        switch kind {
        case .created: "CREATE"
        case .modified: "MODIFY"
        case .removed: "REMOVE"
        case .renamed: "RENAME"
        case .overflow: "OVERFLOW"
        case .unknown: "UNKNOWN"
        }
    }

    private func emitJSON(_ event: WatchEvent) throws {
        let wire = WatchEventWire(event)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(wire)
        if let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    }
}

// MARK: - JSON wire format for events

private struct WatchEventWire: Encodable {
    let path: String
    let kind: String
    let timestamp: Date

    init(_ event: WatchEvent) {
        self.path = event.path.path
        self.kind = "\(event.kind)"
        self.timestamp = event.timestamp
    }
}
