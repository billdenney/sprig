// AgentCommand.swift
//
// `sprigctl agent` — runs the single-process `RepoAgent` host against
// one repo and prints `Envelope<AgentEvent>`s as JSON-per-line on
// stdout. Useful both as a developer-facing diagnostic ("does my
// pipeline produce the badge events I expect?") and as the substrate
// the integration tests drive programmatically.
//
// `#if os(macOS)` for FSEvents lives only here in the CLI consumer;
// `AgentKit.RepoAgent` itself is `#if`-free per CLAUDE.md tier rules.

import AgentKit
import ArgumentParser
import Foundation
import GitCore
import IPCSchema
import PlatformKit
import RepoState
import WatcherKit

/// `sprigctl agent <path> [--polling] [--polling-interval SECS] [--duration SECS]`
/// — start a `RepoAgent` against the repo at `<path>` and print every
/// `AgentEvent` envelope it produces.
///
/// One JSON envelope per line on stdout; warnings on stderr.
struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Run the single-process RepoAgent and stream AgentEvents to stdout."
    )

    @Argument(help: "Repository worktree root (defaults to the current directory).")
    var path: String?

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

    @Option(
        name: .long,
        help: "Stop after SECONDS. Omit to run until interrupted with Ctrl-C."
    )
    var duration: Double?

    @Option(
        name: .long,
        help: "Print one `# stats: {…}` JSON line on stderr every SECONDS. 0 (default) disables."
    )
    var statsInterval: Double = 0

    func run() async throws {
        let rootURL = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
            .standardized

        // Resolve the gitDir up front so the agent knows what's a
        // ".git/-internal lock-or-temp" event when filtering. ADR 0056
        // says nil-on-failure is acceptable; the driver's filter is
        // conservative without it.
        let gitDir: URL? = try? GitMetadataPaths.resolveGitDir(forWorktree: rootURL)

        let runner = Runner(defaultWorkingDirectory: rootURL)
        let gitVersion: GitVersion? = try? await runner.version()

        let watcher: any FileWatcher = makeWatcher()
        let registry = SubscriptionRegistry()
        let sink = InMemoryBadgeEventSink()

        let agent = RepoAgent(
            repoRoot: rootURL,
            gitDir: gitDir,
            gitVersion: gitVersion,
            runner: runner,
            watcher: watcher,
            registry: registry,
            sink: sink
        )

        // Subscribe the CLI's own consumer to the worktree root so the
        // broadcaster has a destination for events. Production hosts
        // (macOS LaunchAgent, Windows Service) do this once per inbound
        // IPC client; here it's a single self-subscription.
        _ = await registry.subscribe(roots: [rootURL])

        // Optional auto-stop. Mirrors `sprigctl watch`'s --duration.
        let stopTask: Task<Void, Never>? = duration.map { secs in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                await agent.stop()
                sink.finish()
            }
        }
        defer { stopTask?.cancel() }

        // Optional periodic stats printer. Reads diagnostics from the
        // agent (passthroughs to `RepoRefreshDriver`) and writes one
        // JSON line per tick to stderr. Cancelled by `defer` when the
        // command exits — doesn't need its own coordination with the
        // sink shutdown.
        let statsTask: Task<Void, Never>? = makeStatsTask(
            interval: statsInterval,
            agent: agent
        )
        defer { statsTask?.cancel() }

        var err = StderrStream()
        print("# agent: watching \(rootURL.path)", to: &err)

        try await agent.start()

        // Drain the sink's stream; one JSON envelope per line.
        // Writes go through `StdoutStream` rather than the default
        // `print()` path so the line terminator is LF on every
        // platform — Swift's default stdout writer applies text-mode
        // FILE * translation on Windows, turning "\n" into "\r\n",
        // which is unconventional for streaming-JSON tooling and
        // surprises downstream consumers that split on "\n".
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var out = StdoutStream()
        for await envelope in sink.events {
            let data = try encoder.encode(envelope)
            if let line = String(data: data, encoding: .utf8) {
                print(line, to: &out)
            }
        }
    }

    /// Spawn a periodic stats printer if `interval > 0`. Returns nil
    /// when stats are disabled, so the caller can `task?.cancel()` in
    /// the defer without checking.
    private func makeStatsTask(
        interval: Double,
        agent: RepoAgent
    ) -> Task<Void, Never>? {
        guard interval > 0 else { return nil }
        let nanos = UInt64(interval * 1_000_000_000)
        return Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                let line = await Self.formatStats(for: agent)
                var err = StderrStream()
                print("# stats: \(line)", to: &err)
            }
        }
    }

    /// Render the agent's current diagnostics as a single-line JSON
    /// blob suitable for "# stats: …" stderr emission.
    private static func formatStats(for agent: RepoAgent) async -> String {
        let attempts = await agent.refreshAttempts()
        let outcome = await agent.lastOutcome()
        let firstDeferral = await agent.firstDeferralAt()
        let wire = StatsWire(
            refreshes: attempts,
            outcome: StatsWire.kind(of: outcome),
            entryCount: StatsWire.entryCount(of: outcome),
            firstDeferralAt: firstDeferral
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(wire),
              let line = String(data: data, encoding: .utf8)
        else { return "{}" }
        return line
    }

    private func makeWatcher() -> any FileWatcher {
        #if os(macOS)
            if polling {
                return PollingFileWatcher(pollInterval: pollingInterval)
            } else {
                return FSEventsWatcher()
            }
        #else
            // Non-macOS: there's no FSEvents, so polling is the only option.
            // The `polling` flag is effectively always-on here; we still
            // honor `--polling-interval` for tuning.
            return PollingFileWatcher(pollInterval: pollingInterval)
        #endif
    }
}

// MARK: - Stats wire format

/// One stats line's payload. Wire shape:
/// ```
/// # stats: {"entryCount":N,"firstDeferralAt":null,"outcome":"applied","refreshes":N}
/// ```
/// Sorted keys + ISO-8601 dates so log greps stay deterministic.
private struct StatsWire: Encodable {
    var refreshes: Int
    /// `"applied"`, `"deferred"`, `"failed"`, or `null` before any
    /// refresh has run. Wire-stable strings; clients pattern-match.
    var outcome: String?
    /// Trie-size from the most recent `.applied` outcome. Nil unless
    /// `outcome == "applied"` — `null` for "no refresh yet" /
    /// "deferred" / "failed".
    var entryCount: Int?
    /// First deferral timestamp; nil when no deferral is pending.
    var firstDeferralAt: Date?

    static func kind(of outcome: RefreshOutcome?) -> String? {
        guard let outcome else { return nil }
        return switch outcome {
        case .applied: "applied"
        case .deferred: "deferred"
        case .failed: "failed"
        }
    }

    static func entryCount(of outcome: RefreshOutcome?) -> Int? {
        guard case let .applied(entryCount, _) = outcome else { return nil }
        return entryCount
    }
}
