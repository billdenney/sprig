// ExternalDiffTool.swift
//
// ADR 0086 C0 / ADR 0027 — the defer-to-git external-tool fallback for
// diffs and conflicts Sprig's built-in renderers can't handle (Office
// docs, unknown binaries). Rather than spawn a tool directly, we go
// through `git difftool` / `git mergetool`, so the user's configured
// `diff.tool`/`merge.tool`, per-repo `.gitattributes` `diff=`/`merge=`
// drivers, and tool discovery all ride git's native stacks (ADR 0023,
// CLAUDE.md rule 5 — all git via Runner).
//
// `--no-prompt` is the safety default: git launches the tool without an
// interactive "Launch X?" question (which would hang a headless run).
// The path is passed after `--` so it can never be read as an option.
// The tool mutates the working-tree file in place; the caller `git add`s
// the result for a merge.
//
// Tier 1, portable.

import Foundation

/// Launch the user's configured external diff / merge tool through git.
public enum ExternalDiffTool {
    /// argv for `git difftool` on one path. Exposed for tests.
    static func diffArguments(path: String, tool: String?) -> [String] {
        var args = ["difftool", "--no-prompt"]
        if let tool { args += ["--tool", tool] }
        args += ["--", path]
        return args
    }

    /// argv for `git mergetool` on one path. Exposed for tests.
    static func mergeArguments(path: String, tool: String?) -> [String] {
        var args = ["mergetool", "--no-prompt"]
        if let tool { args += ["--tool", tool] }
        args += ["--", path]
        return args
    }

    /// Open `path` in the configured (or named) external **diff** tool.
    /// Returns when the tool exits. Honors `diff.tool` /
    /// `.gitattributes diff=<driver>` via git.
    public static func launchDiff(path: String, tool: String? = nil, runner: Runner) async throws {
        _ = try await runner.run(diffArguments(path: path, tool: tool))
    }

    /// Open `path` in the configured (or named) external **merge** tool
    /// to resolve a conflict. The tool writes the resolved file in
    /// place; the caller stages it with `git add`. No-op when there is
    /// nothing to merge.
    public static func launchMerge(path: String, tool: String? = nil, runner: Runner) async throws {
        _ = try await runner.run(mergeArguments(path: path, tool: tool))
    }
}
