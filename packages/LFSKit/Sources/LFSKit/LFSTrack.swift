// LFSTrack.swift
//
// ADR 0029/0091 — the "Track with LFS" write action behind the
// binaryTypeWithoutLFS / largeStagedFileWithoutLFS rail remedies and
// the document-store offer. Writes the LFS attribute for a pattern by
// running `git lfs track <pattern>` (which edits `.gitattributes`).
//
// Detect-don't-bundle (ADR 0029/0047): we probe for `git-lfs` on PATH
// first and refuse with a typed error if it's absent — never a silent
// install. `git lfs track` only edits `.gitattributes`; it does NOT run
// `git lfs install` (the global hook setup), so tracking is safe even
// before the smudge/clean filters are configured.
//
// Tier 1, portable. All git invocation routes through `GitCore.Runner`.

import Foundation
import GitCore

/// Errors from ``LFSTrack``.
public enum LFSTrackError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `git-lfs` is not on PATH. The caller should prompt the user to
    /// install it (ADR 0029), never install it silently.
    case gitLFSNotAvailable

    public var description: String {
        switch self {
        case .gitLFSNotAvailable:
            "git-lfs is not installed; install it to track files with LFS"
        }
    }
}

/// The "Track with LFS" action: probe, then `git lfs track <pattern>`.
public enum LFSTrack {
    /// Track `pattern` (a `.gitattributes`-style glob like `*.psd`) with
    /// Git LFS, writing the attribute into `.gitattributes`.
    ///
    /// - Throws: ``LFSTrackError/gitLFSNotAvailable`` when `git-lfs` is
    ///   absent (detect-and-prompt — the caller surfaces an install
    ///   prompt); ``GitError`` from the underlying `git lfs track`.
    public static func track(pattern: String, runner: Runner) async throws {
        let status = try await LFSInstall.probe(runner: runner)
        guard status.binaryAvailable else {
            throw LFSTrackError.gitLFSNotAvailable
        }
        _ = try await runner.run(["lfs", "track", pattern])
    }
}
