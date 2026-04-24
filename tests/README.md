# Tests

- `integration/` — spawns real `git` across a version matrix (2.39, current Homebrew, latest upstream).
- `e2e/` — XCUITest on a self-hosted macOS runner.
- `snapshots/` — golden diff + merge rendering.
- `benchmarks/` — `package-benchmark`-based perf gates.
- `ai-evals/` — held-out conflict corpus + gold resolutions.
- `fixtures/` — hash-pinned test repos (clean, dirty, conflict, submodule, LFS, 100k-file, 500k-file).

See the master plan §5.5 for the full testing strategy and CI gates.
