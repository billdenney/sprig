// AtomicWriteWithRetry.swift
//
// Windows-tolerant atomic file write helper for the few places in
// TaskWindowKit that write working-tree-visible files (currently:
// `PreferencesViewModel.save()` and the merge-conflict apply
// pipeline's `applyPerRegionText`).
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
//   * Text editors keeping the file open while the user edits it.
//
//   * Other git or sprig processes touching the same file mid-write.
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
    /// Write `data` atomically to `url`, retrying with exponential
    /// backoff on transient Windows file-sharing violations.
    static func run(
        _ data: Data,
        to url: URL,
        attempts: Int = 5,
        initialDelaySec: Double = 0.1
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
        attempts: Int = 5,
        initialDelaySec: Double = 0.1
    ) async throws {
        let data = Data(content.utf8)
        try await run(data, to: url, attempts: attempts, initialDelaySec: initialDelaySec)
    }
}
