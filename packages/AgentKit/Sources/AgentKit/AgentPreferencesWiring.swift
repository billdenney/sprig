// AgentPreferencesWiring.swift
//
// The one mapping from the user's `AppPreferences` to the agent's
// background-job startups (ADR 0068 auto-sync, ADR 0075 auto-backup).
// Every agent host — `sprigctl agent --preferences` today, the macOS
// LaunchAgent and Windows Service later — calls this instead of
// re-deriving intervals and TTLs from raw preference fields, so a
// preferences file means the same thing under every host.
//
// Cadence knobs not expressed in preferences (jitter, fire-on-start)
// keep the ADR defaults: fetch fires once at host start (a
// newly-launched agent syncs promptly), backup does not (an immediate
// backup at launch would mostly duplicate the previous session's
// last tick).

import Foundation
import PlatformKit

/// Pure `AppPreferences` → startup-configuration mapping.
public enum AgentPreferencesWiring {
    /// ADR 0068: nil when auto-fetch is disabled; otherwise the
    /// user's interval with the default jitter and fetch-on-start.
    public static func autoSyncStartup(from prefs: AppPreferences) -> AutoSyncStartup? {
        guard prefs.autoFetchEnabled else { return nil }
        return AutoSyncStartup(
            configuration: AutoSyncConfiguration(
                interval: .seconds(prefs.autoFetchIntervalMinutes * 60)
            ),
            fastForwardPull: prefs.autoPullFastForward
        )
    }

    /// ADR 0075: nil when auto-backup is disabled; otherwise the
    /// user's interval + TTL with the default jitter and no
    /// fire-on-start.
    public static func autoBackupStartup(from prefs: AppPreferences) -> AutoBackupStartup? {
        guard prefs.autoBackupEnabled else { return nil }
        return AutoBackupStartup(
            configuration: AutoSyncConfiguration(
                interval: .seconds(prefs.autoBackupIntervalMinutes * 60),
                fireOnStart: false
            ),
            ttl: TimeInterval(prefs.autoBackupTTLDays) * 86400
        )
    }
}
