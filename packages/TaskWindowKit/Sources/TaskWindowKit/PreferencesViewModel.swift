// PreferencesViewModel.swift
//
// Sixth and final M3 view model — the portable engine behind the
// macOS/Windows "Preferences…" task window. Holds the AppPreferences
// the UI is editing, persists them as JSON to an injected URL.
//
// Tier 1, portable. Per ADR 0048, view models live here; the per-OS
// shells in `apps/{macos,windows}/` bind to this VM's `preferences`
// and `state`.
//
// **Persistence path is INJECTED, not computed.** A PathResolver in
// PlatformKit (master plan §2 / ADR 0048) will eventually compute the
// platform-correct app-support directory; this VM stays portable by
// accepting whatever `preferencesURL` the caller hands it. The shell
// passes `~/Library/Application Support/Sprig/prefs.json` on macOS,
// `%APPDATA%\Sprig\prefs.json` on Windows, `$XDG_CONFIG_HOME/sprig/
// prefs.json` on Linux. Tests use a temp-dir path.
//
// What this VM owns:
//   - The in-memory AppPreferences struct the user is editing.
//   - Codable JSON I/O against `preferencesURL`.
//   - Lifecycle state of the latest load / save call.
//
// What this VM doesn't own (deliberately):
//   - Path resolution for the persistence file — see note above.
//   - Per-preference validation beyond "is this Codable" — fields
//     that need sanity checks (e.g. watchRoots existing on disk)
//     surface validation through the consumer that reads them. The
//     VM only persists what it's told.
//   - Schema migrations across Sprig versions. The first persisted
//     prefs version is `1`; bumping the version + writing a migrator
//     is a future iteration's concern.
//   - Identity profiles (ADR 0041 first-class) — modeled here as a
//     single optional `gitIdentity` for the MVP cut. Multi-identity
//     becomes its own VM that wraps this one.

import Foundation
import PlatformKit
import SafetyKit

// `AppPreferences` and `GitIdentity` — the shape this VM edits — live in
// `PlatformKit` so the headless agent (`AgentKit.AgentPreferencesWiring`)
// can read them without depending on the view-model layer. See
// `PlatformKit/AppPreferences.swift` for the rationale.

/// View model for the Preferences task window. Holds the prefs being
/// edited, loads from / saves to an injected JSON file.
///
/// **Actor-isolated.** All mutable state lives behind the actor.
///
/// **Lifecycle.** Construct with the persistence URL and an
/// `initialPreferences` (the defaults the UI seeds the form with).
/// Call ``load()`` on open — if the file exists it overwrites
/// `preferences`; if not, `preferences` stays at the initial value
/// and `state` lands in `.success` with the load timestamp (loading
/// a not-yet-written prefs file is normal, not an error). The UI
/// calls ``update(_:)`` as the user edits; ``save()`` writes the
/// current value back.
public actor PreferencesViewModel {
    /// Where the JSON file lives. Injected so callers (shells,
    /// tests) decide the platform-correct app-support path.
    public let preferencesURL: URL

    /// The preferences currently being edited. Modified via
    /// ``update(_:)``; reset to the on-disk value by ``load()``.
    public private(set) var preferences: AppPreferences

    /// State of the latest load / save call. Success payload is the
    /// `Date` of the operation — pairs with a "saved at HH:MM"
    /// indicator in the UI without needing extra state.
    public private(set) var state: TaskWindowState<Date> = .idle

    /// In-flight Task, retained so ``cancel`` can interrupt it.
    private var runningTask: Task<Void, Never>?

    /// Clock injection point. Tests pass a fixed clock; production
    /// uses ``defaultClock``.
    private let clock: @Sendable () -> Date

    /// `{ Date() }` lifted to a `@Sendable` closure once at module
    /// load so the default parameter doesn't trip Swift 6's strict
    /// concurrency checking.
    public static let defaultClock: @Sendable () -> Date = { Date() }

    public init(
        preferencesURL: URL,
        initial: AppPreferences = AppPreferences(),
        clock: @Sendable @escaping () -> Date = PreferencesViewModel.defaultClock
    ) {
        self.preferencesURL = preferencesURL
        self.preferences = initial
        self.clock = clock
    }

    // MARK: - Form updates

    /// Replace the in-memory ``preferences`` with a new value. Does
    /// not persist; callers follow up with ``save()`` when ready.
    public func update(_ new: AppPreferences) {
        preferences = new
    }

    // MARK: - I/O

    /// Read the JSON file at ``preferencesURL`` into ``preferences``.
    /// If the file does not exist, leaves the current in-memory
    /// preferences untouched and lands in `.success` (a missing
    /// prefs file is normal on first run — the defaults are correct).
    public func load() async {
        state = .busy(progress: nil)
        let url = preferencesURL
        let timestamp = clock()

        runningTask = Task { [weak self] in
            do {
                let exists = FileManager.default.fileExists(atPath: url.path)
                guard exists else {
                    await self?.recordSuccess(at: timestamp)
                    return
                }
                let data = try Data(contentsOf: url)
                let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
                await self?.recordLoaded(decoded, at: timestamp)
            } catch is CancellationError {
                await self?.recordFailure(.init(
                    description: TaskWindowVocabulary.cancelled("Preferences load")
                ))
            } catch {
                await self?.recordFailure(.init(from: error))
            }
        }

        await runningTask?.value
    }

    /// Encode the current ``preferences`` as pretty-printed,
    /// sorted-keys JSON and write to ``preferencesURL``. Creates the
    /// parent directory if missing. Failures (read-only target,
    /// permission denied) surface via ``state``.
    public func save() async {
        state = .busy(progress: nil)
        let url = preferencesURL
        let snapshot = preferences
        let timestamp = clock()

        runningTask = Task { [weak self] in
            do {
                let parent = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                // Routes through AtomicWriteWithRetry to absorb
                // transient Windows file-sharing violations
                // (Defender's real-time scanner, editors holding the
                // prefs file open, etc.). Single attempt on macOS /
                // Linux; up to ~64 s of backoff retry on Windows.
                try await AtomicWriteWithRetry.run(data, to: url)
                await self?.recordSuccess(at: timestamp)
            } catch is CancellationError {
                await self?.recordFailure(.init(
                    description: TaskWindowVocabulary.cancelled("Preferences save")
                ))
            } catch {
                await self?.recordFailure(.init(from: error))
            }
        }

        await runningTask?.value
    }

    // MARK: - State

    /// Cancel the in-flight load / save, if any.
    public func cancel() {
        runningTask?.cancel()
    }

    /// Reset state to `.idle`. Preserves the in-memory `preferences`.
    public func reset() {
        runningTask?.cancel()
        runningTask = nil
        state = .idle
    }

    // MARK: - Private transitions

    private func recordLoaded(_ loaded: AppPreferences, at timestamp: Date) {
        runningTask = nil
        preferences = loaded
        state = .success(timestamp)
    }

    private func recordSuccess(at timestamp: Date) {
        runningTask = nil
        state = .success(timestamp)
    }

    private func recordFailure(_ failure: TaskWindowState<Date>.Failure) {
        runningTask = nil
        state = .failure(failure)
    }
}
