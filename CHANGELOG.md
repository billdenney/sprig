# Changelog

All notable changes to Sprig are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- Initial project scaffolding: three-tier package structure, ADRs 0001–0053, CI matrix (macOS 14/15 + Linux Swift 6.3 + Windows Swift 6.3), SwiftLint rules enforcing cross-platform discipline.
- `sprigctl agent` subcommand (`sprigctl agent <repo> [--polling] [--polling-interval SECS] [--duration SECS] [--stats-interval SECS]`): runs the cross-platform `RepoAgent` host against a single repo and streams `Envelope<AgentEvent>` envelopes as JSON-per-line on stdout. Useful for ad-hoc debugging of the badge-update flow without a FinderSync extension. `--stats-interval` adds periodic `# stats: {…}` JSON lines on stderr summarizing the agent's `refreshes`, `outcome`, `entryCount`, and `firstDeferralAt` (the ADR 0066 stale-`index.lock` enabler).
- **AgentKit public surface** (consumed by `sprigctl agent` and the in-flight M2-Mac LaunchAgent host):
  - `RepoAgent` — long-lived per-repo host wiring watcher → refresh driver → status refresher → badge store → broadcaster → registry → sink. Exposes `refreshAttempts() / lastOutcome() / firstDeferralAt()` diagnostics.
  - `InMemoryBadgeEventSink` — `AsyncStream<Envelope<AgentEvent>>` sink for in-process consumption (CLI, tests).
  - `TransportBadgeEventSink` — wire-bound sink that JSON-encodes envelopes via `IPCSchema.EnvelopeCodec` and forwards to a `TransportKit.Transport`. Single-client hosts use this directly.
  - `RoutedBadgeEventSink` + `SubscriptionTransportRoutes` — multi-client variant: per-subscription routing so a host serving N concurrent clients delivers each event only to the transport that owns its subscription. Includes `unregisterAll(transport:)` for connection-disconnect cleanup.
  - `ClientRequestDispatcher` — inbound IPC half. Drains `Transport.messages()`, decodes `Envelope<ClientRequest>` (`subscribe` / `badgeQuery`), dispatches to the registry, writes correlated `Envelope<AgentResponse>` replies. Wire-stable error codes for unknown / malformed envelopes.
- `docs/architecture/agent-host.md` — composition reference for both single-client and multi-client agent host wiring; the M2-Mac LaunchAgent picks up this pattern with XPC swapped in for `InProcessTransport`.
