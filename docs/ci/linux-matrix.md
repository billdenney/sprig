# Linux CI matrix

Concrete configuration for `.github/workflows/ci-linux.yml`: which Swift toolchain, which `git` version, which container, what gets built and tested.

Linux CI is **required-green on every PR**. Per ADR 0048 / 0053 it's the load-bearing guard against accidental macOS-only API leakage in the engine.

## What's pinned today

| Setting | Value | Where |
|---|---|---|
| Container image | `swift:6.3.1-noble` | `.github/workflows/ci-linux.yml` |
| Swift version | 6.3.1 | matches `.swift-version` |
| Ubuntu version | 24.04 (Noble) | derived from the container image |
| `git` source | Ubuntu Noble's apt package | installed at job start |
| `git` version | 2.43.x as of writing | whatever Noble's apt repo has |
| What's built | the full SwiftPM workspace (`packages/` + `cli/sprigctl/`) | `swift build` |
| What's tested | the full SwiftPM test suite (`swift test`) | includes integration tests that spawn real git |

The Swift version is held in lockstep with `.swift-version` at the repo root. Bumping the toolchain is one of two specific edits: change `.swift-version`, change the Docker image tag in `ci-linux.yml`, push.

## Why we install git + libjemalloc-dev rather than bundling them

The `swift:6.3.1-noble` image does not ship `git` or `libjemalloc-dev`. Both are installed as the first workflow step:

```yaml
- name: Install git + libjemalloc-dev
  run: |
    apt-get update
    apt-get install -y --no-install-recommends git libjemalloc-dev
    git --version
```

- **`git`** — `GitCoreTests` integration tests (init/status round-trips, merge-conflict fixtures) and `CatFileBatchTests` spawn real git.
- **`libjemalloc-dev`** — `package-benchmark` links `jemalloc` on Linux for malloc-tracking metrics. Vendored on macOS; absent on Linux without this. See [`../architecture/performance.md`](../architecture/performance.md).

Pinning a specific git version isn't worth the maintenance — Noble's package is recent enough to clear our 2.39 floor (ADR 0047), and tracking upstream gives us early detection of any porcelain-format drift.

## What runs

```yaml
- swift build       # Tier-1 portable + Tier-2 protocol layers + cli/sprigctl
- swift test        # all unit + integration tests
```

This catches:

- Any new `import AppKit` / `import SwiftUI` / `import FinderSync` / `import Combine` / `import ServiceManagement` / `import Sparkle` in `packages/` (linux toolchain doesn't have these).
- Any new `#if os(macOS)` block in portable package logic that hides Mac-specific API calls behind it (the linux build sees no implementation and either fails to compile or fails the test).
- Any test code that hardcodes `/usr/bin/env`, POSIX-only paths, or other non-portable assumptions — the same guard catches Windows-specific issues on `ci-windows`.
- Any porcelain parser regression against a real `git` binary.

## What we deliberately don't matrix

- **Multiple git versions on the same Linux runner.** When a regression against an older git surfaces, we'll add a second job (e.g. an Ubuntu 22.04 container with apt-pinned `git=2.39.x`). Until then, the cost of a constant 3× matrix isn't justified.
- **Multiple Linux distros.** We test against Noble. Distro-specific packaging quirks (RPM vs DEB) are out of scope until we ship Linux engine packages, which is a post-1.0 community-maintained surface.
- **ARM64 Linux.** Hosted runners only offer x86_64 currently; the engine is portable Swift and shouldn't care, but if regressions emerge, `linux/arm64` runners are available on demand.

## How linux CI relates to macOS and Windows

| | `ci-macos` | `ci-linux` | `ci-windows` |
|---|---|---|---|
| OS image | `macos-14` + `macos-15` matrix | `ubuntu-24.04` container | `windows-2022` |
| Swift install | latest Xcode-bundled | container provides it | `compnerd/gha-setup-swift@main` |
| `git` source | pre-installed Apple-bundled | `apt-get install git` | pre-installed Git for Windows |
| What runs | lint + format + build + test | build + test | build + test |
| Required-green | ✅ | ✅ | ✅ |

The lint + format check runs only on `ci-macos`; results are identical across runners on the same source, so re-running on each is wasted CPU.

## When to widen the matrix

Specific signals that should trigger adding a new job:

1. **A real-user bug report** against an older git version (then: add a second `ci-linux` job pinned to that version, written so the original job stays clean).
2. **A reported issue on a non-Noble distro** that points at a packaging or syscall difference (then: add an Alpine or Fedora job).
3. **The Windows shell extension landing in M2-Win** triggers a separate workflow that builds the C++/COM extension; that's a Windows concern and lives in `ci-windows.yml` rather than this file.

Each new job needs an entry in this doc explaining why it exists. We're trying to keep the CI surface small and intentional.

## Local reproduction

Maintainer's `script/test` activates the same Swift toolchain via swiftly and runs the same `swift build && swift test && script/lint` sequence. To reproduce the *exact* CI behavior locally on Linux:

```bash
docker run --rm -v "$PWD:/work" -w /work swift:6.3.1-noble bash -c '
  apt-get update >/dev/null
  apt-get install -y --no-install-recommends git >/dev/null
  swift build && swift test
'
```

The lint half (`swiftlint --strict` + `swiftformat --lint`) is run via Docker too — `./script/lint` already does the right thing.
