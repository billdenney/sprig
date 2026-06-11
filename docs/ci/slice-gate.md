# The per-slice verification gate

Every engine slice (feature PR touching `packages/` or `cli/`) passes this gate before
push. This codifies the discipline that shipped ADRs 0068–0083 — it previously lived in
session memory, which is exactly one bus-factor away from not existing (see
master-plan.md's provenance note for how that goes).

## The gate, in order

1. **`./script/format`** — SwiftFormat (Docker-pinned). Re-run after any post-lint edit;
   format and lint disagree on a few multiline constructs (see
   `docs/architecture/cross-platform-quirks.md` and the SwiftFormat notes in
   CONTRIBUTING) — restructure the code rather than fighting the pair.
2. **`./script/lint`** — SwiftLint + SwiftFormat lint mode. Zero violations.
3. **Full local suite** — `swift test`, captured to a log file, single invocation (two
   concurrent runs race `.build` and produce phantom failures). Zero failures.
4. **Full Windows-VM sweep** — `SPRIG_REPO_ROOT=<worktree>
   /home/bill/sprig-windows-vm/test-windows.sh test`. The script rsyncs the *working
   tree*: commit (or keep the tree clean at the commit) before launching, or the sweep
   tests something other than what ships.
5. **The adjusted-gate receipt protocol** (tracked as `VM-ENV-1` in
   `docs/planning/audit-followups.md`): if the sweep's only failures are the known
   environmental members, run each failing member isolated
   (`test-windows.sh test --filter "<SuiteName>"`) on the same tree. Isolated-green =
   gate passed; record the receipts in the PR text. **Any other failing suite, or an
   isolated failure, is a real regression — stop and root-cause.** (The autocrlf/CRLF
   bug was caught exactly here: it failed isolated, which is what separates a code bug
   from the environmental class.)
6. **Commit → push → PR text** with the ADR citations and the test counts (local total,
   sweep total, receipts).

New suites that pass *in-sweep under load* need no isolated receipt — in-sweep is the
stronger signal.

## Suite-growth threshold (master-plan §12)

When the full VM sweep exceeds **~10 minutes wall**, per-slice gating switches to
changed-target sweeps (`--filter` on the affected packages) plus a nightly full sweep.
Until then, full sweep per slice. (2026-06 baseline: ~1,180 tests, ≈2.5 min test phase +
1–3 min sync/build.)

## Hosted CI relationship

Hosted CI (`ci-macos` / `ci-linux` / `ci-windows`) remains authoritative for merge. The
local gate exists because the Mac job is the only lint job and the VM mirrors
`windows-2022` closely enough to catch Windows-only compile/runtime breaks before a
3-minute CI round-trip — historically including toolchain-strictness traps (quirks C/D),
filesystem-latency classes (E), and git-environment differences (G).
