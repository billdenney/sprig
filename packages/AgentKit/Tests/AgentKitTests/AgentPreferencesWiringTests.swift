// AgentPreferencesWiringTests.swift
//
// Pure mapping tests: the user's preferences must mean the same
// background-job configuration under every agent host. Pins the
// documented defaults (fetch hourly ON + fire-on-start, FF-pull OFF,
// backup 30 min ON without fire-on-start, TTL 7 days), the disable
// toggles, and the unit conversions (minutes → Duration, days →
// TimeInterval).

@testable import AgentKit
import Foundation
import TaskWindowKit
import Testing

@Suite("AgentPreferencesWiring — AppPreferences → startups (pure)")
struct AgentPreferencesWiringTests {
    @Test("defaults: hourly fetch with fire-on-start and no ff-pull; 30-min backup, 7-day TTL")
    func defaultsMap() throws {
        let prefs = AppPreferences()

        let sync = try #require(AgentPreferencesWiring.autoSyncStartup(from: prefs))
        #expect(sync.configuration == AutoSyncConfiguration(interval: .seconds(3600)))
        #expect(sync.configuration.fireOnStart, "a newly-launched host fetches promptly")
        #expect(!sync.fastForwardPull, "the default pull stays opt-in (ADR 0068)")

        let backup = try #require(AgentPreferencesWiring.autoBackupStartup(from: prefs))
        #expect(backup.configuration == AutoSyncConfiguration(
            interval: .seconds(1800),
            fireOnStart: false
        ))
        #expect(backup.ttl == 7 * 86400)
    }

    @Test("disable toggles map to nil — the agent starts no scheduler at all")
    func disabledTogglesMapToNil() {
        var prefs = AppPreferences()
        prefs.autoFetchEnabled = false
        prefs.autoBackupEnabled = false
        #expect(AgentPreferencesWiring.autoSyncStartup(from: prefs) == nil)
        #expect(AgentPreferencesWiring.autoBackupStartup(from: prefs) == nil)
    }

    @Test("custom intervals, ff-pull, and TTL carry through with correct units")
    func customValuesCarry() throws {
        var prefs = AppPreferences()
        prefs.autoFetchIntervalMinutes = 15
        prefs.autoPullFastForward = true
        prefs.autoBackupIntervalMinutes = 60
        prefs.autoBackupTTLDays = 3

        let sync = try #require(AgentPreferencesWiring.autoSyncStartup(from: prefs))
        #expect(sync.configuration.interval == .seconds(900))
        #expect(sync.fastForwardPull)

        let backup = try #require(AgentPreferencesWiring.autoBackupStartup(from: prefs))
        #expect(backup.configuration.interval == .seconds(3600))
        #expect(backup.ttl == 3 * 86400)
    }
}
