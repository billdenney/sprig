// AppPreferences.swift
//
// The app-wide user preferences value type, plus the git identity it
// carries. Pure Foundation, Tier 1.
//
// **Why this lives in PlatformKit and not TaskWindowKit.** Preferences
// are read by two very different layers: the Preferences task window
// (`TaskWindowKit.PreferencesViewModel`, which edits them) and the
// background agent (`AgentKit.AgentPreferencesWiring`, which maps them
// to job startups). They were originally declared next to the view
// model, which forced `AgentKit` — a Tier-2 adapter hosting a headless
// background loop — to depend on the whole view-model package just to
// read a settings struct. PlatformKit is the right shared floor: it is
// pure Foundation, already a dependency of every Tier-2 adapter by
// default, and already owns both `PathResolver` (which computes *where*
// this file is persisted) and `SyncPolicy` (the precedent for a policy
// value type living here).
//
// The view model that edits these, and the JSON I/O against a
// persistence URL, stay in `TaskWindowKit.PreferencesViewModel` — this
// file is the shape only, with no behavior beyond Codable.

import Foundation

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

    /// Keep submodules reconciled with the super-repo by default
    /// (ADR 0096) — `SubmoduleUpdate.reconcile` runs `git submodule
    /// update --init --recursive` (no `--force`, dirty submodules
    /// skipped + reported). Default **on**: submodules are tracked by
    /// default, and the op never clobbers local work. Wiring into the
    /// branch-switch / sync / auto-sync flows is the ADR 0096 follow-up.
    public var submoduleAutoUpdateEnabled: Bool

    /// Hours between repeats of the ADR 0096 submodule-update
    /// suggestion for one repo (`SubmoduleSuggestionThrottle`).
    /// Default 4. `<= 0` disables throttling (the suggestion may show
    /// on every refresh).
    public var submoduleSuggestionThrottleHours: Int

    /// Pass `--recurse-submodules` to the ADR 0096 fetch flows and run
    /// a post-fast-forward `submodule update`. Default **on** (tracked
    /// by default). Reserved for the ADR 0096 follow-up that wires it
    /// into `SyncViewModel` / `BranchSwitcherViewModel` /
    /// `AutoSyncScheduler`; defined here so the prefs schema is stable
    /// when that lands.
    public var fetchRecurseSubmodules: Bool

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
        suppressedGuardRails: [String] = [],
        submoduleAutoUpdateEnabled: Bool = true,
        submoduleSuggestionThrottleHours: Int = 4,
        fetchRecurseSubmodules: Bool = true
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
        self.submoduleAutoUpdateEnabled = submoduleAutoUpdateEnabled
        self.submoduleSuggestionThrottleHours = submoduleSuggestionThrottleHours
        self.fetchRecurseSubmodules = fetchRecurseSubmodules
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
        submoduleAutoUpdateEnabled = try container
            .decodeIfPresent(Bool.self, forKey: .submoduleAutoUpdateEnabled) ?? true
        submoduleSuggestionThrottleHours = try container
            .decodeIfPresent(Int.self, forKey: .submoduleSuggestionThrottleHours) ?? 4
        fetchRecurseSubmodules = try container
            .decodeIfPresent(Bool.self, forKey: .fetchRecurseSubmodules) ?? true
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
