# Git best practices Sprig adopts or promotes

The full text — ~60 interventions tagged by intervention level — lives in **§11 of the master plan** at `/home/bill/.claude/plans/please-switch-to-plan-glittery-corbato.md`. This file is a brief index against that.

## Intervention levels

| Tag | Meaning | Example |
|---|---|---|
| **(a) silent default** | Sprig writes the value during onboarding or per-repo init; visible in Settings → Git Defaults but not surfaced as a question | `pull.ff=only`, `push.autoSetupRemote=true`, `rerere.enabled=true` |
| **(b) prompt on first encounter** | First time the situation arises, ask the user; cache the decision | hook-trust review, "stage a `.env` file?", LFS-track a 50 MB file? |
| **(c) onboarding** | Asked once during first-run wizard | identity, signing method, workflow style (GitHub Flow / Trunk / GitFlow) |
| **(d) document only** | We don't change behavior; docs explain the rationale | merge-vs-rebase per-op, GitFlow tradeoffs, submodule deprecation |
| **(e) leave to user** | Stylistic; Sprig doesn't have an opinion | commit-body style beyond 50/72 |

Approximate counts (master plan §11.13): **~30 (a), ~12 (b), ~6 (c), ~8 (d), ~2 (e)**.

## Section index (per master plan §11)

- **§11.1** — Config defaults Sprig writes (the ~30 (a) silent defaults table — `init.defaultBranch=main`, `core.fsmonitor=true`, `pull.ff=only`, `merge.conflictStyle=zdiff3`, `diff.algorithm=histogram`, `rebase.updateRefs=true`, etc.). Captured authoritatively in **ADR 0049**.
- **§11.2** — Performance hygiene (Scalar-style, tiered by repo size). Small/medium/large repos get progressively more aggressive perf config. Authoritative in **ADR 0026**.
- **§11.3** — Security defaults. `safe.directory` prompt, SSH signing as preferred default, Keychain credentials, hook-trust on first encounter. Authoritative in **ADRs 0043, 0044, 0050**.
- **§11.4** — Branch + workflow hygiene. `main` default, GitHub Flow as default mental model, protected-branch detection, merge-vs-rebase exposed equally.
- **§11.5** — Commit hygiene. Conventional Commits prompt per-repo, per-hunk staging in commit UI, `commit.verbose=true`, signing visible in commit UI.
- **§11.6** — History integrity. `reset --hard` always confirms (no "don't ask again"), force-push aliased to `--force-with-lease --force-if-includes` (ADR 0052), warning when rewriting published history.
- **§11.7** — Recovery UX ("Time Machine for Git"). Reflog browser, snapshot refs (`refs/sprig/snapshots/...`, ADR 0033), `fsck --lost-found` integration.
- **§11.8** — Hooks. Default stance: no hooks unless user opts in. Sprig-managed hooks under `.sprig/hooks/` checked into the repo. Third-party hook trust prompts (ADR 0050).
- **§11.9** — Git LFS. Detection + one-click install (ADR 0029). Migration warnings ("rewrites history"), bandwidth-awareness panel, LFS lock UX.
- **§11.10** — Submodules, subtrees, monorepo. Discourage submodules for new projects; document the decision tree. Best-practice defaults for repos that already use them (`submodule.recurse=true`, `push.recurseSubmodules=check`).
- **§11.11** — Secrets + safety. gitleaks-style pre-commit scan, global `.gitignore` populated with macOS noise (`.DS_Store`, `.AppleDouble`, etc.), "remove file from history" wizard with revocation-first emphasis.
- **§11.12** — Collaboration hygiene. PR/MR integration with GitHub/GitLab/Bitbucket/Gitea. Stacked-PR detection (ADR 0051). Draft PRs as default for fresh branches.

## What this file becomes

When M2/M3 land and these defaults are actually being written by Sprig at runtime, this file gets **per-default verification text**: "What does the user see in Settings? What's the override path? What test covers it?" Until then, the master plan §11 is the source.

## Source list (master plan §11.13)

- Pro Git 2e (git-scm.com/book)
- Scalar docs (microsoft/scalar, upstreamed into git itself)
- git release notes 2.35–2.46
- GitHub / GitLab / Atlassian best-practice docs
- CVE-2022-24765 (`safe.directory` rationale)
- gitleaks (gitleaks/gitleaks)
- `git filter-repo` docs
