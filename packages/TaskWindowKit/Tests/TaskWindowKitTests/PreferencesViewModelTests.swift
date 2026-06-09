// PreferencesViewModelTests.swift
//
// Tests for PreferencesViewModel — JSON round-trip against an
// injected temp-dir URL. No git involvement; pure Foundation.

import Foundation
@testable import TaskWindowKit
import Testing

// `.serialized`: each save() is an atomic temp-write + rename, which
// Windows Defender on the local VM (no exclusions, per security
// policy) scans aggressively. With the suite's tests running in
// parallel under full-suite git churn, concurrent saves stack
// sharing-violation retry ladders until AtomicWriteWithRetry's ~64 s
// ceiling blows (observed repeatedly on the Server 2022 VM; hosted
// runners ship Defender exclusions and don't hit this). Serial keeps
// each save's violation window short.
@Suite("PreferencesViewModel — Codable round-trip + load/save semantics", .serialized)
struct PreferencesViewModelTests {
    // MARK: - Fixture helpers

    private func makeTempDir(tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sprig-prefs-\(tag)-\(UUID().uuidString)")
            .standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static let fixedClock: @Sendable () -> Date = {
        let date = Date(timeIntervalSince1970: 1_715_000_000)
        return { date }
    }()

    // Per-platform visibility budget for ``waitForFile(at:timeout:pollInterval:)``.
    //
    // Windows gets 30 s, not the documented ~2 s `FindFirstFile` lag
    // ceiling: under FULL-suite load (~950 tests, most spawning real
    // git against the same disk), `save()`'s `AtomicWriteWithRetry`
    // has been observed taking ~55 s of retries before the file
    // lands, blowing through a 5 s post-save budget (seen twice on
    // the local Server 2022 VM; same pattern as the PR #110
    // polling-watcher budgets). macOS/Linux see the file on the
    // first poll, so their budget is only a failure backstop.
    #if os(Windows)
        private static let fileVisibilityBudget: TimeInterval = 30.0
    #else
        private static let fileVisibilityBudget: TimeInterval = 5.0
    #endif

    /// Poll `FileManager.fileExists(atPath:)` until it returns true or
    /// the deadline elapses, sleeping `pollInterval` between attempts.
    ///
    /// **Why this exists** (Windows-specific race): `Data.write(to:options:.atomic)`
    /// returns successfully on Windows after the underlying `MoveFileEx`
    /// completes, but the new file isn't necessarily visible to
    /// `FileManager.fileExists` (which goes through `FindFirstFile` /
    /// `GetFileAttributes`) for up to ~2 s on busy hosted runners. The
    /// cross-platform-quirks catalog documents this; the polling-watcher
    /// suite uses the same pattern. On macOS / Linux the predicate
    /// returns true on the first poll, so this is a no-op there.
    ///
    /// Returns the final predicate value (true if visible within the
    /// budget, false on timeout).
    private func waitForFile(
        at path: String,
        timeout: TimeInterval = fileVisibilityBudget,
        pollInterval: TimeInterval = 0.05
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Pure-data Codable round-trip

    @Test("AppPreferences round-trips through JSONEncoder/JSONDecoder")
    func appPreferencesRoundTrip() throws {
        let original = AppPreferences(
            schemaVersion: 1,
            watchRoots: [
                URL(fileURLWithPath: "/Users/x/Developer"),
                URL(fileURLWithPath: "/Users/x/Projects")
            ],
            gitIdentity: GitIdentity(name: "Anne", email: "anne@example.com"),
            branchSortRecencyFirst: false,
            autoFetchEnabled: false,
            autoFetchIntervalMinutes: 15,
            autoPullFastForward: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)

        #expect(decoded == original)
    }

    @Test("pre-ADR-0068 preference JSON (no auto-sync keys) decodes with the documented defaults")
    func legacyJSONDecodesWithAutoSyncDefaults() throws {
        // Byte-shape of a prefs file written before the ADR 0068
        // fields existed — exactly the four original keys.
        let legacy = Data("""
        {
          "branchSortRecencyFirst" : true,
          "gitIdentity" : { "email" : "anne@example.com", "name" : "Anne" },
          "schemaVersion" : 1,
          "watchRoots" : []
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacy)
        #expect(decoded.autoFetchEnabled == true)
        #expect(decoded.autoFetchIntervalMinutes == 60)
        #expect(decoded.autoPullFastForward == false)
        #expect(decoded.gitIdentity == GitIdentity(name: "Anne", email: "anne@example.com"))
    }

    @Test("AppPreferences default initializer is empty + recency-first")
    func appPreferencesDefaults() {
        let prefs = AppPreferences()
        #expect(prefs.schemaVersion == 1)
        #expect(prefs.watchRoots.isEmpty)
        #expect(prefs.gitIdentity == nil)
        #expect(prefs.branchSortRecencyFirst)
    }

    // MARK: - Load when file is missing

    @Test("load() on a missing file leaves initial preferences and lands in .success")
    func loadMissingFileIsSuccess() async throws {
        let dir = try makeTempDir(tag: "missing")
        defer { cleanup(dir) }
        let prefsURL = dir.appendingPathComponent("prefs.json")
        let initial = AppPreferences(branchSortRecencyFirst: false)

        let vm = PreferencesViewModel(
            preferencesURL: prefsURL,
            initial: initial,
            clock: Self.fixedClock
        )
        await vm.load()

        // Initial preserved (file didn't exist, so nothing to load).
        let prefs = await vm.preferences
        #expect(prefs == initial)

        let state = await vm.state
        if case let .success(timestamp) = state {
            #expect(timestamp == Date(timeIntervalSince1970: 1_715_000_000))
        } else {
            Issue.record("expected .success, got \(state)")
        }
    }

    // MARK: - Save then load round-trip

    @Test("save() writes JSON, subsequent load() reads it back")
    func saveLoadRoundTrip() async throws {
        let dir = try makeTempDir(tag: "save-load")
        defer { cleanup(dir) }
        let prefsURL = dir.appendingPathComponent("nested/prefs.json")
        let edited = AppPreferences(
            watchRoots: [URL(fileURLWithPath: "/tmp/x")],
            gitIdentity: GitIdentity(name: "Bee", email: "bee@example.com"),
            branchSortRecencyFirst: false
        )

        let writer = PreferencesViewModel(
            preferencesURL: prefsURL,
            initial: edited,
            clock: Self.fixedClock
        )
        await writer.save()
        let writerState = await writer.state
        if case .success = writerState {
            // ok
        } else {
            Issue.record("save() should be .success, got \(writerState)")
        }
        #expect(FileManager.default.fileExists(atPath: prefsURL.path))

        // A fresh VM with different initial defaults loads back the
        // saved value (proving the file actually drives the load).
        let reader = PreferencesViewModel(
            preferencesURL: prefsURL,
            initial: AppPreferences(),
            clock: Self.fixedClock
        )
        await reader.load()
        let loaded = await reader.preferences
        #expect(loaded == edited)
    }

    // MARK: - Save creates parent directories

    @Test("save() creates the parent directory if it doesn't exist")
    func saveCreatesParent() async throws {
        let dir = try makeTempDir(tag: "parent")
        defer { cleanup(dir) }
        let deepURL = dir
            .appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
            .appendingPathComponent("prefs.json")

        let vm = PreferencesViewModel(
            preferencesURL: deepURL,
            initial: AppPreferences(),
            clock: Self.fixedClock
        )
        await vm.save()
        #expect(await waitForFile(at: deepURL.path))
    }

    // MARK: - load() on malformed file fails

    @Test("load() on a malformed JSON file lands in .failure")
    func loadMalformedFails() async throws {
        let dir = try makeTempDir(tag: "malformed")
        defer { cleanup(dir) }
        let prefsURL = dir.appendingPathComponent("prefs.json")
        try Data("{ not json".utf8).write(to: prefsURL)

        let vm = PreferencesViewModel(
            preferencesURL: prefsURL,
            initial: AppPreferences(),
            clock: Self.fixedClock
        )
        await vm.load()

        let state = await vm.state
        if case .failure = state {
            // ok
        } else {
            Issue.record("expected .failure, got \(state)")
        }
    }

    // MARK: - update() doesn't persist

    @Test("update(_:) mutates in-memory but does NOT touch disk until save()")
    func updateDoesNotPersist() async throws {
        let dir = try makeTempDir(tag: "update-no-persist")
        defer { cleanup(dir) }
        let prefsURL = dir.appendingPathComponent("prefs.json")

        let vm = PreferencesViewModel(
            preferencesURL: prefsURL,
            initial: AppPreferences(),
            clock: Self.fixedClock
        )
        let updated = AppPreferences(branchSortRecencyFirst: false)
        await vm.update(updated)
        #expect(await vm.preferences == updated)
        // `update(_:)` is in-memory only; the file shouldn't materialize.
        // No `waitForFile` here — we're asserting non-existence, and on
        // every platform Foundation reports a not-yet-created file as
        // missing immediately.
        #expect(FileManager.default.fileExists(atPath: prefsURL.path) == false)

        await vm.save()
        #expect(await waitForFile(at: prefsURL.path))
    }

    // MARK: - reset() preserves preferences

    @Test("reset() returns state to .idle without disturbing preferences")
    func resetPreservesPreferences() async throws {
        let dir = try makeTempDir(tag: "reset")
        defer { cleanup(dir) }
        let prefsURL = dir.appendingPathComponent("prefs.json")

        let vm = PreferencesViewModel(
            preferencesURL: prefsURL,
            initial: AppPreferences(),
            clock: Self.fixedClock
        )
        let edited = AppPreferences(branchSortRecencyFirst: false)
        await vm.update(edited)
        await vm.save()
        #expect(await vm.state != .idle)

        await vm.reset()
        #expect(await vm.state == .idle)
        #expect(await vm.preferences == edited)
    }
}
