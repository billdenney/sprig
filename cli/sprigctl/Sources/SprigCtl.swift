// sprigctl — Sprig's command-line companion.
//
// This is the M1 exit-criterion tool: `sprigctl status <path>` dumps the
// parsed PorcelainV2Status. Its job is to demonstrate GitCore end-to-end
// outside any GUI and to give the test suite a real binary to exercise.
//
// Lives under `cli/` (not `apps/`) because it's OS-agnostic and has no UI.
// It links only against GitCore + swift-argument-parser so the portability
// rules in ADR 0048 apply: no AppKit, no FinderSync, no platform SDKs.

import ArgumentParser

@main
struct SprigCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sprigctl",
        abstract: "Sprig's command-line companion for introspecting git state.",
        version: "0.1.0",
        subcommands: [VersionCommand.self, StatusCommand.self]
    )
}
