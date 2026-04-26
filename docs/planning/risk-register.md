# Risk register

Top risks to Sprig 1.0, with likelihood / impact / mitigation / owner. Kept in sync with the master plan §9. Reviewed at every milestone exit.

Severity = likelihood × impact, both 1 (low) – 5 (high). 25 = existential, 1 = trivial.

## Active risks

### R1 — swift-cross-ui maturity (severity 12)

- **Likelihood:** 3. The framework is younger than SwiftUI on macOS; gaps and rough edges surface as M3-Win begins.
- **Impact:** 4. Worst case forces Sprig to fall back to native WinUI 3 in C++/WinRT (per ADR 0055), which loses the view-model code-share win and stretches the calendar.
- **Mitigation:** ADR 0055 documents the fallback explicitly. Re-evaluate at M3-Win kickoff. Track upstream activity (issue velocity, recent merges) monthly.
- **Owner:** maintainer.

### R2 — Windows shell-extension expertise (severity 12)

- **Likelihood:** 4. The maintainer is comfortable with macOS but the Windows shell-extension surface (COM, MSIX, IShellIconOverlayIdentifier politics) is specialized. Likely to need a Windows-savvy contributor.
- **Impact:** 3. Without help, M2-Win and beyond slip materially. Doesn't kill the project; pushes 1.0 by a quarter or two.
- **Mitigation:** Surface the recruiting need in CONTRIBUTING and `docs/research/windows-shell-apis.md` from M0. Frame the work attractively (modern TortoiseGit; FOSS; visible mainstream impact). Consider GitHub Sponsors funding to compensate a contributor for the C++/COM work specifically.
- **Owner:** maintainer.

### R3 — Calendar slip from dual-shell commitment (severity 12)

- **Likelihood:** 4. Each macOS-shell milestone needs a Windows-shell counterpart. Worst case is strict serialization → ~2× calendar.
- **Impact:** 3. 1.0 ships later but still ships. Doesn't change the architectural bet.
- **Mitigation:** Invest hard in shared view-model code in `TaskWindowKit` so the per-shell delta is small. Run M2-Mac and M2-Win in parallel where contributor capacity allows.
- **Owner:** maintainer.

### R4 — 15-overlay-slot starvation on Windows (severity 9)

- **Likelihood:** 3. Most user environments have OneDrive (5 slots) + Dropbox (3) preinstalled before Sprig.
- **Impact:** 3. Significant UX regression vs macOS; users may see "modified" badge but not "staged" badge etc. Doesn't break functionality (right-click menu still works) but visibly degrades the flagship UX.
- **Mitigation:** Cap at 5 default slots, "Reduce to 3" toggle, full opt-out toggle, first-run diagnostic. Documented in `docs/research/windows-shell-apis.md`.
- **Owner:** maintainer.

### R5 — FinderSync extension quirks (severity 9)

- **Likelihood:** 3. Apple's FinderSync API has known issues — extensions killed liberally, user-granted-paths confusion, network-volume gaps.
- **Impact:** 3. Increases support load; doesn't break the architectural model.
- **Mitigation:** Detailed onboarding flow walks the user through System Settings activation. ADR 0022 fallback to polling on network volumes. Verification checklist in `docs/research/macos-finder-apis.md` tests the recovery paths.
- **Owner:** maintainer.

### R6 — Monorepo perf regressions (severity 9)

- **Likelihood:** 3. Chromium/Linux-kernel scale (100k–500k files) is far from the typical CI/dev fixture; perf bugs surface late.
- **Impact:** 3. Failing ADR 0021 budgets blocks 1.0.
- **Mitigation:** Benchmark CI gate (M1 deliverable) catches regressions ≤10%. Self-hosted macOS-arm64 runner for stable perf measurement. Test against synthesized 100k-file repos in CI; nightly run against a cached 500k-file fixture.
- **Owner:** maintainer.

### R7 — Bus factor / single-maintainer dependency (severity 9)

- **Likelihood:** 3. BDFL through 1.0 is explicit (ADR 0017). Maintainer illness, life event, or burnout halts everything.
- **Impact:** 3. Project pause; community fork possible but high friction.
- **Mitigation:** ADR 0017's transition-to-steering plan should be drafted in `docs/planning/governance-transition.md` by M7. Keep all keys / certs / accounts documented in a recovery doc accessible to a designated successor.
- **Owner:** maintainer.

### R8 — AI data-leakage anxieties (severity 8)

- **Likelihood:** 4. Cloud LLM calls send user code to third parties; enterprise users will flag this as a hard blocker without strong defaults.
- **Impact:** 2. ADR 0036 (local-first default + per-provider confirmation) addresses this directly. Failure here means losing some user segments, not the project.
- **Mitigation:** Local-first default is load-bearing. Data-handling matrix in AI settings. Eval harness runs against local providers too so users don't have to choose between privacy and quality.
- **Owner:** maintainer.

### R9 — Code-signing cert dependency (severity 8)

- **Likelihood:** 4. macOS Developer ID requires $99/year, paid and renewed by a single human. Windows EV cert is ~$300/year. If the maintainer can't sustain either, releases halt.
- **Impact:** 2. Existing users keep working; new users can't install signed builds; no auto-update.
- **Mitigation:** Surface cert renewal in the release pipeline. GitHub Sponsors / corporate sponsorship as ongoing funding source (ADR 0015). Document the cert ownership transition plan in `docs/planning/governance-transition.md`.
- **Owner:** maintainer.

### R10 — `core.fsmonitor` wire-protocol drift (severity 6)

- **Likelihood:** 2. Protocol is stable since git 2.37; minor revisions in subsequent versions.
- **Impact:** 3. If a future git version changes the protocol incompatibly, our hook breaks `git status` for users who upgraded git.
- **Mitigation:** Integration tests run against pinned git versions (2.39 Apple-bundled, current Homebrew, latest upstream — see `docs/ci/linux-matrix.md`). Feature-detect the protocol version at runtime.
- **Owner:** maintainer.

### R11 — Contributor onboarding friction (severity 6)

- **Likelihood:** 3. Open-source uptake hinges on a <15-minute "clone-to-first-contribution" flow.
- **Impact:** 2. Slower contributor growth; longer to reduce R7 bus factor.
- **Mitigation:** `script/bootstrap` reproducibly sets up the toolchain. CI green-on-first-try. `good-first-issue` triage policy. Verified during M0 with an outside volunteer producing a merged "typo fix" PR within 15 minutes.
- **Owner:** maintainer.

### R12 — LFS / git-lfs licensing & bundling (severity 4)

- **Likelihood:** 2. git-lfs is MIT-licensed; OK to surface install flows. If we ever bundle, re-verify per release.
- **Impact:** 2. License violation forces re-architecture; not catastrophic if caught early.
- **Mitigation:** ADR 0029 (detect-and-install, never bundle by default). License audit step in release pipeline.
- **Owner:** maintainer.

### R13 — Antivirus / SmartScreen quarantine on Windows (severity 6)

- **Likelihood:** 3. New shell extension DLLs trigger SmartScreen "unrecognized publisher" until reputation builds. Some AV products quarantine new extensions outright.
- **Impact:** 2. Users see scary warnings on first install; some abandon the install.
- **Mitigation:** EV code-signing cert (bypasses SmartScreen reputation gating). Submit each release to Microsoft Defender via the Windows Security Intelligence portal. Document SmartScreen prompt in install guide.
- **Owner:** maintainer.

### R14 — Self-hosted runner failure (severity 6)

- **Likelihood:** 3. Hardware fails; macOS updates break the runner; signing cert expires.
- **Impact:** 2. Releases blocked for hours-to-days.
- **Mitigation:** 24-hour recovery target (`docs/ci/self-hosted.md`). Fallback path: temporary build on maintainer's primary Mac. Keychain backup procedure with annual restore drill.
- **Owner:** maintainer.

## Retired / closed risks

(none yet — this section will populate as risks resolve or get reframed)

## Master plan source

This file mirrors and expands master plan §9. When the two diverge, the master plan is canonical for *strategic* risks; this file is canonical for *operational* details (likelihoods, owners, mitigation status).
