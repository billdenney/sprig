import ArgumentParser
import Foundation
import PlatformKit
import WatcherKit

/// `sprigctl watch <path> [--json] [--duration SECONDS]` — stream filesystem
/// events for a directory.
///
/// macOS uses ``WatcherKit/FSEventsWatcher``. Other platforms exit with a
/// friendly message until a portable watcher (polling or per-OS adapter) lands.
struct WatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Stream filesystem change events for a directory (macOS only today)."
    )

    @Flag(name: .long, help: "Emit JSON lines instead of a human-readable summary.")
    var json: Bool = false

    @Option(
        name: .long,
        help: "Stop after SECONDS. Omit to run until interrupted with Ctrl-C."
    )
    var duration: Double?

    @Argument(help: "Directory to watch (defaults to the current directory).")
    var path: String?

    func run() async throws {
        let rootURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)

        #if os(macOS)
            try await watch(root: rootURL, with: FSEventsWatcher())
        #else
            var err = StderrStream()
            print(
                "sprigctl watch requires macOS. A portable polling watcher is planned — see ADR 0048 / docs/architecture/fs-watching.md.",
                to: &err
            )
            throw ExitCode(2)
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
