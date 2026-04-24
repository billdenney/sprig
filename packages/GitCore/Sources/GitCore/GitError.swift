import Foundation

/// Errors thrown by ``Runner`` and its callers.
///
/// Designed for introspection: the raw `stderr` and exit code are preserved so
/// higher layers can decide to surface a friendly message, prompt the user, or
/// retry with different flags. See ``GitExitCode`` for known exit-code semantics.
public enum GitError: Error, Sendable, CustomStringConvertible {
    /// The git executable could not be located on disk or via PATH.
    /// See ADR 0047 for the detection + install bootstrap flow.
    case binaryNotFound(probedPath: String?)

    /// `git` exited with a non-zero status.
    case nonZeroExit(
        command: [String],
        exitCode: Int32,
        stderr: String,
        stdout: String
    )

    /// `git` was signalled (uncaught signal / abort / sigpipe).
    case signalled(command: [String], signal: Int32, stderr: String)

    /// The invocation exceeded its deadline.
    case timedOut(command: [String], afterSeconds: Double)

    /// Output parsing failed (e.g. malformed porcelain-v2 record).
    case parseFailure(context: String, rawSnippet: String)

    /// Some precondition wasn't met (e.g. cwd is not a git working tree).
    case precondition(String)

    public var description: String {
        switch self {
        case .binaryNotFound(let probed):
            return "git binary not found" + (probed.map { " (probed: \($0))" } ?? "")
        case .nonZeroExit(let cmd, let code, let stderr, _):
            return "git \(cmd.joined(separator: " ")) exited with code \(code): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .signalled(let cmd, let sig, _):
            return "git \(cmd.joined(separator: " ")) killed by signal \(sig)"
        case .timedOut(let cmd, let secs):
            return "git \(cmd.joined(separator: " ")) timed out after \(secs)s"
        case .parseFailure(let ctx, let snippet):
            return "parse failure in \(ctx): '\(snippet)'"
        case .precondition(let msg):
            return "precondition: \(msg)"
        }
    }
}
