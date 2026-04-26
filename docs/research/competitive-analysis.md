# Competitive analysis — Git GUIs

Where Sprig sits in the landscape, what it borrows, and what differentiates it. **Light placeholder** at this stage; expanded pre-1.0 marketing prep with deeper feature matrices and screenshots.

## macOS Git GUIs

| Tool | Pricing | UI model | Finder integration | What Sprig learns from it | What Sprig does differently |
|---|---|---|---|---|---|
| **SourceTree** (Atlassian) | Free | Single main window, file tree + commit history split | None | Free + macOS-native baseline | Sprig has no main window (ADR 0030); Finder is the browser |
| **Tower** | $69/yr (paid) | Single main window, polished | Limited | Polished onboarding; great rebase UI | FOSS license; Finder integration; AI |
| **Fork** | $50 one-time | Single main window | None | Clean diff viewer | FOSS; Finder integration; modern git defaults applied |
| **GitUp** | Free | Single main window with live commit graph | None | Interactive graph as direct manipulation | Modern git features (fsmonitor, partial clone); cross-platform engine |
| **GitHub Desktop** | Free, Electron | Single main window, simple | None | Beginner-friendly onboarding; OAuth flows | Native (not Electron); full git-power-user surface; multi-host (GitLab/Bitbucket too) |
| **Sublime Merge** | $99 one-time (free w/ unobtrusive nag) | Single main window, very fast | None | Speed; minimal UI chrome | FOSS; Finder integration |
| **Magit** (Emacs, technically not GUI) | Free | Emacs buffers | N/A | Verb-keystroke completeness | Visual + Finder-integrated for non-Emacs users |

**The gap Sprig fills:** none of these implement Finder badges or right-click verbs. The discontinued SourceTree Beta from 2014 was the last attempt. macOS users who want TortoiseGit-on-Mac currently have nothing.

## Windows Git GUIs

| Tool | Pricing | UI model | Explorer integration | What Sprig learns from it | What Sprig does differently |
|---|---|---|---|---|---|
| **TortoiseGit** | Free, OSS | Explorer-only (no main window) | Full: badges, right-click menu | The entire architectural premise (ADR 0030) | Cross-platform — same UX on macOS; AI features; modern git defaults (Scalar) |
| **GitHub Desktop** | Free, Electron | Single main window | None | OAuth flows, beginner UX | Explorer integration like TortoiseGit |
| **Fork** | $50 one-time | Single main window | None | Clean diff viewer | FOSS; Explorer integration |
| **GitKraken** | $0 free / $7/mo Pro | Single main window, Electron | None | Keyboard-first command palette | Native (swift-cross-ui not Electron); FOSS; Explorer integration |
| **SourceTree (Win)** | Free | Single main window | None | Same as macOS analogue | Explorer integration; AI |
| **Sublime Merge (Win)** | $99 one-time | Single main window, fast | None | Speed | FOSS; Explorer integration |
| **Atlassian Bitbucket Desktop** | Free | Electron | None | — | Native; Explorer integration |

**The gap Sprig fills on Windows:** TortoiseGit hasn't had a major UX refresh in years; competitors are all "another main window with file tree." A modern, AI-enhanced, Scalar-defaults-aware TortoiseGit is the niche.

## Cross-platform Git GUIs

| Tool | Stack | Notes |
|---|---|---|
| **GitKraken** | Electron + libgit2 | 100% code share via Electron; pays the memory + startup cost. What Sprig avoids. |
| **GitHub Desktop** | Electron + `dugite` (shells out to git) | Strong precedent for shell-out-to-git as cross-platform. `GitCore` is effectively Swift `dugite`. |
| **Sublime Merge** | C++ core + custom UI toolkit | Proves native-feeling cross-platform is possible. swift-cross-ui is the Swift analogue (ADR 0055). |
| **Fork** | separate macOS + Windows native codebases | Diverged feature sets, maintenance trap. What we're avoiding via the three-tier architecture. |

## Sprig's positioning

**Headline:** "TortoiseGit, modernized, on every platform that matters."

**Differentiators (in priority order):**

1. **Shell-integrated on macOS *and* Windows.** No competitor does both. (Linux is post-1.0.)
2. **FOSS Apache-2.0** with no paid tier. Tower / Fork / Sublime Merge / GitKraken Pro all charge.
3. **Modern git defaults out of the box** — Scalar's perf bundle (ADR 0026), `pull.ff=only`, `rebase.updateRefs`, `merge.conflictStyle=zdiff3`, ~30 silent defaults. None of the other GUIs ship with these on by default.
4. **Stacked-PR workflow as a first-class verb** (ADR 0051). Graphite / ghstack-class workflow without a CLI dependency.
5. **Local-first AI** for merge conflicts and commit messages (ADRs 0035–0038). Cloud providers gated behind explicit confirmation; Ollama / Apple Foundation Models are the default.
6. **Recovery is a feature** — snapshot refs, reflog browser, "Time Machine for Git" UX (ADR 0033). Most GUIs hide reflog; Sprig surfaces it.
7. **No menu-bar / tray app** (ADR 0034). The shell extension is the surface; we don't add another always-running icon.

**Anti-differentiators (where Sprig doesn't try to win):**

- Not faster than Sublime Merge for raw scrolling through history. We're competitive, not leaders, on micro-perf.
- Not as polished as Tower for first-time-Mac-user onboarding. We're competitive, not leaders, on novice hand-holding (Tower has had a decade of polish).
- Not a code editor. Diff/merge viewers are first-class; full-file editing delegates to the user's editor of choice.
- Not a hosting platform. PR/MR features integrate with GitHub/GitLab/Bitbucket/Gitea; we don't host.

## Pre-1.0 expansion plan

This file becomes the marketing-team handoff. Concretely:

- Per-tool feature matrix (50+ features × 8 tools).
- Screenshots side-by-side for the same workflow.
- Pricing comparison with currency-aware rendering.
- "Migration guide" sections for users coming from each tool — what's the same, what's different, what they'll miss.

That work is part of the M9 (1.0) marketing-prep tranche.
