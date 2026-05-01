// GitMetadataPaths.swift
//
// Utilities for watching `.git/` so Sprig refreshes badges when a
// **different** git agent modifies repo state — terminal `git
// commit`, another GUI, a hook, a CI system on the same machine,
// etc. Without these, Sprig only sees worktree-file changes and
// misses commits (which leave the worktree byte-identical).
//
// Tier 1 portable. Pure file-system + path math; no platform APIs.
//
// Two responsibilities:
//
// 1. **Resolve** the actual git directory for a worktree. The naive
//    case is `<worktree>/.git/` is a directory. But for **submodules**
//    (each one's `.git` is a file pointing to
//    `<super-repo>/.git/modules/<name>/`) and **linked worktrees**
//    (`git worktree add` creates `<linked>/.git` as a file pointing
//    to `<original>/.git/worktrees/<name>/`), the `.git` is a TEXT
//    FILE with `gitdir: <path>`. We follow the pointer.
//
// 2. **Filter lock/temp** files so the watcher's events don't trigger
//    spurious refreshes. Git uses an atomic write-rename pattern
//    (`<file>.lock` → rename to `<file>`) for index, refs, and
//    packed-refs updates. Each operation emits 2-3 watcher events;
//    only the final rename matters to a status query. Pack writes
//    use `objects/pack/tmp_*` temp names.
//
// **Version-aware hook.** The lock-file patterns and the storage
// layout (loose-refs vs reftable) evolve between git versions.
// Currently the implementation handles git ≥ 2.39 (Sprig's floor per
// ADR 0047), with the reftable format from 2.45+ already
// auto-detected via `<gitDir>/reftable/` presence. The
// `gitVersion: GitVersion?` parameter on filter helpers is plumbed
// for future divergent logic; today it's accepted-but-ignored.
//
// Submodule recursion (and nested submodules) is a deliberate
// follow-up — `submoduleWorktrees(at:runner:)` will land in a sibling
// PR. This PR's resolveGitDir already handles each individual
// submodule's `.git` file, so the follow-up is purely "discover all
// of them and call this for each."

import Foundation

public enum GitMetadataPaths {
    /// The actual git directory for `worktreeURL`'s worktree.
    ///
    /// Handles three shapes:
    ///
    /// - `<worktree>/.git` is a **directory**: returns it.
    /// - `<worktree>/.git` is a **file** containing `gitdir: <path>`:
    ///   reads the pointer and returns the resolved path. Both
    ///   relative-to-worktree and absolute pointers are supported.
    /// - `<worktree>/.git` is **missing**: throws
    ///   ``GitError/binaryNotFound`` shaped like... actually no,
    ///   throws ``ResolveError/notARepository``.
    public static func resolveGitDir(forWorktree worktreeURL: URL) throws -> URL {
        let worktree = worktreeURL.standardized
        let dotGit = worktree.appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            throw ResolveError.notARepository(worktree: worktree)
        }

        if isDirectory.boolValue {
            return dotGit.standardized
        }

        // `.git` is a file. Parse `gitdir: <path>`.
        let raw: String
        do {
            raw = try String(contentsOf: dotGit, encoding: .utf8)
        } catch {
            throw ResolveError.gitdirPointerUnreadable(at: dotGit, underlying: error)
        }

        guard let pointerLine = raw
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix("gitdir:") })
        else {
            throw ResolveError.gitdirPointerMalformed(at: dotGit, content: raw)
        }

        let target = pointerLine
            .dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespaces)

        guard !target.isEmpty else {
            throw ResolveError.gitdirPointerMalformed(at: dotGit, content: raw)
        }

        // Per gitrepository-layout(7), gitdir paths can be relative
        // (resolved against the worktree) or absolute. We don't follow
        // a chain of pointers — git's docs say nested gitdir pointers
        // aren't supported, so the resolved target is the final dir.
        let pointerURL = URL(fileURLWithPath: target, relativeTo: worktree).standardized

        // Sanity: the resolved dir should exist. If it doesn't, the
        // worktree is broken (submodule-not-initialized, linked-worktree
        // pruned, etc.). Surface a typed error so callers can decide
        // whether to skip or warn.
        var resolvedIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pointerURL.path, isDirectory: &resolvedIsDirectory),
              resolvedIsDirectory.boolValue
        else {
            throw ResolveError.gitdirPointerTargetMissing(
                at: dotGit,
                target: pointerURL
            )
        }

        return pointerURL
    }

    /// True if `path` (somewhere within `gitDir`) is a git-managed
    /// lock file or transient temp file whose modification doesn't
    /// indicate a state change a status query should see.
    ///
    /// Filtering rules:
    /// - **`*.lock`** anywhere — `index.lock`, `HEAD.lock`,
    ///   `refs/heads/main.lock`, `packed-refs.lock`, etc. Git's
    ///   atomic write-rename pattern creates these for ≤ 100 ms
    ///   per write; the final rename to the non-`.lock` name is
    ///   the event that matters.
    /// - **`objects/pack/tmp_*`** and **`objects/pack/.tmp-*`** —
    ///   pack-write temps from `git fetch` / `git gc` / `git
    ///   repack`. Renamed to `pack-<sha>.pack` on success.
    /// - **`objects/incoming-*/`** — fetch staging directory in
    ///   git ≥ 2.40. Contents move into `objects/pack/` on success.
    /// - **`gc.pid`**, **`shallow.lock`**, **`commondir.lock`**
    ///   and other named lockfiles already captured by the `.lock`
    ///   suffix rule.
    ///
    /// `gitVersion` is plumbed for future divergent rules (e.g. if
    /// git 3.x changes the temp-file layout); today it's ignored.
    public static func isLockOrTempPath(
        _ path: URL,
        in gitDir: URL,
        gitVersion: GitVersion? = nil
    ) -> Bool {
        _ = gitVersion // reserved for future version-conditioned rules
        let resolvedPath = path.standardized.path
        let gitDirPath = gitDir.standardized.path

        // Only filter paths that are actually inside the git dir. A
        // worktree-side `*.lock` from the user's editor is a real
        // event we want to surface.
        guard resolvedPath.hasPrefix(gitDirPath) else { return false }

        // Trim the gitDir prefix to get the relative path inside.
        let relative = String(resolvedPath.dropFirst(gitDirPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lastComponent = (relative as NSString).lastPathComponent

        // Rule 1: anything ending in `.lock`.
        if lastComponent.hasSuffix(".lock") {
            return true
        }

        // Rule 2: pack-write temp files. Git 2.x uses `tmp_pack_*`,
        // `.tmp-*-pack` and similar; the leading `tmp_` / `.tmp-`
        // is the stable signal.
        if relative.hasPrefix("objects/pack/") {
            if lastComponent.hasPrefix("tmp_") || lastComponent.hasPrefix(".tmp-") {
                return true
            }
        }

        // Rule 3: fetch staging directory (git 2.40+).
        if relative.hasPrefix("objects/incoming-") {
            return true
        }

        return false
    }

    /// True iff a `*.lock` file exists at one of the canonical critical
    /// locations inside `gitDir`, indicating that **some git agent is
    /// currently mutating repo state**.
    ///
    /// Critical locations checked:
    /// - `index.lock` — `git add`, `git rm`, `git commit`, etc.
    /// - `HEAD.lock` — branch checkouts and detached-HEAD ops
    /// - `packed-refs.lock` — `git gc`, `git pack-refs`, branch deletes
    ///   that touch a packed ref
    /// - `config.lock` — `git config` writes
    /// - `shallow.lock` — fetch/clone of shallow repos
    ///
    /// **Why this matters.** Watcher events fire as git rewrites refs
    /// and the index. Querying `git status` mid-operation observes
    /// inconsistent state — the index hasn't caught up to the new ref
    /// tip, etc. The agent's event coalescer uses this signal to
    /// **defer** status refreshes until the lock disappears.
    /// Typical lock duration: <100 ms; we re-check on the next tick.
    ///
    /// We deliberately don't walk `refs/**/*.lock` — those locks are
    /// shorter-lived and end up filtered by ``isLockOrTempPath(_:in:gitVersion:)``
    /// at the per-event layer anyway. The four/five top-level locks
    /// catch the disruptive operations.
    ///
    /// `gitVersion` reserved for future divergent rules; ignored today.
    public static func gitOperationInFlight(
        in gitDir: URL,
        gitVersion: GitVersion? = nil
    ) -> Bool {
        _ = gitVersion
        let critical = [
            "index.lock",
            "HEAD.lock",
            "packed-refs.lock",
            "config.lock",
            "shallow.lock"
        ]
        let fm = FileManager.default
        for name in critical {
            let url = gitDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                return true
            }
        }
        return false
    }

    /// Enumerate **linked worktrees** (`git worktree add`) of the repo
    /// at `gitDir`, returning each linked worktree's root URL.
    ///
    /// `git worktree add <path>` creates `<path>/.git` as a file
    /// pointing back to `<original>/.git/worktrees/<name>/`. This
    /// function reads the inverse mapping: each
    /// `<gitDir>/worktrees/<name>/gitdir` file contains the absolute
    /// path of the linked worktree. The mapping is canonical and
    /// updated by `git worktree add`/`remove`/`prune`.
    ///
    /// Returns an empty array when the repo has no linked worktrees
    /// (the `worktrees/` subdirectory is absent).
    ///
    /// Does NOT recurse — linked worktrees can themselves have
    /// linked worktrees, but that's a rare, handled by callers via
    /// repeating `linkedWorktrees(at:)` on each result's resolved
    /// gitDir if needed.
    public static func linkedWorktrees(at gitDir: URL) throws -> [URL] {
        let worktreesDir = gitDir.standardized.appendingPathComponent("worktrees")
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: worktreesDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return []
        }

        let entries = try fm.contentsOfDirectory(
            at: worktreesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var results: [URL] = []
        for entry in entries {
            // Each linked-worktree subdir contains a `gitdir` file
            // that gives the absolute path of the linked worktree.
            let pointer = entry.appendingPathComponent("gitdir")
            guard let raw = try? String(contentsOf: pointer, encoding: .utf8) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // The gitdir file points at `<linked>/.git`; the worktree
            // root is one level up.
            let pointerURL = URL(fileURLWithPath: trimmed).standardized
            let worktreeRoot = pointerURL.deletingLastPathComponent().standardized
            results.append(worktreeRoot)
        }

        // Deterministic order so callers can rely on the result for
        // diff-style change detection between calls.
        return results.sorted { $0.path < $1.path }
    }

    /// Discover **submodules** (recursively, including nested) and
    /// return each submodule's worktree URL.
    ///
    /// Implementation runs `git submodule status --recursive` inside
    /// `worktreeURL`. The output line format (per `git-submodule(1)`)
    /// is:
    ///
    ///   `<status-char> <sha-or-marker> <path> [<refname>]`
    ///
    /// where `<status-char>` is one of:
    /// - ` ` — clean (matches super-repo's recorded SHA)
    /// - `+` — different SHA than recorded ("out of date")
    /// - `-` — not yet initialized
    /// - `U` — merge conflict
    ///
    /// We return ALL submodule paths regardless of status — including
    /// uninitialized ones — so the caller can render the appropriate
    /// `submodule-init-needed` / `submodule-out-of-date` badges.
    ///
    /// `--recursive` flattens nested submodules into the same listing,
    /// so this is a single git invocation regardless of nesting depth.
    /// Each `path` is reported relative to `worktreeURL`; we resolve
    /// to absolute URLs.
    static func submoduleWorktrees(
        at worktreeURL: URL,
        runner: Runner? = nil
    ) async throws -> [URL] {
        let worktree = worktreeURL.standardized
        let r = runner ?? Runner(defaultWorkingDirectory: worktree)
        let output = try await r.run(
            ["submodule", "status", "--recursive"],
            cwd: worktree
        )
        // Path components in submodule status are UTF-8; bail loudly if
        // git emits non-UTF-8 bytes (`String(bytes:encoding:)` returns
        // nil rather than substituting U+FFFD). Surfaces malformed
        // output rather than silently dropping submodules.
        guard let stdoutText = String(bytes: output.stdout, encoding: .utf8) else {
            throw GitError.parseFailure(
                context: "submodule status --recursive emitted non-UTF-8 bytes",
                rawSnippet: ""
            )
        }
        var results: [URL] = []
        for rawLine in stdoutText.split(whereSeparator: \.isNewline) {
            // Tolerate empty lines (trailing newlines) gracefully.
            guard !rawLine.isEmpty else { continue }
            // First char is the status indicator; remaining is
            // `<sha-or-marker> <path> [<refname>]`. We split on
            // whitespace and pick index 1 as the path. The refname
            // component (if present) is parenthesized and may itself
            // contain spaces in pathological cases, but we don't need
            // it here.
            let body = rawLine.dropFirst()
            let parts = body.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let path = String(parts[1])
            results.append(worktree.appendingPathComponent(path).standardized)
        }
        return results
    }
}

public extension GitMetadataPaths {
    /// Errors from ``GitMetadataPaths/resolveGitDir(forWorktree:)``.
    enum ResolveError: Error, Equatable {
        /// `<worktree>/.git` doesn't exist at all.
        case notARepository(worktree: URL)

        /// `<worktree>/.git` is a file but reading it as UTF-8 failed.
        case gitdirPointerUnreadable(at: URL, underlying: Error)

        /// `<worktree>/.git` is a file but doesn't contain a parseable
        /// `gitdir: <path>` line.
        case gitdirPointerMalformed(at: URL, content: String)

        /// The `gitdir:` pointer points at a path that doesn't exist
        /// or isn't a directory. Common for submodule worktrees that
        /// haven't been `git submodule init`'d yet.
        case gitdirPointerTargetMissing(at: URL, target: URL)

        public static func == (lhs: ResolveError, rhs: ResolveError) -> Bool {
            switch (lhs, rhs) {
            case let (.notARepository(a), .notARepository(b)):
                a == b
            case let (.gitdirPointerUnreadable(a, _), .gitdirPointerUnreadable(b, _)):
                // Underlying error excluded from equality so callers
                // don't need to construct equal NSErrors in tests.
                a == b
            case let (.gitdirPointerMalformed(a, ac), .gitdirPointerMalformed(b, bc)):
                a == b && ac == bc
            case let (.gitdirPointerTargetMissing(a, at), .gitdirPointerTargetMissing(b, bt)):
                a == b && at == bt
            default:
                false
            }
        }
    }
}
