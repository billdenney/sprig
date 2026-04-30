# Tests

- `integration/` — spawns real `git` across a version matrix (2.39, current Homebrew, latest upstream).
- `snapshots/` — golden diff + merge rendering.
- `benchmarks/` — `package-benchmark`-based perf gates.
- `ai-evals/` — held-out conflict corpus + gold resolutions.
- `fixtures/` — hash-pinned test repos (clean, dirty, conflict, submodule, LFS, 100k-file, 500k-file).

**No E2E suite today.** XCUITest end-to-end tests against the real macOS shell need a self-hosted macOS-arm64 runner (real Finder, signing cert, notarization), which we don't currently operate. When that runner is provisioned, an `e2e/` directory and matching workflow get re-introduced; until then, integration + snapshot tests cover the surfaces we can hit on hosted CI.

See the master plan §5.5 for the full testing strategy and CI gates.
