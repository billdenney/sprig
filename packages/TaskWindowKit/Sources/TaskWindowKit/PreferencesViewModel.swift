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
import SafetyKit

/// User-editable Sprig preferences persisted as JSON.
///
/// Codable + Sendable + Equatable so the VM can serialize / round-trip /
/// observe it across the actor boundary. Adding a new field is
/// additive: an old JSON file without the field decodes with the
/// default value, an old build reading a new JSON file ignores the
/// unknown fields. **Don't** rename or remove existing fields without
/// a schema-migration plan.
public struct AppPreferences: Sendable, Codable, Equatable {
    /// Schema version. `1` is the first shipping shape; bump when
    /// adding a field would break old readers (which we should
    /// otherwise avoid).
    public var schemaVersion: Int

    /// Directories Sprig watches for repos (per ADR 0025
    /// user-added watch roots). Stored as `URL` for type safety;
    /// serializes as plain string paths in JSON.
    public var watchRoots: [URL]

    /// Default git identity for new commits, or `nil` to defer to
    /// `~/.gitconfig` (the typical case until the user opts into a
    /// Sprig-managed identity). Multi-identity profiles (ADR 0041)
    /// land in a future VM that wraps this one.
    public var gitIdentity: GitIdentity?

    /// Sort branches by recency (`-committerdate`) instead of
    /// alphabetical (default true per ADR 0026's modern-config
    /// bundle).
    public var branchSortRecencyFirst: Bool

    /// Background `git fetch --all --prune` per watched repo
    /// (ADR 0068). Default **on** — fetch is read-only and the
    /// behind/ahead badges depend on it.
    public var autoFetchEnabled: Bool

    /// Minutes between background fetches. ADR 0068 default: 60.
    /// The Status task window's per-repo override (ADR 0064) layers
    /// on top of this app-wide value.
    public var autoFetchIntervalMinutes: Int

    /// After each background fetch, fast-forward local branches that
    /// are strictly behind their upstream (and the working directory
    /// for the checked-out branch). Fail-closed: never merges,
    /// rebases, or touches a dirty worktree. Default **off**
    /// (ADR 0068: an unattended process mutating the working
    /// directory is opt-in).
    public var autoPullFastForward: Bool

    /// Periodically snapshot a dirty working tree into
    /// `refs/sprig/backup/…` (ADR 0075) — crash/oops insurance for
    /// work that was never committed. Default **on**: it's pure-local,
    /// touches nothing the user sees, and is TTL-bounded.
    public var autoBackupEnabled: Bool

    /// Minutes between backup ticks. ADR 0075 default: 30.
    public var autoBackupIntervalMinutes: Int

    /// Days a backup survives before the per-tick prune removes it.
    /// ADR 0075 default: 7.
    public var autoBackupTTLDays: Int

    /// Guard-rail IDs the user opted out of via the warning banner's
    /// "never show this again" checkbox (ADR 0070 amendment). Values
    /// are `PreflightWarning.railID` strings; shells pass this into
    /// `PreflightChecks(suppressedRails:)`. Empty by default.
    public var suppressedGuardRails: [String]

    public init(
        schemaVersion: Int = 1,
        watchRoots: [URL] = [],
        gitIdentity: GitIdentity? = nil,
        branchSortRecencyFirst: Bool = true,
        autoFetchEnabled: Bool = true,
        autoFetchIntervalMinutes: Int = 60,
        autoPullFastForward: Bool = false,
        autoBackupEnabled: Bool = true,
        autoBackupIntervalMinutes: Int = 30,
        autoBackupTTLDays: Int = 7,
        suppressedGuardRails: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.watchRoots = watchRoots
        self.gitIdentity = gitIdentity
        self.branchSortRecencyFirst = branchSortRecencyFirst
        self.autoFetchEnabled = autoFetchEnabled
        self.autoFetchIntervalMinutes = autoFetchIntervalMinutes
        self.autoPullFastForward = autoPullFastForward
        self.autoBackupEnabled = autoBackupEnabled
        self.autoBackupIntervalMinutes = autoBackupIntervalMinutes
        self.autoBackupTTLDays = autoBackupTTLDays
        self.suppressedGuardRails = suppressedGuardRails
    }

    /// Custom decode so preference files written before the ADR 0068 /
    /// ADR 0075 fields existed load with the documented defaults
    /// instead of failing on the missing keys ("adding a field is
    /// additive").
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        watchRoots = try container.decode([URL].self, forKey: .watchRoots)
        gitIdentity = try container.decodeIfPresent(GitIdentity.self, forKey: .gitIdentity)
        branchSortRecencyFirst = try container.decode(Bool.self, forKey: .branchSortRecencyFirst)
        autoFetchEnabled = try container
            .decodeIfPresent(Bool.self, forKey: .autoFetchEnabled) ?? true
        autoFetchIntervalMinutes = try container
            .decodeIfPresent(Int.self, forKey: .autoFetchIntervalMinutes) ?? 60
        autoPullFastForward = try container
            .decodeIfPresent(Bool.self, forKey: .autoPullFastForward) ?? false
        autoBackupEnabled = try container
            .decodeIfPresent(Bool.self, forKey: .autoBackupEnabled) ?? true
        autoBackupIntervalMinutes = try container
            .decodeIfPresent(Int.self, forKey: .autoBackupIntervalMinutes) ?? 30
        autoBackupTTLDays = try container
            .decodeIfPresent(Int.self, forKey: .autoBackupTTLDays) ?? 7
        suppressedGuardRails = try container
            .decodeIfPresent([String].self, forKey: .suppressedGuardRails) ?? []
    }
}

/// A name + email pair. Mirrors `user.name` + `user.email` in
/// `~/.gitconfig`. Used by ``AppPreferences/gitIdentity`` (single
/// identity, MVP cut).
public struct GitIdentity: Sendable, Codable, Equatable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

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
