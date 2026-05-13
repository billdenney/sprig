# Changelog

All notable changes to Sprig are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **M1 → M2 exit gate wired into hosted CI — all three criteria** now enforced on every PR across macOS / Linux / Windows via the new `tests/integration/` target:
  - `SprigctlStatusByteMatchTests` — `PorcelainV2Parser.parse(_:)` correctness across the documented fixture states (clean / modified / staged / both / untracked / deleted / renamed / gitignored / merge-conflict). Closes M1's parser-fidelity exit criterion. Interpretation note in `docs/planning/milestones.md`: sprigctl status itself emits human-readable / JSON output, so the literal "byte equality of binary outputs" wording was impossible by design; the honest test is parser correctness, which this PR enforces.
  - `WatcherEventBudgetTests` — `EventCoalescer` ingests + drains 10k synthetic `WatchEvent` values within a single-core wall-clock budget (1 s ceiling vs. typical ~30 ms locally). Closes M1's watcher-CPU exit criterion as a wall-clock proxy (CPU % isn't portably readable from inside swift-testing).
  - `Status100kFileBudgetTests` — synthesizes a 100 000-file repo via `FixtureSynthesizer.makeRepoWithFileCount(_:)`, runs `git status --porcelain=v2 -z` + `PorcelainV2Parser.parse(_:)` against it, asserts the measured window completes inside a 60 s wall-clock ceiling. Hosted-CI smoke for M1's third exit criterion — catches catastrophic regressions (orders-of-magnitude blow-outs in parse time, accidental O(N²) walks) without waiting on self-hosted runner provisioning. The fine-grained perf comparisons (sustained CPU%, peak RSS, latency distributions per ADR 0021) still need stable hardware; the existing `Benchmarks/SprigCoreBenchmarks.swift` ladder is **extended to 100k** here so those measurements run automatically when the self-hosted runner comes online (see `docs/ci/self-hosted.md`).
  - New shared `IntegrationSupport` library hosts `FixtureSynthesizer` (clean / modified / staged / staged-and-modified / untracked / deleted / merge-conflict / renamed / gitignored repo synthesizers backed by real `git init` + `git commit`, plus `makeRepoWithFileCount(_:dirtyFraction:_:)` for scale tests). Available for the benchmark target to consume in a follow-up PR, replacing the inline synthesizers in `Benchmarks/SprigCoreBenchmarks.swift`.
- Initial project scaffolding: three-tier package structure, ADRs 0001–0053, CI matrix (macOS 14/15 + Linux Swift 6.3 + Windows Swift 6.3), SwiftLint rules enforcing cross-platform discipline.
- `sprigctl agent` subcommand (`sprigctl agent <repo> [--polling] [--polling-interval SECS] [--duration SECS] [--stats-interval SECS]`): runs the cross-platform `RepoAgent` host against a single repo and streams `Envelope<AgentEvent>` envelopes as JSON-per-line on stdout. Useful for ad-hoc debugging of the badge-update flow without a FinderSync extension. `--stats-interval` adds periodic `# stats: {…}` JSON lines on stderr summarizing the agent's `refreshes`, `outcome`, `entryCount`, and `firstDeferralAt` (the ADR 0066 stale-`index.lock` enabler).
- **AgentKit public surface** (consumed by `sprigctl agent` and the in-flight M2-Mac LaunchAgent host):
  - `RepoAgent` — long-lived per-repo host wiring watcher → refresh driver → status refresher → badge store → broadcaster → registry → sink. Exposes `refreshAttempts() / lastOutcome() / firstDeferralAt()` diagnostics.
  - `InMemoryBadgeEventSink` — `AsyncStream<Envelope<AgentEvent>>` sink for in-process consumption (CLI, tests).
  - `TransportBadgeEventSink` — wire-bound sink that JSON-encodes envelopes via `IPCSchema.EnvelopeCodec` and forwards to a `TransportKit.Transport`. Single-client hosts use this directly.
  - `RoutedBadgeEventSink` + `SubscriptionTransportRoutes` — multi-client variant: per-subscription routing so a host serving N concurrent clients delivers each event only to the transport that owns its subscription. Includes `unregisterAll(transport:)` for connection-disconnect cleanup.
  - `ClientRequestDispatcher` — inbound IPC half. Drains `Transport.messages()`, decodes `Envelope<ClientRequest>` (`subscribe` / `badgeQuery`), dispatches to the registry, writes correlated `Envelope<AgentResponse>` replies. Wire-stable error codes for unknown / malformed envelopes.
- `docs/architecture/agent-host.md` — composition reference for both single-client and multi-client agent host wiring; the M2-Mac LaunchAgent picks up this pattern with XPC swapped in for `InProcessTransport`.
