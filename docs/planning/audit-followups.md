# Audit follow-ups — durable tracker

Each entry here is a known failure mode identified by an audit (per `risk-register.md`'s audit obligations) plus the deferred fix that closes it. Items move from "Pending" to "Closed" as their fixing PRs land. This file is the source of truth for which audit findings are still open; in-code `// TODO(<finding-id>):` markers point back here.

The format is loosely modeled on `docs/planning/disabled-tests.md`: a single grep-able file beats scattered issues. Audit follow-ups are NOT optional — they're debt notes we promise to pay when their trigger conditions arrive.

## Pending

### `VM-ENV-1` — Two environmental test members fail every full Windows-VM sweep under load; gate adjusted with isolated receipts

- **Origin:** Not an internal audit — an environmental failure mode of the local Windows test VM (`dockur/windows` Server 2022, mirroring the GitHub `windows-2022` runner), ratified into an adjusted gate by the maintainer (2026-06, in-session). Tracked here because the discipline fits and the ratification previously lived only in conversation — exactly the scattered-state this tracker exists to prevent.
- **Where:** `PreferencesViewModelTests` "save() writes JSON, subsequent load() reads it back" and `MergeConflictResolverPerRegionTests` "text(regions:) with [.ours, .theirs] splices each region". `RepoAgentAutoBackupTests` "agent with AutoBackupStartup backs up a dirty tree on its tick" joined the family once (2026-06-11) — on the watch list, same treatment. Linux-local cousin, also watch-listed (one occurrence, 2026-06-11): `SprigctlAgentTests/socketServesSubscriber` (the two-process UDS e2e) once saw `subscriptionEnded(agent_shutdown)` instead of `badgeChanged` under full-suite load — the agent's `--duration` expired before the event propagated; 3× isolated passes at ~8 s on the same tree.
- **Symptom:** Under full-suite load (~1,180 tests, the suites in question landing 100+ seconds into the run), file writes become invisible to subsequent reads/subprocesses for 60–90+ s (ERROR_SHARING_VIOLATION retry ladders, `waitForFile` expiring). The same tests pass **isolated in 0.1–4 s, every time** — dozens of receipts on record. Hosted Windows CI (different load profile, more cores) has never shown the signature. Distinct from the *deterministic* CRLF class (quirk G1): this one is load-dependent; that one fails isolated too.
- **Adjusted gate (the ratified protocol, also in `docs/ci/slice-gate.md`):** a full-VM sweep whose only failures are these members is treated as green **if and only if** each failing member then passes an isolated `--filter` run on the same tree (the receipt). Any *other* failure, or an isolated-run failure, is a real regression — the stash-browser CRLF bug was caught precisely because it failed the isolated run.
- **Why not loosen the assertions:** `PreferencesViewModelTests` already polls with `waitForFile`; the pathological window under load exceeds any reasonable budget. Loosening further would blunt the tests on the platforms where they're sharp. The holder is the AV/scanner/FS, not the assertions.
- **Trigger (b) fired — investigated 2026-06-16.** Hosted Windows CI *did* reproduce the `waitForFile` signature (`PreferencesViewModelTests.updateDoesNotPersist`, PR #156 CI run). Per the protocol, this triggered a real investigation:
  - A Windows-VM probe (`WindowsHandleInheritanceProbe`, since removed) **refuted** the standing "concurrent child-process handle inheritance" hypothesis: a Foundation `Process` child spawned with redirected stdio does **not** inherit the parent's open file handle (the held-handle atomic write succeeds while the child is alive). So the holder is NOT a git child, and a spawn handle-allowlist (`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`) would have been the wrong fix.
  - The remaining external holder is a **scanner/FS**, with the real-time scanner the leading candidate — but NOT yet confirmed on hosted CI. (Conflicting prior notes: the test header says VM Defender exclusions were tried and "streaks persisted"; the `sprig_windows_vm_testing` note claims hosted windows-2022 runners already ship exclusions. If the latter holds, the hosted holder is FS-contention, not Defender.) `ci-windows.yml` now adds work/temp/process exclusions (low-risk on an ephemeral runner) **and** a diagnostic that prints the scanner's pre-existing state + exclusions BEFORE touching anything — so the next hosted run resolves this empirically rather than by assertion.
- **Trigger to close:** the diagnostic shows the scanner was active+unexcluded AND the exclusion holds across several hosted-Windows runs with no `waitForFile` recurrence. If the diagnostic shows the runner already excluded the work dir (scanner not the holder), reclassify to FS-contention and fall back to the adjusted-gate/re-run posture. The local-VM `I/O-starvation` note persists until the VM gains IO headroom regardless.
- **Owner:** me (receipts per slice + the CI fix), maintainer (VM sizing).
- **Severity:** Low (verification overhead + an intermittent hosted-CI red until the Defender fix is confirmed; no shipped-code risk).

### `UP-5472` — Re-pin Linux toolchain to a stable release once one ships the upstream `Process.run()` fix

- **Origin:** Not an internal audit — an upstream swift-corelibs-foundation bug ([swiftlang/swift-corelibs-foundation#5472](https://github.com/swiftlang/swift-corelibs-foundation/issues/5472)) tracked here because the discipline fits: temporary pin now, durable removal trigger.
- **Where:** `.swift-version` + `.github/workflows/ci-linux.yml` (container image pin) — Linux only; macOS CI uses Xcode's toolchain and the Windows toolchain is unaffected (the buggy `/proc/self/fd` scan is Linux-only code).
- **Symptom (pre-pin):** On Linux, `Process.run()` scans `/proc/self/fd` via `findMaximumOpenFromProcSelfFD()` and memcpy's a fixed 256 bytes of each dirent's `d_name`, over-reading short records (crash frame: `__memmove_avx_unaligned_erms` ← `Process.run()`). When the final record lands near an unmapped page the whole test process SIGSEGVs. Grew from a 1-in-20 hosted-CI flake (the reason ci-linux.yml has its 3× retry loop) to 3-of-3 retry exhaustion as the suite's real-git spawn count grew past ~900 tests.
- **Why a snapshot pin and not a code workaround:** Serializing all `process.run()` launches through a global lock was implemented and empirically disproven — the crash reproduced *inside* the serialized window (the over-read needs only fd-table geometry, not a concurrent scan). The fix upstream (`81eb85a`, merged 2026-05-19) is in no stable release: 6.3.2 predates it (`ahead_by: 73`) and `release/6.4.x` branched 6 commits before it (`ahead_by: 6`). Only `main` snapshots contain it.
- **Pin shipped:** `.swift-version` → `main-snapshot-2026-05-27` (swiftly-managed local dev) and the ci-linux.yml container → the matching `swiftlang/swift:nightly-main-noble` digest. The 3× retry loop in ci-linux.yml stays as defense-in-depth until the pin is gone.
- **Re-check log:** every housekeeping pass compares `release/6.4.x...81eb85a`. Latest (2026-06-11): still `ahead_by: 6` — the release branch has not absorbed the fix. Staged plan (maintainer-approved 2026-06-10): the moment it lands, Linux AND Windows move together to that 6.4 snapshot; both pin to 6.4 stable when it ships, closing this entry. macOS stays on Xcode throughout.
- **Trigger to close:** Whichever lands first — (a) `release/6.4.x` absorbs the fix via the upstream automerge cadence and a 6.4.x snapshot/release ships it, or (b) a 6.3.x patch release cherry-picks it. Closing PR: move `.swift-version` + ci-linux.yml back to the stable release, then (separate follow-up after a few weeks green) consider removing the retry loop.
- **Owner:** maintainer + me.
- **Severity:** High while open (was failing every Linux CI run on main; with the pin, expected solid green).

### `R15-F1` — `GitCore.Runner` retries on git-side lock contention

- **Origin:** `docs/planning/multi-agent-audit-2026-05.md` finding F1 (Medium severity).
- **Where:** `packages/GitCore/Sources/GitCore/Runner.swift` — `Runner.run(_:cwd:stdin:throwOnNonZero:)`.
- **Symptom:** Sprig-initiated *write* git ops (`git config`, `git stash`, `git add`) fail with `GitError.nonZeroExit` when another agent is mid-mutation and holding `index.lock` / `packed-refs.lock` / etc. Stderr matches `Unable to create '*.lock': File exists`.
- **Proposed fix:** Add an opt-in `retryOnLockContention: RetryPolicy = .none` parameter on `run(...)`. `RetryPolicy.exponential(maxAttempts: 3)` matches typical lockfile lifetime (<100 ms). Detect by stderr pattern match.
- **Trigger to ship:** First Sprig-spawned write that fails with this signature in CI or a user report. Without a real failure, the speculative retry adds complexity for no proven benefit.
- **Owner:** maintainer (audit) + me (drives the fix PR).
- **Severity:** Medium (read ops are unaffected; only Sprig-initiated writes during external-agent windows).

### `R15-F2` — `GitCore.CatFileBatch` restart-after-repack

- **Origin:** F2 (High severity).
- **Where:** `packages/GitCore/Sources/GitCore/CatFileBatch.swift` — `CatFileBatch` actor.
- **Symptom:** After `git gc` (run by Sprig or any external agent), the long-lived `cat-file --batch` process holds stale mmap'd pack pages. Subsequent `read()` calls may return wrong bytes, false-positive `objectNotFound`, or silently corrupt content.
- **Proposed fix (two-step):**
  1. Add `CatFileBatch.restart() async` — close the existing process and spin up a new one. Idempotent and safe from any actor context.
  2. Wire watcher events on `<gitDir>/objects/pack/` (created/modified/removed) to call `restart()` on every `CatFileBatch` instance for that repo. Lives in agent-layer code (M2 agent work).
- **Trigger to ship:** When the agent (M2-Mac) starts using `CatFileBatch` in production paths (diff viewer, log graph rendering). Currently `CatFileBatch` is only used in tests and benchmarks where there are no repacks mid-use.
- **Owner:** maintainer + me.
- **Severity:** High — silent data corruption is the worst failure mode in the audit. **Must be closed before M3 ships any feature that reads pack-resident objects.**

### `R15-F3` — `RepoStateStore` monotonic apply-sequence guard

- **Origin:** F3 (Medium severity).
- **Where:** `packages/RepoState/Sources/RepoState/RepoStateStore.swift` — `RepoStateStore.apply(_:)`.
- **Symptom:** Two `apply()` calls landing out of order (a t=0 snapshot finishes after a t=10 snapshot) clobber fresh state with stale data. Actor isolation serializes the calls but doesn't reject older ones.
- **Proposed fix:** Add an `apply(_:sequence:)` overload taking a monotonic `UInt64` (or `Date`) sequence number. Store keeps the highest seen and no-ops older inputs.
- **Trigger to ship:** When the agent's coalescer dispatches multiple concurrent `git status` calls (e.g., when fan-out across submodules makes parallelism worthwhile). Today's serial agent doesn't need this.
- **Owner:** maintainer + me.
- **Severity:** Medium — agent serialization handles it today; this is belt-and-suspenders for future agent bugs.

### `R15-F4` — Per-platform case-folding for `RepoStateStore.badge(for:)`

- **Origin:** F4 (Low severity).
- **Where:** `packages/RepoState/Sources/RepoState/RepoStateStore.swift` — `badge(for:)` and the underlying `PathTrie` lookups.
- **Symptom:** macOS HFS+ (default) and Windows NTFS (default) are case-insensitive. Git stores paths case-sensitively. If porcelain reports `Foo.swift` and the shell extension queries `foo.swift`, the trie lookup misses.
- **Proposed fix:** A platform-aware path normalizer at the trie boundary. Likely a small `PathCase` helper in `PlatformKit` or `RepoState` that:
  1. Detects the volume's case-sensitivity (stat the volume root, check `volumeSupportsCaseSensitiveNames`).
  2. On case-insensitive volumes, lowercases (or fold-case via Unicode case-folding) before insert AND lookup.
  3. On case-sensitive volumes, byte-exact as today.
- **Trigger to ship:** When a user reports a case-mismatch bug, or when M2 integration tests on macOS exercise it. Real likelihood is low because the shell extension passes paths it got from the OS, which usually echoes the on-disk casing.
- **Owner:** maintainer + me.
- **Severity:** Low.

### `R15-F2.support` — In-code TODO markers cross-reference this tracker

- **Where:** `Runner.run`, `CatFileBatch` (class doc), `RepoStateStore.apply`, `RepoStateStore.badge(for:)`, `PollingFileWatcher` (class doc) — all carry doc-comments referencing the audit findings.
- **Status:** Pending closure when each F1–F4 finding lands its fix. The closing PR removes the warning paragraphs from the doc-comments and crosses out the corresponding entry here.

## Closed

*(empty — kept this way intentionally. Entries move here when their fixing PR merges.)*

## How to use this file

**Adding an audit finding:**

1. Run an audit per `risk-register.md`'s audit obligations.
2. Number each pending finding `<RiskID>-F<N>` (e.g., `R15-F5`).
3. Document in the audit doc with severity + symptom + proposed fix.
4. Append a `Pending` entry here with the fields above.
5. Add `// TODO(<RiskID>-F<N>): <one-line>` comments at relevant call sites pointing here.

**Closing an audit finding:**

1. Ship the fixing PR.
2. Move the entry from `Pending` to `Closed` with the fixing PR number + date.
3. Remove the in-code `// TODO(...)` markers in the same PR.
4. Cross-out the corresponding `Deferred fix` line in the originating audit doc.

**Triaging at milestone exits:**

The CLAUDE.md milestone-exit checklist includes "every Pending audit follow-up has a triggered-by date or is rejected with a written rationale." Items lingering past their trigger condition without explanation are treated as overdue.
