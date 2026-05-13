# Changelog

All notable changes to Sprig are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **IPCSchema v1 wire-format locked down** — the on-the-wire JSON envelope between `SprigAgent` and every consumer (FinderSync extension, Windows shell extension, `sprigctl`, task-window app) is now contractually frozen for the v1 schema version:
  - `packages/IPCSchema/STABILITY.md` — the wire-format policy. Names what's stable (envelope key set, every `kind` discriminator, every payload field name, sorted-key JSON output, ISO-8601 dates, `IPCError` cases) vs. what's safely extensible (new `EnvelopeMessage` cases, new optional payload fields, new wire-stable string-enum values). New variants must come with both encode-direction and decode-direction golden tests in the same PR.
  - `packages/IPCSchema/Tests/IPCSchemaTests/WireFormatGoldenTests.swift` — single source of truth for the v1 wire-format contract. Encode-golden (typed value → exact bytes) and decode-golden (exact bytes → typed value) for every variant of every `EnvelopeMessage` enum (`ClientRequest.{badgeQuery, subscribe}`, `AgentResponse.{badgeReply, subscribeAck, error}`, `AgentEvent.{badgeChanged, subscriptionEnded}`). The two-directional coverage catches silent wire drift in either direction, which round-trip-only tests miss when encoder + decoder co-evolve a breaking change in lockstep.
  - The pre-existing single-variant `wireShapeRegression()` tests in `EnvelopeTests.swift` + `AgentEventTests.swift` were superseded by the consolidated file and removed; their content lives in the new file alongside the previously-missing five variants' goldens.
- `sprigctl agent` subcommand (`sprigctl agent <repo> [--polling] [--polling-interval SECS] [--duration SECS] [--stats-interval SECS]`): runs the cross-platform `RepoAgent` host against a single repo and streams `Envelope<AgentEvent>` envelopes as JSON-per-line on stdout. Useful for ad-hoc debugging of the badge-update flow without a FinderSync extension. `--stats-interval` adds periodic `# stats: {…}` JSON lines on stderr summarizing the agent's `refreshes`, `outcome`, `entryCount`, and `firstDeferralAt` (the ADR 0066 stale-`index.lock` enabler).
- **AgentKit public surface** (consumed by `sprigctl agent` and the in-flight M2-Mac LaunchAgent host):
  - `RepoAgent` — long-lived per-repo host wiring watcher → refresh driver → status refresher → badge store → broadcaster → registry → sink. Exposes `refreshAttempts() / lastOutcome() / firstDeferralAt()` diagnostics.
  - `InMemoryBadgeEventSink` — `AsyncStream<Envelope<AgentEvent>>` sink for in-process consumption (CLI, tests).
  - `TransportBadgeEventSink` — wire-bound sink that JSON-encodes envelopes via `IPCSchema.EnvelopeCodec` and forwards to a `TransportKit.Transport`. Single-client hosts use this directly.
  - `RoutedBadgeEventSink` + `SubscriptionTransportRoutes` — multi-client variant: per-subscription routing so a host serving N concurrent clients delivers each event only to the transport that owns its subscription. Includes `unregisterAll(transport:)` for connection-disconnect cleanup.
  - `ClientRequestDispatcher` — inbound IPC half. Drains `Transport.messages()`, decodes `Envelope<ClientRequest>` (`subscribe` / `badgeQuery`), dispatches to the registry, writes correlated `Envelope<AgentResponse>` replies. Wire-stable error codes for unknown / malformed envelopes.
- `docs/architecture/agent-host.md` — composition reference for both single-client and multi-client agent host wiring; the M2-Mac LaunchAgent picks up this pattern with XPC swapped in for `InProcessTransport`.
