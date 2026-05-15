// MergeApplyPipeline.swift
//
// Static apply helpers consumed by MergeConflictResolverViewModel.
// Extracted out of the VM so the latter stays under SwiftLint's
// file-length cap as the apply surface grows (whole-side picks +
// per-region text + LFS-pointer materialization + future LFS-pull
// affordances all live here).
//
// The pipeline is intentionally stateless — every call receives the
// resources it needs (repo URL, runner, catFile) as arguments. That
// makes each helper independently testable without standing up the
// whole VM.

import ConflictKit
import Foundation
import GitCore

/// Static apply helpers. Not instantiated; namespace only.
enum MergeApplyPipeline {
    /// Top-level dispatch for one path's resolution. Branches on the
    /// choice kind (whole-side picks vs per-region text), then on the
    /// stage's mode (regular file vs submodule). LFS-pointer kinds
    /// trigger a post-apply `git lfs checkout` materialization step.
    static func applySingle(
        conflict: ClassifiedConflict,
        choice: ConflictedPathChoice,
        repoURL: URL,
        runner: Runner,
        catFile: CatFileBatch
    ) async throws {
        if case let .text(regions) = choice {
            try applyPerRegionText(
                conflict: conflict,
                regions: regions,
                repoURL: repoURL
            )
            _ = try await runner.run(["add", "--", conflict.entry.path])
            return
        }

        guard let stageNumber = choice.stage else {
            throw MergeApplyError.pending(path: conflict.entry.path)
        }
        guard let stage = conflict.entry.stages.first(where: { $0.stage == stageNumber }) else {
            throw MergeApplyError.missingStage(
                path: conflict.entry.path,
                stage: stageNumber
            )
        }
        switch stage.mode {
        case .submodule:
            try await applySubmoduleStage(
                path: conflict.entry.path,
                stage: stage,
                runner: runner
            )
        case .regularFile, .executable, .symlink, .unknown:
            try await applyBlobStage(
                conflict: conflict,
                stage: stage,
                repoURL: repoURL,
                runner: runner,
                catFile: catFile
            )
        }
    }

    /// Splice per-region resolutions into the working-tree file +
    /// write back. Source is the markered file git wrote during the
    /// failed merge; parsed via ``ConflictedFile/init(source:)``;
    /// applied via ``ConflictedFile/applying(_:)``. Rejects non-text
    /// kinds with ``MergeApplyError/textChoiceOnNonTextKind(path:)``.
    static func applyPerRegionText(
        conflict: ClassifiedConflict,
        regions: [ConflictResolution],
        repoURL: URL
    ) throws {
        guard conflict.kind == .text else {
            throw MergeApplyError.textChoiceOnNonTextKind(path: conflict.entry.path)
        }
        let target = repoURL.appendingPathComponent(conflict.entry.path)
        let source = try String(contentsOf: target, encoding: .utf8)
        let resolved = try ConflictedFile(source: source).applying(regions)
        try resolved.write(to: target, atomically: true, encoding: .utf8)
    }

    /// Update the index directly for a submodule stage. The stage's
    /// `sha` is a commit SHA in the submodule's own repo, not a blob
    /// SHA in the super-repo, so we can't read + write bytes — we
    /// use `git update-index --cacheinfo` to plant the gitlink.
    private static func applySubmoduleStage(
        path: String,
        stage: UnmergedStage,
        runner: Runner
    ) async throws {
        let modeOctal = String(stage.mode.rawMode, radix: 8)
        _ = try await runner.run([
            "update-index",
            "--add",
            "--cacheinfo",
            "\(modeOctal),\(stage.sha),\(path)"
        ])
    }

    /// Whole-side blob apply: cat-file the chosen stage, write bytes
    /// to disk, `git add`. For LFS-pointer conflicts the written
    /// bytes are a pointer (~150 bytes of OID + size); a follow-up
    /// `git lfs checkout` materializes the actual binary.
    private static func applyBlobStage(
        conflict: ClassifiedConflict,
        stage: UnmergedStage,
        repoURL: URL,
        runner: Runner,
        catFile: CatFileBatch
    ) async throws {
        let blob = try await catFile.read(stage.sha)
        let target = repoURL.appendingPathComponent(conflict.entry.path)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try blob.content.write(to: target)
        _ = try await runner.run(["add", "--", conflict.entry.path])
        if conflict.kind == .lfsPointer {
            try await materializeLFSPointer(
                path: conflict.entry.path,
                runner: runner
            )
        }
    }

    /// Run `git lfs checkout -- <path>` so the working-tree file
    /// becomes the actual binary instead of the pointer text we
    /// just wrote. Surfaces `MergeApplyError.lfsMaterializeFailed`
    /// with the underlying error description on any failure (git-lfs
    /// missing, object not in cache, etc.). The pointer + index
    /// entry are still correct after a failure — the user can
    /// re-checkout once their LFS environment is healthy.
    private static func materializeLFSPointer(
        path: String,
        runner: Runner
    ) async throws {
        do {
            _ = try await runner.run(["lfs", "checkout", "--", path])
        } catch {
            throw MergeApplyError.lfsMaterializeFailed(
                path: path,
                underlying: String(describing: error)
            )
        }
    }
}
