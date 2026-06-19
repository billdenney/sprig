// SubmoduleUpdate — the ADR 0096 auto-reconcile op.
//
// Tier 1 portable. Pure Foundation; spawns git via `GitCore.Runner`;
// snapshots dirty work via `SafetyKit.WorktreeBackup`.
//
// ADR 0096 makes submodules tracked-by-default. The write op is
// `git submodule update --init --recursive` with **NO `--force`** so a
// submodule the user has been editing is never silently clobbered.
//
// The catch (verified against git 2.43): git's own `submodule update`
// does NOT skip-and-continue past a dirty submodule. When a checkout
// would overwrite local *tracked* changes, git ABORTS THE WHOLE COMMAND
// (exit 1) and updates nothing — even the clean submodules. So a naive
// `update --init --recursive` is all-or-nothing in the presence of one
// dirty submodule.
//
// This op therefore pre-classifies: it reads `git submodule status`,
// probes each submodule's worktree for dirt (`git -C <sub> status
// --porcelain -z` — ANY output, tracked or untracked, counts as dirty),
// and then runs `update --init --recursive` over ONLY the clean
// submodule paths (as explicit pathspecs). Dirty submodules are SKIPPED
// and REPORTED, never touched.
//
// For a dirty submodule the user explicitly elects to overwrite, the
// snapshot-then-force remedy (``snapshotThenForce(submodulePath:in:runner:)``)
// takes a ``SafetyKit/WorktreeBackup`` snapshot INSIDE THE SUBMODULE'S
// REPO (ADR 0075 — a `refs/sprig/backup/...` ref in the submodule's own
// gitdir, capturing ALL tracked + untracked work with NO exclude list)
// and ONLY THEN runs `submodule update --init --force -- <sub>` from the
// super-repo. The no-exclude detail is load-bearing: `WorktreeBackup`'s
// default `JunkFilePatterns` excludes (`*.key`, `*.env`, `*secret*`, …)
// are right for periodic auto-backups but WRONG for a force-destroy — a
// tracked edit to such a file would otherwise be silently excluded,
// mint no backup ref, and be clobbered by the force with nothing to
// recover. The overwritten work is recoverable from the submodule's
// Recover surface.
// No super-repo HEAD moves, so no ADR 0033 snapshot ref is minted here;
// the recoverable state is the submodule's uncommitted working tree
// (a `WorktreeBackup`), exactly as ADR 0089's force path does for
// sparse-checkout.

import Foundation
import GitCore
import SafetyKit

/// Outcome of a non-forced ``SubmoduleUpdate/reconcile(at:runner:)``.
public struct SubmoduleUpdateOutcome: Sendable, Equatable {
    /// Paths of submodules that were clean and got `update --init
    /// --recursive`'d (relative to the super-repo worktree).
    public let updated: [String]

    /// Paths of submodules that were dirty and SKIPPED — left exactly
    /// as the user had them. Each is a candidate for
    /// ``SubmoduleUpdate/snapshotThenForce(submodulePath:in:runner:)``.
    public let skippedDirty: [String]

    public init(updated: [String], skippedDirty: [String]) {
        self.updated = updated
        self.skippedDirty = skippedDirty
    }
}

/// Outcome of a ``SubmoduleUpdate/snapshotThenForce(submodulePath:in:runner:)``.
public struct SubmoduleForceOutcome: Sendable, Equatable {
    /// The submodule path that was force-updated.
    public let submodulePath: String

    /// The `refs/sprig/backup/...` ref minted inside the submodule's
    /// repo before the force, or `nil` when there was nothing the force
    /// could discard — the submodule's working-tree content was already
    /// equivalent to its `HEAD` (a genuinely clean tree, or only
    /// stat-/normalization-dirty so staging it reproduces `HEAD`'s
    /// tree). Because the backup uses NO exclude list, `nil` no longer
    /// hides a junk-only-dirty case: a tracked edit to a `*.key`/`*.env`/
    /// `*secret*`-shaped file IS captured and yields a ref.
    public let backupRef: BackupRefName?

    public init(submodulePath: String, backupRef: BackupRefName?) {
        self.submodulePath = submodulePath
        self.backupRef = backupRef
    }
}

/// The ADR 0096 auto-reconcile submodule update op.
public enum SubmoduleUpdate {
    /// Run `git submodule update --init --recursive` (NO `--force`)
    /// over the clean submodules of the super-repo at `worktree`,
    /// skipping and reporting any dirty submodule rather than letting
    /// git abort the whole command.
    ///
    /// - Parameters:
    ///   - worktree: super-repo worktree root.
    ///   - runner: ``GitCore/Runner`` for the super-repo. Per-submodule
    ///     dirt probes derive a `cwd`-scoped runner from it.
    /// - Returns: which submodules were updated and which were skipped
    ///   dirty.
    ///
    /// A super-repo with no submodules returns an empty outcome without
    /// spawning `submodule update` (nothing to reconcile).
    @discardableResult
    public static func reconcile(
        at worktree: URL,
        runner: Runner
    ) async throws -> SubmoduleUpdateOutcome {
        let standardized = worktree.standardized
        let entries = try await SubmoduleStatus.fetch(
            at: standardized,
            runner: runner,
            recursive: false
        )
        guard !entries.isEmpty else {
            return SubmoduleUpdateOutcome(updated: [], skippedDirty: [])
        }

        var cleanPaths: [String] = []
        var dirtyPaths: [String] = []
        for entry in entries {
            // An uninitialized submodule is an EMPTY directory, not a git
            // repo — a `git -C <sub> status` probe would walk UP and report
            // the PARENT repo's dirt, so a dirty super-repo would wrongly
            // mark every uninitialized submodule "dirty" and skip it. Treat
            // it as clean so `update --init` clones it (the whole point of
            // tracked-by-default). Only INITIALIZED submodules get probed.
            if entry.state == .notInitialized {
                cleanPaths.append(entry.path)
                continue
            }
            if try await isDirty(submodulePath: entry.path, superRepo: standardized, runner: runner) {
                dirtyPaths.append(entry.path)
            } else {
                cleanPaths.append(entry.path)
            }
        }

        if !cleanPaths.isEmpty {
            var arguments = ["submodule", "update", "--init", "--recursive", "--"]
            arguments.append(contentsOf: cleanPaths)
            _ = try await runner.run(arguments, cwd: standardized)
        }

        return SubmoduleUpdateOutcome(updated: cleanPaths, skippedDirty: dirtyPaths)
    }

    /// The snapshot-then-force remedy for one dirty submodule.
    ///
    /// Takes a ``SafetyKit/WorktreeBackup`` snapshot INSIDE the
    /// submodule's own repo (capturing ALL tracked + untracked work —
    /// with NO exclude list, so a force-destroy is fully recoverable) as
    /// a `refs/sprig/backup/...` ref, and ONLY THEN runs `git submodule
    /// update --init --force -- <submodulePath>` from the super-repo,
    /// overwriting the submodule's working tree with the recorded SHA.
    ///
    /// - Parameters:
    ///   - submodulePath: the dirty submodule's path, relative to the
    ///     super-repo worktree (a value from
    ///     ``SubmoduleUpdateOutcome/skippedDirty``).
    ///   - worktree: super-repo worktree root.
    ///   - runner: ``GitCore/Runner`` for the super-repo. The in-submodule
    ///     backup uses a `cwd`-scoped runner derived from it.
    /// - Returns: the path and the minted backup ref (or `nil` only when
    ///   the working tree held nothing the force could discard — its
    ///   content already equalled `HEAD`).
    @discardableResult
    public static func snapshotThenForce(
        submodulePath: String,
        in worktree: URL,
        runner: Runner
    ) async throws -> SubmoduleForceOutcome {
        let standardized = worktree.standardized
        let submoduleWorktree = standardized.appendingPathComponent(submodulePath)

        // Snapshot FIRST, inside the submodule's repo. `WorktreeBackup`
        // builds the ref in the submodule's own gitdir because the
        // runner's cwd is the submodule worktree.
        let subRunner = Runner(
            gitPath: runner.gitPath,
            defaultWorkingDirectory: submoduleWorktree,
            environmentOverrides: runner.environmentOverrides,
            log: runner.log
        )
        // `excludedPatterns: []` — back up EVERYTHING, with no exclude
        // list. `WorktreeBackup`'s default `JunkFilePatterns` excludes
        // (`*.key`, `*.env`, `*secret*`, …) exist to keep PERIODIC
        // auto-backups from persisting likely-secret/junk files into git
        // objects every tick. That trade-off is wrong here: this is a
        // user-ELECTED destructive overwrite, and `createBackupIfDirty`'s
        // junk-only-dirty guard returns `nil` (no ref) when the sole dirt
        // is an excluded path. If a TRACKED `*.key`/`*.env`/`*secret*`
        // edit were the only dirt, the default excludes would mint no
        // backup and the `--force` below would clobber it with NO
        // recovery ref — permanent data loss. For a force-destroy,
        // everything the force can discard must be recoverable, so
        // nothing is excluded. (The backup ref is local to the
        // submodule's gitdir and TTL-pruned; it is never pushed.)
        let backup = WorktreeBackup(runner: subRunner, excludedPatterns: [])
        let backupRef = try await backup.createBackupIfDirty()

        // Only now overwrite. `--` pins the pathspec so a submodule
        // whose name looks like a flag can't be misparsed.
        let arguments = [
            "submodule", "update", "--init", "--force", "--", submodulePath
        ]
        _ = try await runner.run(arguments, cwd: standardized)

        return SubmoduleForceOutcome(submodulePath: submodulePath, backupRef: backupRef)
    }

    /// `true` when the submodule at `submodulePath` has ANY working-tree
    /// change — tracked modifications OR untracked files. We treat both
    /// as "don't clobber": `git submodule update` aborts on tracked
    /// dirt, and a force would discard untracked work the user may
    /// still want, so the conservative skip covers both.
    ///
    /// Only ever called for an INITIALIZED submodule — `reconcile`
    /// short-circuits the uninitialized case before probing, because a
    /// `git -C <empty-sub-dir>` walks up to the parent repo.
    private static func isDirty(
        submodulePath: String,
        superRepo: URL,
        runner: Runner
    ) async throws -> Bool {
        let submoduleWorktree = superRepo.appendingPathComponent(submodulePath)
        let subRunner = Runner(
            gitPath: runner.gitPath,
            defaultWorkingDirectory: submoduleWorktree,
            environmentOverrides: runner.environmentOverrides,
            log: runner.log
        )
        let status = try await subRunner.run(
            ["status", "--porcelain", "-z"],
            throwOnNonZero: false
        )
        // Defensive: an unexpected non-zero status (the submodule's git
        // dir is unreadable) reads as not-dirty rather than throwing.
        guard status.exitCode == 0 else { return false }
        return !status.stdout.isEmpty
    }
}
