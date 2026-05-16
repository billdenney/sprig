// AtomicWriteWithRetry.swift
//
// Windows-tolerant atomic file write helper used by the merge-conflict
// apply pipeline (`MergeApplyPipeline.applyPerRegionText`).
//
// Why this exists
// ---------------
// `String.write(to:atomically:encoding:)` does write-temp-then-rename.
// On Windows the rename uses `MoveFileEx`, which fails with Win32
// `ERROR_SHARING_VIOLATION` (code 32, surfaced through Foundation as
// `CocoaError.fileWriteNoPermission`) when another process holds an
// open handle on the target. The most common culprits:
//
//   * Windows Defender's real-time scanner -- holds a transient
//     read-share-deny-write handle while scanning a freshly-written
//     file. Median scan time ~200 ms, worst case ~2 s.
//
//   * Text editors keeping the file open while the user resolves a
//     conflict. The user's expected workflow is "tweak in editor →
//     hit Apply in Sprig"; Sprig then races the editor's file watcher.
//
//   * Other git clients running concurrently (e.g. `git status`
//     issued by another tool's pre-commit hook).
//
// macOS and Linux take the success path on the first attempt --
// POSIX `rename(2)` overwrites a locked target -- so this is
// effectively Windows-only behavior with zero overhead elsewhere.
//
// Retry schedule: five attempts with backoff `100 ms → 200 ms →
// 400 ms → 800 ms → 1.6 s` (cumulative ≈ 3.1 s), matched to Defender's
// scan-completion distribution. Falls through to throw the last seen
// error if all attempts fail, preserving the caller's typed-error
// surface unchanged.

import Foundation

enum AtomicWriteWithRetry {
    /// Write `content` atomically to `url`, retrying with exponential
    /// backoff on transient Windows file-sharing violations.
    static func run(
        _ content: String,
        to url: URL,
        attempts: Int = 5,
        initialDelaySec: Double = 0.1
    ) async throws {
        var lastError: Error?
        for attempt in 0 ..< attempts {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
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
}
