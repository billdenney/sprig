// AtomicWriteWithRetry.swift
//
// Windows-tolerant atomic file write helper for the few places in
// TaskWindowKit that write working-tree-visible files: the
// merge-conflict apply pipeline (`MergeApplyPipeline.applyPerRegionText`)
// and `PreferencesViewModel.save()`.
//
// Why this exists
// ---------------
// `Data.write(to:options:.atomic)` and `String.write(to:atomically:
// encoding:)` do write-temp-then-rename. On Windows the rename step
// uses `MoveFileEx`, which fails with Win32 `ERROR_SHARING_VIOLATION`
// (code 32, surfaced through Foundation as
// `CocoaError.fileWriteNoPermission`) when another process holds an
// open handle on the target. The most common culprits:
//
//   * Windows Defender's real-time scanner -- holds a transient
//     read-share-deny-write handle while scanning a freshly-written
//     file. Median scan time ~200 ms, worst case ~2 s.
//
//   * Text editors keeping the file open while the user resolves a
//     conflict or edits a config file. The user's expected workflow
//     is "tweak in editor → hit Apply / Save in Sprig"; Sprig then
//     races the editor's file watcher.
//
//   * Other git or sprig processes touching the same file mid-write
//     (e.g. `git status` issued by another tool's pre-commit hook).
//
// macOS and Linux take the success path on the first attempt --
// POSIX `rename(2)` overwrites a locked target -- so this is
// effectively Windows-only behavior with zero overhead elsewhere.
//
// Retry schedule: eight attempts with backoff `250 ms → 500 ms →
// 1 s → 2 s → 4 s → 8 s → 16 s → 32 s` (cumulative ≈ 64 s).
// The previous tighter schedule (5×100ms, ~3.1 s total) was exhausting
// on hosted Windows runners under heavy parallel-test load, where
// Defender + the runner's scheduler can keep a single file
// inaccessible for tens of seconds. Falls through to throw the last
// seen error if all attempts fail, preserving the caller's typed-
// error surface unchanged.

import Foundation

enum AtomicWriteWithRetry {
    /// Write `data` atomically to `url`, retrying with exponential
    /// backoff on transient Windows file-sharing violations.
    static func run(
        _ data: Data,
        to url: URL,
        attempts: Int = 8,
        initialDelaySec: Double = 0.25
    ) async throws {
        var lastError: Error?
        for attempt in 0 ..< attempts {
            do {
                try data.write(to: url, options: .atomic)
                return
            } catch let error as CocoaError where error.code == .fileWriteNoPermission {
                // Transient sharing violation on Windows; back off + retry.
                lastError = error
                if attempt < attempts - 1 {
                    let backoff = initialDelaySec * pow(2.0, Double(attempt))
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }
        }
        // Out of retries -- surface the last seen error so the
        // caller's typed-error handling kicks in unchanged.
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    /// String overload -- encodes UTF-8 then defers to the Data form.
    static func run(
        _ content: String,
        to url: URL,
        attempts: Int = 8,
        initialDelaySec: Double = 0.25
    ) async throws {
        let data = Data(content.utf8)
        try await run(data, to: url, attempts: attempts, initialDelaySec: initialDelaySec)
    }
}
