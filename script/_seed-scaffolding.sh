#!/usr/bin/env bash
# One-shot scaffolding seeder for the Sprig repo.
# Idempotent: safe to re-run; only writes files that don't already exist
# (unless FORCE=1 is set).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

write() {
  # write <path> -- reads heredoc from stdin
  local path="$1"
  mkdir -p "$(dirname "$path")"
  if [[ -e "$path" && "${FORCE:-0}" != "1" ]]; then
    echo "  skip  $path (exists)"
    return 0
  fi
  cat >"$path"
  echo "  wrote $path"
}

echo "Seeding scaffolding into $ROOT ..."

########################################
# Root config files
########################################

write .gitignore <<'EOF'
## Swift + Xcode
.build/
.swiftpm/
DerivedData/
*.xcuserstate
*.xcuserdatad/
*.xcscmblueprint
xcuserdata/
Package.resolved

## macOS
.DS_Store
.AppleDouble
.LSOverride
Icon?
._*
.Spotlight-V100
.Trashes

## Linux
*.swp
.nfs*

## Windows
Thumbs.db
ehthumbs.db
Desktop.ini

## Secrets / signing
*.p12
*.p8
*.provisionprofile
.env
.env.*
!.env.example
apps/macos/Sparkle/ed_private_key*

## Tools
node_modules/
dist/
coverage/
*.log

## Sprig-specific
apps/macos/**/SprigApp.xcodeproj/project.xcworkspace/xcuserdata/
tests/fixtures/repos/*.extracted/
EOF

write .gitattributes <<'EOF'
* text=auto eol=lf
*.swift text eol=lf
*.md    text eol=lf
*.yml   text eol=lf
*.yaml  text eol=lf
*.sh    text eol=lf

*.png   binary
*.jpg   binary
*.pdf   binary
*.ico   binary
*.icns  binary

# Large repo fixtures live in LFS
tests/fixtures/repos/**/*.tar.zst filter=lfs diff=lfs merge=lfs -text
EOF

write .editorconfig <<'EOF'
root = true

[*]
indent_style = space
indent_size = 4
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
charset = utf-8

[*.{yml,yaml,md}]
indent_size = 2

[Makefile]
indent_style = tab
EOF

write .dockerignore <<'EOF'
.git
.build
.swiftpm
apps/
tests/fixtures/repos/*.extracted
*.xcodeproj
DerivedData
EOF

write .swiftformat <<'EOF'
--indent 4
--swiftversion 6.3
--commas inline
--trimwhitespace always
--wraparguments before-first
--wrapparameters before-first
--wrapcollections before-first
--disable redundantSelf
EOF

write .swiftlint.yml <<'EOF'
# Sprig SwiftLint configuration.
# Custom rules enforce the three-tier cross-platform boundaries (ADR 0048, 0053).

included:
  - apps
  - packages
  - tests

excluded:
  - .build
  - .swiftpm
  - DerivedData

line_length:
  warning: 140
  error: 200

type_name:
  min_length: 2

identifier_name:
  min_length: 1
  excluded:
    - id
    - x
    - y
    - z
    - r
    - g
    - b

custom_rules:
  no_appkit_in_packages:
    name: "No AppKit/SwiftUI/Cocoa in packages/ (Tier 1-2 must be portable)"
    regex: '^import (AppKit|SwiftUI|Cocoa|FinderSync|Combine|ServiceManagement|Sparkle)\b'
    included:
      - "packages/"
    severity: error
    message: "Imports of AppKit/SwiftUI/Cocoa/FinderSync/Combine/ServiceManagement/Sparkle are banned in packages/. See ADR 0048, 0053 and CLAUDE.md."

  no_hardcoded_home_paths:
    name: "No hardcoded user-home or platform paths"
    regex: '("/Users/|"~/Library/|"\\\\AppData\\\\|"/home/)'
    included:
      - "packages/"
      - "apps/"
    excluded:
      - "tests/fixtures/"
      - "docs/"
    severity: error
    message: "Hardcoded absolute paths are forbidden. Use PathResolver (ADR 0053)."

  no_os_check_in_portable:
    name: "No #if os() in portable package sources"
    regex: '^\s*#if os\('
    included:
      - "packages/"
    excluded:
      - "packages/**/Sources/Mac/"
      - "packages/**/Sources/Linux/"
      - "packages/**/Sources/Windows/"
    severity: error
    message: "#if os() is only permitted in Mac/Linux/Windows adapter subdirs. If portable code needs a platform branch, the abstraction is wrong (ADR 0048)."
EOF

write NOTICE <<'EOF'
Sprig
Copyright 2026 The Sprig Contributors

This product is licensed under the Apache License, Version 2.0 (see LICENSE).

Third-party attributions will be listed here as dependencies are added.
EOF

write CHANGELOG.md <<'EOF'
# Changelog

All notable changes to Sprig are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- Initial project scaffolding: three-tier package structure, ADRs 0001–0053, CI matrix (macOS 14/15 + Linux Swift 6.3 + Windows Swift 6.3), SwiftLint rules enforcing cross-platform discipline.
EOF

write CODE_OF_CONDUCT.md <<'EOF'
# Contributor Covenant Code of Conduct

Sprig adopts the [Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/) unmodified.

## Reporting

Report unacceptable behavior to the project maintainer via the email listed in the repository owner's GitHub profile. All complaints will be reviewed and investigated promptly and fairly.

The maintainer is obligated to respect the privacy and security of the reporter of any incident.

## Enforcement

Community Impact Guidelines from Contributor Covenant v2.1 apply verbatim. See https://www.contributor-covenant.org/version/2/1/code_of_conduct/ for the full text.
EOF

write SECURITY.md <<'EOF'
# Security Policy

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Please report vulnerabilities privately via one of:

- GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) (preferred).
- Email the maintainer directly — address in the repo owner's GitHub profile.

Please include: a clear description of the issue, steps to reproduce, affected versions, and (if possible) a proposed mitigation.

## Response expectations

- Initial acknowledgment within 72 hours.
- Triage + severity assessment within 7 days.
- Fix + coordinated disclosure within 90 days for high/critical issues, longer for lower severity.

## Threat model

The primary threat vectors for Sprig users are:

1. **Malicious repository content** — git hooks, submodule URLs, filter configs, attributes. Sprig prompts on first-encounter of hooks (ADR 0050) and blocks `file://`/`ext::` protocols by default.
2. **Credential exfiltration** — Sprig stores tokens only in macOS Keychain (never plaintext) and honors existing credential helpers.
3. **Arbitrary code execution via AI-generated resolutions** — AI suggestions are always surfaced as previews for user review before application; never auto-applied without confirmation (ADR 0028).
4. **Supply chain** — dependencies are Dependabot-tracked and license-audited. CI blocks GPL/AGPL deps.

## Scope

In scope: the app, the agent, the FinderSync extension, the installer, and all packages in `packages/`.

Out of scope: third-party Git hosting providers (GitHub/GitLab/etc.), the user's `git` binary itself, the user's OS, third-party AI providers (Anthropic, OpenAI, Ollama) — report those issues to their respective maintainers.
EOF

write GOVERNANCE.md <<'EOF'
# Governance

Sprig currently operates under a **BDFL (Benevolent Dictator For Life) model** (ADR 0017). The maintainer — whoever holds the primary GitHub ownership — has final say on all technical and community decisions.

## Transition plan

Once the project reaches any of these triggers, we'll publish an updated governance model and open a steering committee:

- Three or more regular contributors (≥ 5 merged PRs over ≥ 3 months each).
- The 1.0 release ships.
- The maintainer explicitly invites co-maintainers.

The transition document lives at `docs/planning/governance-transition.md` and will be drafted by M7.

## Decision process (today)

1. Open an issue or draft ADR in `docs/decisions/`.
2. Discuss in PR or issue comments.
3. Maintainer decides and either merges the ADR (accepted) or closes with reasoning.

## Code of Conduct enforcement

Violations are reviewed by the maintainer. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
EOF

########################################
# Root Package.swift
########################################

write Package.swift <<'EOF'
// swift-tools-version: 6.0
// Sprig — root SwiftPM manifest. See ADR 0053 for the three-tier structure
// this manifest enforces.

import PackageDescription

let tier1Targets: [String] = [
    "GitCore", "RepoState", "ConflictKit", "AIKit", "LFSKit",
    "SubmoduleKit", "SubtreeKit", "SafetyKit", "IPCSchema",
    "PlatformKit", "DiagKit", "StatusKit", "TaskWindowKit", "UIKitShared",
]

let tier2Targets: [String] = [
    "WatcherKit", "CredentialKit", "NotifyKit", "UpdateKit",
    "LauncherKit", "TransportKit", "AgentKit",
]

let package = Package(
    name: "Sprig",
    platforms: [.macOS(.v14)],
    products:
        (tier1Targets + tier2Targets).map { name in
            .library(name: name, targets: [name])
        },
    targets:
        tier1Targets.flatMap { name in
            [
                .target(name: name, path: "packages/\(name)/Sources/\(name)"),
                .testTarget(
                    name: "\(name)Tests",
                    dependencies: [.target(name: name)],
                    path: "packages/\(name)/Tests/\(name)Tests"
                ),
            ]
        }
        +
        tier2Targets.flatMap { name -> [Target] in
            [
                .target(
                    name: name,
                    dependencies: ["PlatformKit"],
                    path: "packages/\(name)/Sources",
                    sources: [name, "Mac", "Linux", "Windows"]
                ),
                .testTarget(
                    name: "\(name)Tests",
                    dependencies: [.target(name: name)],
                    path: "packages/\(name)/Tests/\(name)Tests"
                ),
            ]
        }
)
EOF

########################################
# Per-package stub sources + tests
########################################

# Tier 1: portable packages. Each gets:
#   Sources/<Pkg>/<Pkg>.swift   (public enum stub)
#   Tests/<Pkg>Tests/<Pkg>Tests.swift
for pkg in GitCore RepoState ConflictKit AIKit LFSKit SubmoduleKit SubtreeKit SafetyKit IPCSchema PlatformKit DiagKit StatusKit TaskWindowKit UIKitShared; do
    write "packages/$pkg/Sources/$pkg/$pkg.swift" <<EOF
// $pkg — portable (Tier 1) package. No UI, no platform APIs.
// Must compile on macOS, Linux, and Windows Swift 6.3.
// See CLAUDE.md and ADR 0048 for cross-platform discipline.

import Foundation

public enum $pkg {
    public static let moduleName = "$pkg"
}
EOF
    write "packages/$pkg/Tests/${pkg}Tests/${pkg}Tests.swift" <<EOF
import Testing
@testable import $pkg

@Test func moduleNameIsSet() {
    #expect($pkg.moduleName == "$pkg")
}
EOF
done

# Tier 2: adapter packages. Each gets:
#   Sources/<Pkg>/<Pkg>.swift  (protocol)
#   Sources/Mac/<Pkg>Mac.swift   (#if os(macOS) real impl — stub for now)
#   Sources/Linux/<Pkg>Linux.swift (#if os(Linux) stub)
#   Sources/Windows/<Pkg>Windows.swift (#if os(Windows) stub)
for pkg in WatcherKit CredentialKit NotifyKit UpdateKit LauncherKit TransportKit AgentKit; do
    write "packages/$pkg/Sources/$pkg/$pkg.swift" <<EOF
// $pkg — adapter (Tier 2) package.
// The protocol lives here (portable); implementations live in
// Sources/Mac, Sources/Linux, Sources/Windows.
// See ADR 0048 and CLAUDE.md.

import Foundation
import PlatformKit

public enum $pkg {
    public static let moduleName = "$pkg"
}
EOF
    write "packages/$pkg/Sources/Mac/${pkg}Mac.swift" <<EOF
#if os(macOS)
import Foundation

// macOS implementation stub — see ADR 0048 / CLAUDE.md.
// Real impl arrives in the relevant milestone (see docs/planning/roadmap.md).

enum ${pkg}MacImpl {
    static let platform = "macOS"
}
#endif
EOF
    write "packages/$pkg/Sources/Linux/${pkg}Linux.swift" <<EOF
#if os(Linux)
import Foundation

// Linux stub — part of the day-1 cross-platform scaffolding (ADR 0053).
// Real implementation lands when a Linux port is prioritized post-1.0.

enum ${pkg}LinuxImpl {
    static let platform = "Linux"
    static func notImplemented() -> Never {
        fatalError("${pkg} Linux impl not yet available — see docs/architecture/cross-platform.md")
    }
}
#endif
EOF
    write "packages/$pkg/Sources/Windows/${pkg}Windows.swift" <<EOF
#if os(Windows)
import Foundation

// Windows stub — part of the day-1 cross-platform scaffolding (ADR 0053).
// Real implementation lands when a Windows port is prioritized post-1.0.

enum ${pkg}WindowsImpl {
    static let platform = "Windows"
    static func notImplemented() -> Never {
        fatalError("${pkg} Windows impl not yet available — see docs/architecture/cross-platform.md")
    }
}
#endif
EOF
    write "packages/$pkg/Tests/${pkg}Tests/${pkg}Tests.swift" <<EOF
import Testing
@testable import $pkg

@Test func moduleNameIsSet() {
    #expect($pkg.moduleName == "$pkg")
}
EOF
done

########################################
# ADR template + index + ADR files 0001-0053
########################################

write docs/decisions/0000-template.md <<'EOF'
---
status: proposed  # proposed | accepted | superseded-by-NNNN | deprecated
date: YYYY-MM-DD
deciders: <github handles>
consulted: <github handles, teams>
informed: <github handles, teams>
---

# NNNN. Short decision title

## Context and problem statement

What is the issue we're seeing that motivates this decision? Include any relevant data or references.

## Decision drivers

- Driver 1
- Driver 2

## Considered options

1. Option A
2. Option B
3. Option C

## Decision

We chose **Option X** because…

## Consequences

**Positive**
- …

**Negative / trade-offs**
- …

## Links

- Relevant ADRs, RFCs, external references
- Plan file section(s) if this came from the master plan
EOF

# Define ADR titles (NN|title)
adrs=(
  "0001|Use system git binary for all git operations"
  "0002|License — Apache-2.0"
  "0003|Primary language — Swift"
  "0004|Filesystem watcher — FSEvents-based with per-repo incremental index"
  "0005|Enable core.fsmonitor via our watcher"
  "0006|Modular SwiftPM packages per subsystem"
  "0007|AI integration is optional, pluggable, provider-agnostic"
  "0008|Default to Scalar-style modern git settings"
  "0009|Distribution — direct notarized DMG with Sparkle"
  "0010|Minimum macOS — 14 Sonoma floor with opportunistic 15 APIs"
  "0011|UI framework — SwiftUI-first with AppKit escape hatches"
  "0012|MVP scope — thin MVP plus merge UI"
  "0013|AI providers — Anthropic, OpenAI, Ollama, Apple on-device"
  "0014|Telemetry — opt-in only, local-first"
  "0015|Sustainability — pure FOSS + GitHub Sponsors"
  "0016|Project name — Sprig"
  "0017|Governance — BDFL transitioning to open steering"
  "0018|Distribution channels — Homebrew Cask + direct download at 1.0"
  "0019|Badge icon set — full 10 with user-selectable reveal level"
  "0020|Context menu layout — common flat, advanced in submenu"
  "0021|Performance budget — Linux-kernel scale"
  "0022|Non-local volumes — best-effort with polling fallback"
  "0023|Git invocation — shell out only, no libgit2"
  "0024|Our FSEvents watcher is single source of truth, drives core.fsmonitor"
  "0025|Repo discovery — user-added roots plus learn-as-you-go"
  "0026|Scalar-style defaults — perf bundle, safety hardening, maintenance, partial clone"
  "0027|Merge UI — built-in 3-way view with external-tool delegation option"
  "0028|AI merge assistance — suggest-only with hunk preview"
  "0029|LFS install flow — detect plus one-click Homebrew"
  "0030|Finder-first architecture — no main app file tree"
  "0031|Submodules — badges plus right-click plus SubmoduleManager window"
  "0032|Git extension support plan"
  "0033|Destructive-op safety — tiered with snapshot refs"
  "0034|No menu-bar helper"
  "0035|AI feature scope for M7"
  "0036|AI privacy default — local-first with per-action cloud confirmation"
  "0037|AI prompt storage — in-repo versioned markdown"
  "0038|AI evaluation harness"
  "0039|Onboarding — adaptive"
  "0040|Keyboard-first with command palette"
  "0041|Multi-identity profiles — first-class"
  "0042|Accessibility and localization — full a11y, English at 1.0"
  "0043|Credentials — Keychain-backed helper honoring existing tools"
  "0044|Commit signing — SSH signing in onboarding, default on"
  "0045|Docs platform — DocC plus Astro Starlight"
  "0046|Release cadence — monthly stable plus weekly beta"
  "0047|Git detection and install bootstrap"
  "0048|Cross-platform extensibility rules"
  "0049|Modern git config defaults"
  "0050|Hook security model — trust prompt per-repo"
  "0051|Stacked-PR workflow as first-class"
  "0052|Force-push aliasing — always --force-with-lease --force-if-includes"
  "0053|Day-1 cross-platform scaffolding commitment"
)

for entry in "${adrs[@]}"; do
    num="${entry%%|*}"
    title="${entry#*|}"
    slug="$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9 -' | tr ' ' '-' | sed 's/--*/-/g' | sed 's/-$//')"
    path="docs/decisions/${num}-${slug}.md"
    # Use a heredoc that substitutes vars (no quoting of delimiter)
    mkdir -p "$(dirname "$path")"
    if [[ -e "$path" && "${FORCE:-0}" != "1" ]]; then
        echo "  skip  $path (exists)"
        continue
    fi
    cat >"$path" <<EOF
---
status: accepted
date: 2026-04-24
deciders: maintainer
consulted: —
informed: —
---

# ${num}. ${title}

## Context

See the master plan at \`/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md\`, §3 (Decision Log) for the rationale, alternatives, and consequences that produced this ADR.

## Decision

Captured in the plan. This file exists as the canonical ADR location for linking from PRs, CHANGELOG entries, and code comments. The decision summary in the plan is the source of truth until this file is expanded.

## Consequences

See the plan for trade-offs. When implementation reveals new consequences, update this file and cite the commit.

## Links

- Master plan, §3 Decision Log (ADR ${num}).
- CLAUDE.md — summarizes load-bearing rules across multiple ADRs.
EOF
    echo "  wrote $path"
done

write docs/decisions/README.md <<'EOF'
# Architecture Decision Records (ADRs)

Sprig uses [MADR](https://adr.github.io/madr/) format. Each decision lives as a numbered markdown file in this directory.

Status values: `proposed`, `accepted`, `superseded-by-NNNN`, `deprecated`.

New ADRs: copy `0000-template.md`, pick the next free number, add an entry to the table below, and link from your PR.

## Index

| #    | Title                                                                      | Status   |
|------|----------------------------------------------------------------------------|----------|
| 0001 | Use system git binary for all git operations                               | accepted |
| 0002 | License — Apache-2.0                                                       | accepted |
| 0003 | Primary language — Swift                                                   | accepted |
| 0004 | Filesystem watcher — FSEvents-based with per-repo incremental index        | accepted |
| 0005 | Enable core.fsmonitor via our watcher                                      | accepted |
| 0006 | Modular SwiftPM packages per subsystem                                     | accepted |
| 0007 | AI integration is optional, pluggable, provider-agnostic                   | accepted |
| 0008 | Default to Scalar-style modern git settings                                | accepted |
| 0009 | Distribution — direct notarized DMG with Sparkle                           | accepted |
| 0010 | Minimum macOS — 14 Sonoma floor with opportunistic 15 APIs                 | accepted |
| 0011 | UI framework — SwiftUI-first with AppKit escape hatches                    | accepted |
| 0012 | MVP scope — thin MVP plus merge UI                                         | accepted |
| 0013 | AI providers — Anthropic, OpenAI, Ollama, Apple on-device                  | accepted |
| 0014 | Telemetry — opt-in only, local-first                                       | accepted |
| 0015 | Sustainability — pure FOSS + GitHub Sponsors                               | accepted |
| 0016 | Project name — Sprig                                                       | accepted |
| 0017 | Governance — BDFL transitioning to open steering                           | accepted |
| 0018 | Distribution channels — Homebrew Cask + direct download at 1.0             | accepted |
| 0019 | Badge icon set — full 10 with user-selectable reveal level                 | accepted |
| 0020 | Context menu layout — common flat, advanced in submenu                     | accepted |
| 0021 | Performance budget — Linux-kernel scale                                    | accepted |
| 0022 | Non-local volumes — best-effort with polling fallback                      | accepted |
| 0023 | Git invocation — shell out only, no libgit2                                | accepted |
| 0024 | Our FSEvents watcher is single source of truth, drives core.fsmonitor      | accepted |
| 0025 | Repo discovery — user-added roots plus learn-as-you-go                     | accepted |
| 0026 | Scalar-style defaults — perf bundle, safety hardening, maintenance, partial clone | accepted |
| 0027 | Merge UI — built-in 3-way view with external-tool delegation option        | accepted |
| 0028 | AI merge assistance — suggest-only with hunk preview                       | accepted |
| 0029 | LFS install flow — detect plus one-click Homebrew                          | accepted |
| 0030 | Finder-first architecture — no main app file tree                          | accepted |
| 0031 | Submodules — badges plus right-click plus SubmoduleManager window          | accepted |
| 0032 | Git extension support plan                                                 | accepted |
| 0033 | Destructive-op safety — tiered with snapshot refs                          | accepted |
| 0034 | No menu-bar helper                                                         | accepted |
| 0035 | AI feature scope for M7                                                    | accepted |
| 0036 | AI privacy default — local-first with per-action cloud confirmation        | accepted |
| 0037 | AI prompt storage — in-repo versioned markdown                             | accepted |
| 0038 | AI evaluation harness                                                      | accepted |
| 0039 | Onboarding — adaptive                                                      | accepted |
| 0040 | Keyboard-first with command palette                                        | accepted |
| 0041 | Multi-identity profiles — first-class                                      | accepted |
| 0042 | Accessibility and localization — full a11y, English at 1.0                 | accepted |
| 0043 | Credentials — Keychain-backed helper honoring existing tools               | accepted |
| 0044 | Commit signing — SSH signing in onboarding, default on                     | accepted |
| 0045 | Docs platform — DocC plus Astro Starlight                                  | accepted |
| 0046 | Release cadence — monthly stable plus weekly beta                          | accepted |
| 0047 | Git detection and install bootstrap                                        | accepted |
| 0048 | Cross-platform extensibility rules                                         | accepted |
| 0049 | Modern git config defaults                                                 | accepted |
| 0050 | Hook security model — trust prompt per-repo                                | accepted |
| 0051 | Stacked-PR workflow as first-class                                         | accepted |
| 0052 | Force-push aliasing — always --force-with-lease --force-if-includes        | accepted |
| 0053 | Day-1 cross-platform scaffolding commitment                                | accepted |

All 53 ADRs above were ratified simultaneously in the initial scaffolding, based on the planning dialogue captured in the master plan file. Subsequent ADRs follow the normal one-per-PR cadence.
EOF

########################################
# CI workflows
########################################

write .github/workflows/ci-macos.yml <<'EOF'
name: CI (macOS)
on:
  pull_request:
  push:
    branches: [main]

jobs:
  lint-build-test:
    runs-on: macos-14
    strategy:
      matrix:
        macos: [macos-14, macos-15]
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app || true
      - name: SwiftLint
        run: |
          brew install swiftlint || true
          swiftlint --strict
      - name: SwiftFormat (check-only)
        run: |
          brew install swiftformat || true
          swiftformat --lint .
      - name: Build packages
        run: swift build --configuration debug
      - name: Run tests
        run: swift test
EOF

write .github/workflows/ci-linux.yml <<'EOF'
name: CI (Linux — cross-platform guard for packages/)
on:
  pull_request:
  push:
    branches: [main]

jobs:
  build-portable:
    runs-on: ubuntu-24.04
    container:
      image: swift:6.3-noble
    steps:
      - uses: actions/checkout@v4
      - name: Build packages (portable subset)
        # Tier 1 + protocol shells of Tier 2 must compile on Linux.
        # Mac-only adapter sources are excluded by #if os(macOS).
        run: swift build
      - name: Run tests (portable subset)
        run: swift test
EOF

write .github/workflows/ci-windows.yml <<'EOF'
name: CI (Windows — advisory cross-platform guard)
on:
  pull_request:
  push:
    branches: [main]

jobs:
  build-portable:
    runs-on: windows-2022
    continue-on-error: true   # advisory until Windows port is prioritized
    steps:
      - uses: actions/checkout@v4
      - uses: compnerd/gha-setup-swift@main
        with:
          branch: swift-6.3-release
          tag: 6.3-RELEASE
      - name: Build packages
        run: swift build
      - name: Run tests
        run: swift test
EOF

write .github/workflows/benchmarks.yml <<'EOF'
name: Benchmarks (nightly)
on:
  schedule:
    - cron: "17 7 * * *"   # 07:17 UTC
  workflow_dispatch:

jobs:
  perf:
    runs-on: [self-hosted, macOS, arm64]   # hosted runners are too noisy for perf gates
    steps:
      - uses: actions/checkout@v4
      - run: swift package benchmark --format jmh > benchmarks.json
      - uses: actions/upload-artifact@v4
        with:
          name: benchmarks
          path: benchmarks.json
EOF

write .github/workflows/e2e.yml <<'EOF'
name: E2E (XCUITest)
on:
  pull_request:
    paths:
      - 'apps/macos/**'
      - 'packages/**'
  workflow_dispatch:

jobs:
  e2e:
    runs-on: [self-hosted, macOS, arm64]
    steps:
      - uses: actions/checkout@v4
      - run: ./script/test --suite=e2e
EOF

write .github/workflows/ai-evals.yml <<'EOF'
name: AI evals
on:
  pull_request:
    paths:
      - 'packages/AIKit/**'
      - 'tests/ai-evals/**'

jobs:
  evals:
    runs-on: ubuntu-24.04
    container:
      image: swift:6.3-noble
    steps:
      - uses: actions/checkout@v4
      - run: swift test --filter AIEvals
        env:
          SPRIG_AI_EVAL_FIXTURES: tests/ai-evals/fixtures
          # Provider keys set via GitHub secrets; Ollama runs in a sidecar.
EOF

write .github/workflows/release.yml <<'EOF'
name: Release
on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: [self-hosted, macOS, arm64]
    steps:
      - uses: actions/checkout@v4
      - run: ./script/release
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          APPLE_APP_SPECIFIC_PASSWORD: ${{ secrets.APPLE_APP_SPECIFIC_PASSWORD }}
EOF

write .github/dependabot.yml <<'EOF'
version: 2
updates:
  - package-ecosystem: "swift"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
EOF

write .github/CODEOWNERS <<'EOF'
# All PRs require review from the maintainer pre-1.0.
* @maintainer

# Cross-platform-sensitive paths need explicit review from anyone who touches
# them, because the ADRs 0048/0053 rules apply.
/packages/               @maintainer
/apps/macos/             @maintainer
/.github/workflows/      @maintainer
/docs/decisions/         @maintainer
EOF

write .github/PULL_REQUEST_TEMPLATE.md <<'EOF'
## Summary

<!-- 1–3 bullets describing the change -->

## Related ADRs

<!-- e.g., Implements ADR 0024. Supersedes part of ADR 0017. -->

## Test plan

- [ ] `./script/test` passes locally.
- [ ] No new banned imports in `packages/` (AppKit/SwiftUI/Cocoa/FinderSync/Combine/ServiceManagement/Sparkle).
- [ ] No new `#if os(...)` in portable package sources.
- [ ] No new hardcoded absolute paths.
- [ ] Destructive ops (if any) create snapshot refs via SafetyKit.
- [ ] CHANGELOG.md updated under `[Unreleased]` for user-visible changes.
EOF

write .github/ISSUE_TEMPLATE/bug.yml <<'EOF'
name: Bug report
description: Something's broken
labels: [bug]
body:
  - type: textarea
    attributes:
      label: What happened?
  - type: textarea
    attributes:
      label: What did you expect to happen?
  - type: textarea
    attributes:
      label: Steps to reproduce
  - type: input
    attributes:
      label: Sprig version
  - type: input
    attributes:
      label: macOS version
  - type: input
    attributes:
      label: git version (output of `git --version`)
EOF

write .github/ISSUE_TEMPLATE/feature.yml <<'EOF'
name: Feature request
description: Propose a new capability
labels: [enhancement]
body:
  - type: textarea
    attributes:
      label: What's the problem?
  - type: textarea
    attributes:
      label: What would the solution look like?
  - type: textarea
    attributes:
      label: Alternatives considered
EOF

write .github/ISSUE_TEMPLATE/docs.yml <<'EOF'
name: Docs issue
description: Something's unclear, missing, or wrong in the docs
labels: [docs]
body:
  - type: input
    attributes:
      label: Which page or file?
  - type: textarea
    attributes:
      label: What's the problem?
EOF

########################################
# docs/ tree placeholders
########################################

write docs/VISION.md <<'EOF'
# Vision

Sprig is a macOS-native, Finder-first Git client. See the master plan for full context.

## Target users

- **Novices** who want to use git without learning the CLI.
- **Power users** who want a fast, safe, scriptable GUI that stays out of the way.
- **Teams** that want shared defaults, safe destructive ops, and stacked-PR workflows.

## Differentiation

Deep Finder integration (badges + context menu on every file/folder) combined with task-specific windows for focused work. No persistent "app window with a file tree" — Finder is the file tree.

## Non-goals (at 1.0)

- Not cross-platform (but the core is portable for future ports — see `architecture/cross-platform.md`).
- Not a code editor or a hosting service.
- Not a replacement for the `git` CLI — a companion.
EOF

write docs/REQUIREMENTS.md <<'EOF'
# Requirements

Traceable requirement IDs referenced from code and tests. Derived from the master plan §1.1.

| ID | Requirement |
|----|-------------|
| R-01 | Right-click context menus in Finder for every git operation. |
| R-02 | Use the system `git` binary. |
| R-03 | Overlay icons in Finder for file status. |
| R-04 | FSEvents-based change notifications; no full rescans. |
| R-05 | Not a resource hog — minimize work per filesystem event. |
| R-06 | Novice-friendly and expert-complete. |
| R-07 | Submodule-aware throughout. |
| R-08 | Optional AI integration, especially for merge conflict resolution. |
| R-09 | Support all git extensions, including LFS. |
| R-10 | Default to modern git settings (Scalar-style). |
| R-11 | Modular architecture for easy contribution. |
| R-12 | Aim for large open-source adoption. |
| R-13 | Keep a questions log and a decision log. |
| R-14 | Maintain CLAUDE.md, MEMORY.md, and other best-practice files. |
| R-15 | Comprehensive testing infrastructure with GitHub CI. |
| R-16 | Cross-platform-ready from day 1 (future Windows/Linux ports additive). |
EOF

write docs/QUESTIONS.md <<'EOF'
# Open questions log

This file mirrors the "Still open" section of the master plan (§4). Items here are non-blocking and get resolved as execution proceeds.

## Non-blocking

- Brand availability: `sprig.app`, `sprig.dev`, `@sprig` on GitHub, USPTO search, `com.sprig.app` bundle-id. Fallback: Finch → Rookery.
- Mac Developer ID certificate ownership.
- Homebrew cask maintenance owner.
- Self-hosted runner provisioning details.
- Fixture storage: LFS in-repo vs. separate `sprig-fixtures` repo vs. public mirror.
- Docs domain activation.

## Expected follow-up rounds

- Round 9 (M1): porcelain-v2 parser edge cases, fsmonitor wire protocol, repo-ignore rules.
- Round 10 (M3): per-task-window UX details.
- Round 11 (M4): merge UI specifics.
- Round 12 (M7): AI prompt tuning, eval corpus composition, provider quirks.
EOF

write docs/GLOSSARY.md <<'EOF'
# Glossary

## Sprig-specific terms

- **Tier 1 / 2 / 3** — portable core / platform adapter / platform shell. See `architecture/cross-platform.md`.
- **MVP-10** — the ten Finder right-click actions shipping at M2 (clone, status, commit, push, pull, fetch, branch-switch, stage/unstage, diff, log).
- **Task window** — a focused, standalone SwiftUI window launched from a Finder right-click.
- **Snapshot ref** — a ref under `refs/sprig/snapshots/<timestamp>/<op>` auto-created before destructive ops. 30-day TTL.
- **Watch root** — a directory Sprig scans for repos at startup.

## Git terms Sprig surfaces

- **fsmonitor** — a daemon that tells git which files have changed since the last query, making `git status` O(changes) instead of O(tree).
- **Scalar stack** — Microsoft's opinionated bundle of git config for large repos: fsmonitor, commit-graph, multi-pack-index, partial clone, sparse-checkout, maintenance.
- **Partial clone** — a clone that defers blob download; filter `--filter=blob:none`.
- **Sparse-checkout cone mode** — a worktree that materializes only specified directories.
- **LFS pointer** — the tiny text file that replaces a large binary under Git LFS.

## macOS terms

- **FinderSync** — Apple's extension point for Finder badges + context menus.
- **FSEvents** — macOS kernel API for filesystem change notifications.
- **XPC** — macOS inter-process RPC.
- **LaunchAgent** — per-user background service registered with launchd.
- **Notarization** — Apple's post-sign malware-scan step; required for direct distribution.
EOF

# Architecture placeholder docs
for f in overview modules fs-watching finder-integration git-backend ai-integration security performance; do
    cap="$(echo "$f" | sed -e 's/-/ /g' -e 's/\b\(.\)/\u\1/g')"
    write "docs/architecture/${f}.md" <<EOF
# ${cap}

Placeholder. The authoritative text for this topic lives in the master plan at \`/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md\`. This file will be expanded as the milestone that exercises this area lands (see \`docs/planning/roadmap.md\`).
EOF
done

write docs/architecture/cross-platform.md <<'EOF'
# Cross-Platform Architecture

Sprig is macOS-only at 1.0 but the codebase is structured so a future Windows or Linux port is additive.

This document mirrors §12 of the master plan (`/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md`). The plan is the source of truth; this file will be expanded during M0 with concrete code examples.

## The three tiers

1. **Portable core** (`packages/{GitCore, RepoState, ConflictKit, AIKit, LFSKit, SubmoduleKit, SubtreeKit, SafetyKit, IPCSchema, PlatformKit, DiagKit, StatusKit, TaskWindowKit, UIKitShared}/`) — pure Swift + Foundation. Must compile on macOS, Linux, Windows.
2. **Platform adapters** (`packages/{WatcherKit, CredentialKit, NotifyKit, UpdateKit, LauncherKit, TransportKit, AgentKit}/`) — protocol in `Sources/<Pkg>/`; macOS impl in `Sources/Mac/`; Linux/Windows stubs in `Sources/{Linux,Windows}/`.
3. **Platform shells** (`apps/{macos,windows,linux}/`) — full rewrite per OS; only macOS populated at 1.0.

## Hard rules (CI-enforced)

1. No `AppKit`/`SwiftUI`/`Cocoa`/`FinderSync`/`Combine`/`ServiceManagement`/`Sparkle` imports in `packages/`.
2. No `#if os(...)` in portable package sources; only in `Sources/{Mac,Linux,Windows}/`.
3. No hardcoded absolute paths.
4. Every `PlatformKit` protocol has Mac/Linux/Windows source files from day 1 (Linux/Windows may be `fatalError` stubs).
5. `ci-linux` builds `packages/` on every PR; red build blocks merge.

## Adapter seams

See `packages/PlatformKit/` for the authoritative protocol list: `FileWatcher`, `CredentialStore`, `NotificationPresenter`, `UpdateChannel`, `Transport`, `ServiceLauncher`, `PathResolver`, `GitLocator`.

## Porting checklist

When a Windows or Linux port begins:

1. Populate `apps/<platform>/` with the platform shell.
2. Replace `fatalError` stubs in `packages/*/Sources/{Linux,Windows}/` with real impls.
3. Flip `ci-<platform>` to required-green.
4. Write a port-specific `docs/architecture/<platform>-port.md`.

No file moves. No protocol refactors. That's the deal.
EOF

write docs/ci/self-hosted.md <<'EOF'
# Self-hosted runner provisioning

Placeholder. Self-hosted macOS ARM64 runner setup, secret storage, signing-cert handling will be documented here before M2.
EOF

write docs/ci/linux-matrix.md <<'EOF'
# Linux CI matrix

Placeholder. Which Swift toolchain, which git versions, which container images. Populated in M0.
EOF

write docs/planning/roadmap.md <<'EOF'
# Roadmap

Mirrors §6 of the master plan.

- **M0 — Foundations**: Docs, CI (macOS + Linux + Windows `packages/`), SPM skeleton, ADRs 0001–0053 accepted. Contributor onboarding usable.
- **M1 — Read-only prototype**: FSEvents watcher, porcelain-v2 parser, `sprigctl` CLI. Validates 100k-file perf budget.
- **M2 — SprigAgent + FinderSync alpha**: LaunchAgent, XPC, overlay badges, MVP-10 context-menu actions (sheets, not task windows yet).
- **M3 — First task windows**: CommitComposer, LogBrowser, DiffViewer, BranchSwitcher, CloneDialog, Preferences.
- **M4 — MergeConflictResolver (MVP gate)**: 3-way merge view, conflict list, hunk accept/reject, snapshot safety net. **MVP ships here.**
- **M5 — Rebase + advanced branching**: RebaseInteractive, cherry-pick, revert, tag, stash.
- **M6 — Submodules + LFS first-class**: SubmoduleManager, LFS install flow, `git subtree` import wizard.
- **M7 — AI integration**: Merge suggestions, commit-message drafting, PR description drafting. Ollama one-click installer.
- **M8 — Beta**: Perf budgets verified in CI; a11y pass; localization scaffolding.
- **M9 — 1.0**: Signed/notarized DMG, Sparkle appcast, Homebrew Cask, docs site, launch.
EOF

write docs/planning/milestones.md <<'EOF'
# Milestones — exit criteria

Placeholder. Each milestone's concrete exit criteria (tests, benchmarks, UX validations) live here. Populated as each milestone is scoped.
EOF

write docs/planning/risk-register.md <<'EOF'
# Risk register

Mirrors §9 of the master plan.

- FinderSync extension quirks (Apple-side).
- `core.fsmonitor` wire-protocol drift.
- AI data-leakage anxieties.
- Monorepo perf regressions (Chromium/kernel scale).
- Mac Developer ID dependency ($99/year).
- LFS + bundling licensing check.
- Contributor onboarding friction (<15 minutes clone-to-contribution).
- Bus factor (BDFL model through 1.0).
EOF

write docs/planning/governance-transition.md <<'EOF'
# Governance transition plan

Placeholder. Drafted by M7. Captures when and how to open a steering committee, recruit maintainers, and retire the BDFL role.
EOF

write docs/ux/principles.md <<'EOF'
# UX Principles

- **Finder-first**: every feature reachable from a right-click.
- **Safe by default**: tiered confirmations + snapshot refs for destructive ops.
- **Novice-safe, expert-complete**: wizards for learners, palette + shortcuts for power users.
- **Privacy-first AI**: local providers default; cloud providers BYOK + per-action confirmation.
- **No surprise network calls**: offline mode is fully functional for git operations.
EOF

write docs/ux/flows/.gitkeep <<'EOF'
EOF

write docs/ux/wireframes/.gitkeep <<'EOF'
EOF

write docs/research/git-feature-inventory.md <<'EOF'
# Git Feature Inventory

See §10 of the master plan at `/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md` for the full tiered inventory (Tier 1 MVP, Tier 2 1.0, Tier 3 post-1.0, Tier 4 out-of-scope) plus the security, performance, and recovery cross-cutting sections and the TortoiseGit composite-workflow mapping.

This file will be expanded during M0 with the full content and kept in sync as features land.
EOF

write docs/research/git-best-practices.md <<'EOF'
# Git Best Practices Sprig Adopts or Promotes

See §11 of the master plan for the full document: ~60 interventions tagged (a) silent default, (b) prompt-on-first-encounter, (c) onboarding, (d) document only, or (e) leave to user. Covers config defaults, performance hygiene (Scalar stack), security, branch/commit/history hygiene, recovery UX, hooks, LFS, submodules, secrets, and collaboration.

Expanded to full content during M0.
EOF

write docs/research/tortoisegit-feature-map.md <<'EOF'
# TortoiseGit → Sprig feature mapping

Placeholder. Verb-by-verb mapping of TortoiseGit menu items to Sprig equivalents, for users coming from Windows.
EOF

write docs/research/competitive-analysis.md <<'EOF'
# Competitive analysis — macOS Git GUIs

Placeholder. SourceTree, Tower, Fork, GitUp, GitHub Desktop, Sublime Merge. Strengths/weaknesses, pricing, positioning, and what Sprig does differently.
EOF

write docs/research/macos-finder-apis.md <<'EOF'
# macOS FinderSync + related APIs

Placeholder. FinderSync gotchas, overlay slot limits, sandboxing impact, user-granted paths, known-good patterns from Dropbox/Google Drive. Required reading before M2.
EOF

########################################
# script/ helpers
########################################

write script/bootstrap <<'EOF'
#!/usr/bin/env bash
# Set up a local dev environment. Idempotent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Bootstrapping Sprig dev environment"

if ! command -v swift >/dev/null 2>&1; then
    echo "Swift toolchain not found. Install Swift 6.3+ from https://swift.org/download" >&2
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "git not found. On macOS: 'xcode-select --install' or 'brew install git'." >&2
    exit 1
fi

echo "==> Resolving SwiftPM dependencies"
swift package resolve

echo "==> Building packages (portable graph)"
swift build

echo "==> Done. Run './script/test' to verify your environment."
EOF
chmod +x script/bootstrap

write script/test <<'EOF'
#!/usr/bin/env bash
# Run the local test matrix.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SUITE="${1:---suite=unit}"

case "$SUITE" in
    --suite=unit|"")
        echo "==> swift test (unit)"
        swift test
        ;;
    --suite=integration)
        echo "==> swift test (integration)"
        swift test --filter Integration
        ;;
    --suite=e2e)
        echo "==> XCUITest (requires macOS + signed build)"
        xcodebuild test -project apps/macos/SprigApp/SprigApp.xcodeproj \
            -scheme SprigAppUITests -destination 'platform=macOS'
        ;;
    --suite=all)
        swift test
        ;;
    *)
        echo "Unknown suite: $SUITE" >&2
        exit 2
        ;;
esac
EOF
chmod +x script/test

write script/release <<'EOF'
#!/usr/bin/env bash
# Build signed + notarized DMG, update Sparkle appcast, open Homebrew cask PR.
# Only runs on macOS self-hosted runner during a tag push.
set -euo pipefail
echo "Release pipeline not yet implemented. Placeholder until M9." >&2
exit 1
EOF
chmod +x script/release

########################################
# apps/ placeholders
########################################

write apps/windows/README.md <<'EOF'
# apps/windows/

Placeholder. The Windows port populates this directory post-1.0. See `/docs/architecture/cross-platform.md` for the design.

Expected contents when the port begins:

- `SprigApp/` — WinUI 3 or swift-cross-ui shell.
- `SprigAgent/` — Windows Service wrapper.
- `SprigExplorer/` — `IShellIconOverlayIdentifier` + `IContextMenu` shell extension.
- `Installer/` — MSIX manifest + WiX scripts.
EOF

write apps/linux/README.md <<'EOF'
# apps/linux/

Placeholder. The Linux port populates this directory post-1.0. See `/docs/architecture/cross-platform.md` for the design.

Expected contents when the port begins:

- `SprigApp/` — GTK4 or swift-cross-ui shell.
- `SprigAgent/` — systemd `--user` unit wrapper.
- `SprigNautilus/` — Nautilus Python extension (Dolphin/Thunar variants follow).
- `Installer/` — Flatpak manifest + AppImage build files.
EOF

write apps/macos/README.md <<'EOF'
# apps/macos/

The macOS app. Contains the SwiftUI + AppKit shell, the LaunchAgent background service, the FinderSync extension, the (stretch) Quick Look preview extension, and the DMG installer scripts.

This is the only `apps/` dir populated at 1.0. Windows and Linux shells, if ever built, are additive — they do **not** require reshaping any packages in `packages/`.

- `SprigApp/` — main app bundle; SwiftUI task windows; the only place `import AppKit/SwiftUI` is allowed.
- `SprigAgent/` — LaunchAgent wrapper around `AgentKit`.
- `SprigFinder/` — FinderSync extension; thin, delegates to SprigAgent over XPC.
- `SprigQuickLook/` — (M6+) `.diff` preview.
- `Resources/` — app icon, 10-badge asset catalog, `.xcstrings` string catalogs.
- `Entitlements/` — per-target entitlements plists.
- `LaunchAgent/` — `com.sprig.agent.plist` template.
- `Sparkle/` — appcast config + EdDSA public-key placeholder.
- `Installer/` — DMG + notarization scripts.

Xcode project skeletons are materialized in M2.
EOF

########################################
# tests/ placeholders
########################################

write tests/README.md <<'EOF'
# Tests

- `integration/` — spawns real `git` across a version matrix (2.39, current Homebrew, latest upstream).
- `e2e/` — XCUITest on a self-hosted macOS runner.
- `snapshots/` — golden diff + merge rendering.
- `benchmarks/` — `package-benchmark`-based perf gates.
- `ai-evals/` — held-out conflict corpus + gold resolutions.
- `fixtures/` — hash-pinned test repos (clean, dirty, conflict, submodule, LFS, 100k-file, 500k-file).

See the master plan §5.5 for the full testing strategy and CI gates.
EOF

for d in integration e2e snapshots benchmarks ai-evals; do
    write "tests/$d/.gitkeep" <<EOF
EOF
done

write tests/fixtures/README.md <<'EOF'
# Test fixtures

Hash-pinned repo snapshots used by integration, E2E, and benchmark suites.

Format: `tests/fixtures/repos/<name>.tar.zst` stored via Git LFS with a corresponding SHA-256 checksum in `checksums.txt`. The test helper extracts on demand to `tests/fixtures/repos/<name>.extracted/` (gitignored).

## Adding a fixture

1. Create the repo state, tar it with `zstd -19`.
2. Compute the SHA-256 and add to `checksums.txt`.
3. Add the tarball via `git lfs track` then `git add`.
4. Document the fixture's purpose and shape in a per-fixture `.md` next to the tarball.
EOF

echo
echo "Scaffolding seed complete."
