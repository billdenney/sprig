// LoggedCommand.swift
//
// Wire-stable record of a single `git` invocation. Produced by
// `Runner.run` when an attached `RunnerLog` is configured; consumed
// by the agent's "Commands" panel surface (ADR 0057).
//
// Tier-1 portable. Pure Foundation primitives; `Codable + Sendable +
// Equatable` so the record can travel through `IPCSchema` envelopes
// to task windows for live rendering.
//
// **Storage shape decisions:**
//
// - `argv` is the literal arguments passed to `Process` (resolved git
//   path is its first element, then user-supplied args). Captures
//   exactly what was run, suitable for direct user copy/paste.
// - `cwd` is a string, not a `URL`, so JSON encoding is portable
//   across POSIX and Windows path forms without `URL`'s
//   percent-encoding noise.
// - `stderrTail` is bounded — long stderr output (e.g. a `git fetch`
//   with verbose progress) shouldn't bloat the log. Truncated to
//   ``Self/stderrTailLimit`` characters; truncation appended marker.
// - `stdoutByteCount` records output size without storing the bytes,
//   so the panel can show "produced 1.2 MB of output" without keeping
//   it. Stdout is rarely useful to render in a Commands panel; if
//   debugging needs it, `sprigctl logs` reads the agent's full bundle.
// - `id: UUID` is the wire-correlation key. Subscribers that receive
//   the same record more than once (reconnect, replay) dedupe by `id`.

import Foundation

/// A single completed `git` invocation, captured for diagnostic and
/// UI surfaces (ADR 0057's "Commands" panel).
public struct LoggedCommand: Codable, Sendable, Equatable, Identifiable {
    /// Stable ring-buffer / wire identifier. Generated when the log
    /// records the entry.
    public var id: UUID

    /// Literal argv. First element is the resolved git executable
    /// path; subsequent elements are the arguments. Exactly what
    /// `Process` was invoked with.
    public var argv: [String]

    /// Working directory at invocation time (string form, since this
    /// crosses the IPC wire). Nil if the runner didn't set one (i.e.
    /// the child inherits the agent's cwd).
    public var cwd: String?

    /// When the runner spawned the process.
    public var startedAt: Date

    /// When the runner observed termination.
    public var finishedAt: Date

    /// Process exit code. 0 == success.
    public var exitCode: Int32

    /// Up to ``Self/stderrTailLimit`` characters of the captured
    /// stderr, with a truncation marker if longer. Nil if stderr was
    /// empty or wasn't captured.
    public var stderrTail: String?

    /// Total stdout bytes the process produced. Useful for "produced
    /// 1.2 MB" hover-tooltips without storing the bytes.
    public var stdoutByteCount: Int

    /// True when the process exited with a non-zero code or by signal.
    /// Convenience for UI styling.
    public var failed: Bool {
        exitCode != 0
    }

    /// Wall-clock duration. Equal to `finishedAt - startedAt`.
    public var duration: TimeInterval {
        finishedAt.timeIntervalSince(startedAt)
    }

    public init(
        id: UUID = UUID(),
        argv: [String],
        cwd: String? = nil,
        startedAt: Date,
        finishedAt: Date,
        exitCode: Int32,
        stderrTail: String? = nil,
        stdoutByteCount: Int = 0
    ) {
        self.id = id
        self.argv = argv
        self.cwd = cwd
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.stderrTail = stderrTail
        self.stdoutByteCount = stdoutByteCount
    }

    /// Maximum characters retained in ``stderrTail`` before truncation.
    /// Long stderr (e.g. `git fetch --progress` output) isn't useful
    /// in the Commands panel; the user can find it in agent logs.
    public static let stderrTailLimit: Int = 1000

    /// Truncate `stderr` to ``Self/stderrTailLimit`` characters,
    /// appending a `[…N more bytes]` marker when truncation occurred.
    /// Returns nil for empty input so callers store nil rather than
    /// an empty string.
    public static func truncateStderr(_ stderr: String) -> String? {
        if stderr.isEmpty { return nil }
        if stderr.count <= stderrTailLimit { return stderr }
        let cut = stderr.index(stderr.endIndex, offsetBy: -stderrTailLimit)
        let omitted = stderr.distance(from: stderr.startIndex, to: cut)
        return "[…\(omitted) more bytes elided] " + String(stderr[cut...])
    }
}
