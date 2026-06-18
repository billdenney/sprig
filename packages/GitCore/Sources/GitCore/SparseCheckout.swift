// SparseCheckout.swift
//
// ADR 0089 — cone-mode sparse-checkout, the engine behind the
// beginner-facing "Choose folders to keep on this Mac…" selective-sync
// window (a direct analogue to OneDrive / SharePoint selective sync).
//
// Sparse-checkout changes which paths git *materializes* in the working
// tree; it never touches committed history. Re-checking a folder
// restores it byte-for-byte from the object store, and `disable`
// restores the whole worktree. That is the reassuring, lossless story
// the UI tells — but it is only fully true for CLEAN folders.
//
// The bare `git sparse-checkout set` is NOT clean-only honest:
//   * A dropped folder with *modified* tracked files or *untracked*
//     files is LEFT materialized (git warns, then keeps it) — so the
//     picker's "this folder is now off your computer" promise is
//     silently violated.
//   * A dropped folder with a *staged* change is de-materialized with
//     NO warning (the content survives in the index, but the worktree
//     file vanishes — alarming, and easy to mistake for data loss).
//
// So this wrapper adds the safety analysis the bare command lacks:
// ``planChange(to:)`` reports which dropped folders hold uncommitted or
// untracked work, so the UI can fail closed (skip + report) and offer a
// snapshot-then-force escape hatch instead of surprising the user.
// ``forciblyClearDirectories(_:)`` is that escape hatch's teeth — and
// its doc comment spells out the one safe way to call it.
//
// Tier 1, portable. All git access via ``Runner``. Cone mode only
// (power users keep the CLI for arbitrary patterns, per the ADR).

import Foundation

/// Cone-mode sparse-checkout wrapper plus the dirty-folder safety
/// analysis the bare `git sparse-checkout` command doesn't provide.
public struct SparseCheckout: Sendable {
    public let runner: Runner

    public init(runner: Runner) {
        self.runner = runner
    }

    // MARK: - Reads

    /// The current materialization state: ``SparseSelection/full`` when
    /// sparse-checkout is off, ``SparseSelection/cone(directories:)``
    /// listing the cone's top-level directories when cone mode is on, or
    /// ``SparseSelection/unsupportedPatternMode`` when sparse-checkout is
    /// on but NOT in cone mode (hand-crafted patterns the cone-only
    /// picker must not rewrite).
    public func currentSelection() async throws -> SparseSelection {
        let enabled = try await runner.run(
            ["config", "--get", "core.sparseCheckout"],
            throwOnNonZero: false
        )
        let isOn = enabled.exitCode == 0
            && enabled.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        guard isOn else { return .full }

        // The picker is cone-only. A sparse repo without cone mode holds
        // arbitrary patterns (`git sparse-checkout list` emits raw
        // patterns like `/*`, `!/docs/`, not directory names); parsing
        // those as folders — and worse, `set`ting over them — would
        // mangle the user's hand-crafted sparse file. Report it as
        // unsupported instead.
        let cone = try await runner.run(
            ["config", "--get", "core.sparseCheckoutCone"],
            throwOnNonZero: false
        )
        let isCone = cone.exitCode == 0
            && cone.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        guard isCone else { return .unsupportedPatternMode }

        let listed = try await runner.run(["sparse-checkout", "list"], throwOnNonZero: false)
        var directories: [String] = []
        listed.stdoutString.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { directories.append(trimmed) }
        }
        // On a case-insensitive filesystem `sparse-checkout list` echoes
        // the user's typed casing, which can diverge from the HEAD-tree
        // casing the picker shows; canonicalize so membership checks line
        // up. No-op on a case-sensitive repo.
        let canonical = try await canonicalizeToTreeCasing(directories)
        return .cone(directories: canonical.sorted())
    }

    /// The repo's top-level *directories* at HEAD — the candidates the
    /// folder picker shows. Reads the HEAD tree (not the worktree, so
    /// already-dropped folders still appear) and keeps only tree
    /// entries: blobs (root files, always kept by cone mode) and
    /// submodule gitlinks (type `commit`) are excluded, which sidesteps
    /// the sparse-vs-submodule hazard the ADR flags. Empty on an unborn
    /// HEAD.
    public func topLevelDirectories() async throws -> [String] {
        let result = try await runner.run(["ls-tree", "-z", "HEAD"], throwOnNonZero: false)
        guard result.exitCode == 0 else { return [] }
        return Self.parseTopLevelTreeDirectories(result.stdout).sorted()
    }

    // MARK: - Writes

    /// `git sparse-checkout init --cone` — turn on cone-mode
    /// sparse-checkout. Idempotent.
    public func enableConeMode() async throws {
        _ = try await runner.run(["sparse-checkout", "init", "--cone"])
    }

    /// `git sparse-checkout set <directories>` — materialize exactly the
    /// named top-level directories (plus repo-root files). The inverse
    /// of unchecking the others.
    public func set(_ directories: [String]) async throws {
        _ = try await runner.run(["sparse-checkout", "set"] + directories)
    }

    /// `git sparse-checkout add <directories>` — re-check (re-materialize)
    /// folders without disturbing the rest of the cone.
    public func add(_ directories: [String]) async throws {
        _ = try await runner.run(["sparse-checkout", "add"] + directories)
    }

    /// `git sparse-checkout disable` — restore the full worktree and
    /// turn sparse-checkout off.
    public func disable() async throws {
        _ = try await runner.run(["sparse-checkout", "disable"])
    }

    // MARK: - Safety analysis

    /// Compute what changing the cone to `targetDirectories` would do,
    /// and — crucially — which dropped folders hold uncommitted or
    /// untracked work that the bare git command would either silently
    /// strand (modified / untracked) or de-materialize without warning
    /// (staged).
    ///
    /// Callers fail closed on ``SparseChangePlan/blockedDrops``: refuse
    /// the change and report, offering a snapshot-then-force path
    /// (mint a ``WorktreeBackup`` then ``forciblyClearDirectories(_:)``)
    /// rather than surprising the user.
    public func planChange(to targetDirectories: [String]) async throws -> SparseChangePlan {
        let current = try await currentlyMaterializedDirectories()
        let target = Set(targetDirectories)
        let drops = current.subtracting(target)
        let adds = target.subtracting(current)

        var reasonsByDirectory: [String: Set<DirtyReason>] = [:]
        if !drops.isEmpty {
            // Map a status path's top component back to the canonical
            // dropped-folder name. On a case-insensitive filesystem a
            // case-only rename makes `git status` report the on-disk
            // dirent casing while the cone/tree use the index casing —
            // without folding, the dirty-folder guard would miss it and
            // silently de-materialize the work.
            let caseFold = try await caseInsensitive()
            var dropByKey: [String: String] = [:]
            for drop in drops {
                dropByKey[caseFold ? drop.lowercased() : drop] = drop
            }

            let status = try await runner.run(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all"]
            )
            let parsed = try PorcelainV2Parser.parse(status.stdout)
            for entry in parsed.entries {
                guard let top = Self.topLevelComponent(of: entry.path),
                      let canonical = dropByKey[caseFold ? top.lowercased() : top]
                else { continue }
                let reasons = Self.dirtyReasons(for: entry)
                if !reasons.isEmpty { reasonsByDirectory[canonical, default: []].formUnion(reasons) }
            }
        }

        let blocked = reasonsByDirectory
            .map { DirtyDirectory(name: $0.key, reasons: $0.value) }
            .sorted { $0.name < $1.name }
        return SparseChangePlan(
            target: targetDirectories.sorted(),
            adds: adds.sorted(),
            drops: drops.sorted(),
            blockedDrops: blocked
        )
    }

    /// **DANGER — permanently discards uncommitted tracked changes AND
    /// deletes untracked files inside `directories`.** It reverts each
    /// folder to its pristine HEAD content so a subsequent ``set(_:)``
    /// can cleanly de-materialize it.
    ///
    /// The ONLY safe caller is one that has *just* minted a recoverable
    /// backup of the working tree (`SafetyKit.WorktreeBackup`'s
    /// `createBackupIfDirty()`, which captures tracked changes AND
    /// untracked files). The selective-sync surfaces do exactly that
    /// before calling, and their undo-round-trip tests prove the work
    /// comes back byte-for-byte. Never call this without that backup.
    ///
    /// Scoped per named directory: it can never touch anything outside
    /// `directories`. Ignored files are preserved (no `-x`) and nested
    /// repositories are not removed (no `-ff`).
    public func forciblyClearDirectories(_ directories: [String]) async throws {
        for directory in directories {
            // Revert tracked modifications (index + worktree) to HEAD.
            // Tolerant of a non-zero exit: a directory whose only dirt
            // is untracked files has nothing for `restore` to match.
            _ = try await runner.run(
                ["restore", "--worktree", "--staged", "--", directory],
                throwOnNonZero: false
            )
            // Remove untracked files and directories within this folder.
            _ = try await runner.run(["clean", "-fd", "--", directory])
        }
    }

    // MARK: - Internals

    private func currentlyMaterializedDirectories() async throws -> Set<String> {
        switch try await currentSelection() {
        case .full:
            return try await Set(topLevelDirectories())
        case let .cone(directories):
            return Set(directories)
        case .unsupportedPatternMode:
            throw SparseCheckoutError.unsupportedPatternMode
        }
    }

    /// Whether git treats this repo's paths case-insensitively
    /// (`core.ignorecase` — auto-set on macOS HFS+/APFS and Windows
    /// NTFS). Drives the case-folding in ``currentSelection()`` and
    /// ``planChange(to:)`` so folder names that differ only by case
    /// across git's outputs line up.
    private func caseInsensitive() async throws -> Bool {
        let result = try await runner.run(
            ["config", "--get", "core.ignorecase"],
            throwOnNonZero: false
        )
        return result.exitCode == 0
            && result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Map cone directory names to their HEAD-tree casing when the repo
    /// is case-insensitive; pass names through unchanged otherwise (and
    /// for names with no top-level tree match, e.g. nested cone paths).
    private func canonicalizeToTreeCasing(_ names: [String]) async throws -> [String] {
        guard try await caseInsensitive() else { return names }
        var byKey: [String: String] = [:]
        for directory in try await topLevelDirectories() {
            byKey[directory.lowercased()] = directory
        }
        return names.map { byKey[$0.lowercased()] ?? $0 }
    }

    /// Parse `git ls-tree -z HEAD` output, returning the paths of the
    /// top-level entries whose type is `tree` (directories). Each
    /// NUL-terminated record is `<mode> SP <type> SP <object> TAB
    /// <path>`; blobs and submodule gitlinks (type `commit`) are
    /// dropped.
    static func parseTopLevelTreeDirectories(_ data: Data) -> [String] {
        var directories: [String] = []
        for record in data.split(separator: 0) {
            // swiftlint:disable:next optional_data_string_conversion
            let line = String(decoding: record, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            // Metadata before the TAB is `<mode> SP <type> SP <object>`;
            // the entry type is the second token.
            let meta = line[..<tab].split(separator: " ")
            guard meta.count >= 2, meta[1] == "tree" else { continue }
            directories.append(String(line[line.index(after: tab)...]))
        }
        return directories
    }

    /// The first path component of `path`, or nil for a repo-root file
    /// (no separator). Git always emits `/`-separated paths, on every
    /// platform.
    static func topLevelComponent(of path: String) -> String? {
        guard let slash = path.firstIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }

    private static func dirtyReasons(for entry: Entry) -> Set<DirtyReason> {
        switch entry {
        case let .ordinary(ordinary):
            changeReasons(ordinary.xy)
        case let .renamed(renamed):
            changeReasons(renamed.xy)
        case .unmerged:
            [.conflict]
        case .untracked:
            [.untrackedFile]
        case .ignored:
            []
        }
    }

    private static func changeReasons(_ xy: StatusXY) -> Set<DirtyReason> {
        var reasons: Set<DirtyReason> = []
        if xy.index != .unmodified { reasons.insert(.stagedChange) }
        if xy.worktree != .unmodified { reasons.insert(.unsavedChange) }
        return reasons
    }
}

// MARK: - Model

/// The worktree's current materialization state.
public enum SparseSelection: Sendable, Equatable {
    /// Sparse-checkout is off; the whole worktree is materialized.
    case full
    /// Cone mode on, materializing exactly these top-level directories
    /// (plus repo-root files, which cone mode always keeps).
    case cone(directories: [String])
    /// Sparse-checkout is on but NOT in cone mode — the repo holds
    /// hand-crafted patterns. The cone-only folder picker refuses to
    /// touch it rather than rewrite the pattern file.
    case unsupportedPatternMode
}

/// Errors specific to ``SparseCheckout`` (git-backed failures surface as
/// ``GitError`` from the underlying ``Runner``).
public enum SparseCheckoutError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Sparse-checkout is enabled but not in cone mode; the folder
    /// picker is cone-only and won't rewrite hand-crafted patterns.
    case unsupportedPatternMode

    public var description: String {
        switch self {
        case .unsupportedPatternMode:
            "this repository uses advanced sparse-checkout patterns; change them with the git command line"
        }
    }
}

/// Why a folder being dropped from the cone is "dirty" — it holds work
/// not safely recorded in committed history.
public enum DirtyReason: Sendable, Equatable, Hashable, CaseIterable {
    /// A staged (index) change.
    case stagedChange
    /// An unsaved (worktree) modification to a tracked file.
    case unsavedChange
    /// An untracked file (new, not yet added to git).
    case untrackedFile
    /// An unresolved merge conflict.
    case conflict
}

/// A top-level folder that can't be dropped cleanly because it holds
/// uncommitted or untracked work.
public struct DirtyDirectory: Sendable, Equatable {
    public let name: String
    public let reasons: Set<DirtyReason>

    public init(name: String, reasons: Set<DirtyReason>) {
        self.name = name
        self.reasons = reasons
    }
}

/// The effect of changing the cone, plus the fail-closed safety verdict.
public struct SparseChangePlan: Sendable, Equatable {
    /// The requested cone (sorted).
    public let target: [String]
    /// Directories that would be newly materialized.
    public let adds: [String]
    /// Directories that would be de-materialized.
    public let drops: [String]
    /// Dropped directories holding uncommitted / untracked work. When
    /// non-empty, callers must fail closed (and may offer a
    /// snapshot-then-force path).
    public let blockedDrops: [DirtyDirectory]

    public init(target: [String], adds: [String], drops: [String], blockedDrops: [DirtyDirectory]) {
        self.target = target
        self.adds = adds
        self.drops = drops
        self.blockedDrops = blockedDrops
    }

    /// True when no dropped folder holds at-risk work — the change is
    /// safe to apply directly.
    public var isCleanToApply: Bool {
        blockedDrops.isEmpty
    }
}
