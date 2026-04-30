# Self-hosted runner provisioning

What a self-hosted runner fleet would look like, and what it unlocks. **No self-hosted runners are currently operated** — every job runs on GitHub-hosted runners today. As a consequence, the E2E suite (XCUITest), the perf-gate benchmark workflow, and the release pipeline are all parked: no `tests/e2e/`, no nightly benchmark comparison, no signed/notarized builds from CI.

This document describes the future provisioning plan. It activates when the maintainer has the budget for hosting + cert maintenance, or when a sponsor steps in. **Authoritative content lands before M9** (1.0 release pipeline). Until then this is a sketch.

ADR cross-references: 0021 (perf budgets), 0046 (release cadence), 0054 (Windows shell at 1.0).

Companion: [`linux-matrix.md`](linux-matrix.md), [`../architecture/performance.md`](../architecture/performance.md).

## What's hosted today vs what self-hosted would unlock

| Job | Today | Future (self-hosted required) | Why self-hosted |
|---|---|---|---|
| `ci-macos` (build + test + lint) | ✅ hosted `macos-14` / `macos-15` | — | Standard hosted runners are fine; CPU variance is acceptable for boolean pass/fail tests |
| `ci-linux` (build + test) | ✅ hosted `ubuntu-24.04` (in `swift:6.3.1-noble`) | — | Same |
| `ci-windows` (build + test) | ✅ hosted `windows-2022` | — | Same |
| Benchmark **smoke build** (every PR) | ✅ hosted | — | Just verifies the benchmark target compiles |
| **E2E** (XCUITest driving signed builds) | ❌ not implemented | self-hosted macOS-arm64 | Needs a real Finder, real signing cert, real notarization — none available on hosted runners |
| **Benchmarks** (perf gates / regression detection) | ❌ not implemented | self-hosted macOS-arm64 | Hosted runners vary ~3× CPU between runs (ADR 0021); not stable enough for perf regression detection |
| **Release pipeline** (sign + notarize + publish) | ❌ not implemented | self-hosted macOS-arm64 | Developer ID signing key cannot leave a trusted machine |
| **Windows E2E** (UI Automation against MSIX) | ❌ not implemented | self-hosted Windows | Once M2-Win lands; currently TBD |

## Planned macOS-arm64 runner (provisioning TBD)

Hardware: a Mac mini M2 Pro, 16 GB RAM, 512 GB SSD. Sized for two concurrent jobs (E2E + benchmark) with headroom. Plan to evaluate after first three months of operation; upgrade to M4 Pro if benchmark queueing becomes a bottleneck.

OS: latest macOS at all times (we develop against the floor of macOS 14 but the runner stays current to catch forward-compat issues early).

GitHub Actions runner installed as a launchd-managed user service (`gh-actions-runner` user account, no admin privileges). Token rotated on a 90-day schedule.

## Secret handling

- **Apple Developer ID signing cert + private key** — stored in a dedicated keychain, unlocked at runner-service startup via launchd `EnvironmentVariables`. Never exported to env vars in workflow steps. Signing tools (`codesign`, `productsign`) read directly from the keychain.
- **Notarization API key** (App Store Connect) — stored as a `.p8` file in `/var/sprig-ci/notarization/`, mode `0400`, owner `gh-actions-runner`. Path passed to `xcrun notarytool` via workflow input.
- **Sparkle EdDSA signing key** — stored similarly to the notarization key. Each release signs the appcast item via `sparkle/sign_update`.
- **GitHub PAT for cask PR creation** — fine-grained PAT with write access to a single fork (`sprig-org/homebrew-sprig-cask`). Stored as a GitHub Actions secret on the workflow side, not on the runner.

**Hard rules:**

- No secret material is checked into the repo.
- No secret is printed to job logs (workflow steps explicitly use `::add-mask::` for any value passing through stdout).
- The runner's keychain is never exported, even for backups (we re-issue keys rather than copy them around).

## Planned Windows runner

Hardware TBD; sized for the Windows E2E + MSIX-build pipeline.

OS: Windows 11 Pro 23H2+. Joined to the same per-runner network namespace as the macOS box for shared artifact storage if needed.

Secrets: EV code-signing cert, MSIX signing material, WinSparkle signing key. Same handling pattern as macOS: dedicated user account, secrets read from a protected directory, never in env vars.

## Linux runner — likely not needed

For now, all Linux work runs on hosted runners. We don't run an `apps/linux/` GUI shell at 1.0 (ADR 0054), so there's no Linux-side equivalent of the macOS XCUITest / Windows UI Automation needs. If we add Linux-side benchmark gating post-1.0, a self-hosted Linux runner gets added then.

## Backup + recovery

- **Keychain dump → encrypted offsite backup** every 30 days. Restore drill once per year.
- **Notarization key + Sparkle key** stored in a separate offline backup (1Password vault accessible only to the maintainer).
- **Runner host loss recovery target: 24 hours.** The release pipeline can fall back to a temporary build on the maintainer's primary Mac for an emergency.

## Open questions

- **Who owns the runner long-term once governance opens** (ADR 0017)? Default: maintainer, but the "single point of failure for releases" note in the risk register should track this.
- **Do we run the benchmark suite on Linux + Windows hosted runners as a smoke test** (knowing the perf numbers themselves are noisy)? Probably yes — catches "did the benchmark binary build" before nightly.
- **GitHub-hosted macOS-arm64 runners** (announced 2024) — do they obviate the need for our self-hosted box? Probably not for E2E (still need real Finder + signing keys) but maybe for benchmarks if the variance turns out to be acceptable. Re-evaluate post-M2.
