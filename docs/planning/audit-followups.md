# Audit follow-ups — durable tracker

Each entry here is a known failure mode identified by an audit (per `risk-register.md`'s audit obligations) plus the deferred fix that closes it. Items move from "Pending" to "Closed" as their fixing PRs land. This file is the source of truth for which audit findings are still open; in-code `// TODO(<finding-id>):` markers point back here.

The format is loosely modeled on `docs/planning/disabled-tests.md`: a single grep-able file beats scattered issues. Audit follow-ups are NOT optional — they're debt notes we promise to pay when their trigger conditions arrive.

## Pending

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
