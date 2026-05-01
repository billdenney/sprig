// IPCSchema — portable (Tier 1) package. No UI, no platform APIs.
// Must compile on macOS, Linux, and Windows Swift 6.3.
// See CLAUDE.md and ADR 0048 for cross-platform discipline.
//
// Wire format between SprigAgent (LaunchAgent on macOS, Windows
// Service on Windows) and consumers — shell extensions, sprigctl,
// future task-window apps. JSON over XPC on macOS, JSON over named
// pipes on Windows; the schema is transport-agnostic.

import Foundation

public enum IPCSchema {
    public static let moduleName = "IPCSchema"

    /// Current envelope schema version. Bumped on **breaking** wire
    /// changes (field removal, kind enum reduction). Adding new
    /// optional fields or new message kinds is backward-compatible
    /// and does NOT bump this.
    ///
    /// Receivers must reject envelopes whose `schemaVersion` is
    /// strictly greater than this — they don't know how to interpret
    /// the future format. Older versions are rejected the same way
    /// (Sprig releases drop support N versions back; today, only v1).
    public static let currentSchemaVersion: Int = 1

    /// Lowest envelope version this build still parses. Same as
    /// `currentSchemaVersion` today; bumped only when we drop support
    /// for a previous wire format.
    public static let minimumSupportedSchemaVersion: Int = 1
}
