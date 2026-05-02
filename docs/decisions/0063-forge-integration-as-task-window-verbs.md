---
status: accepted
date: 2026-05-02
deciders: maintainer
consulted: —
informed: —
---

# 0063. Forge integration — task-window verbs (no "PRs" tab)

## Context and problem statement

Every other Git GUI in 2026 puts pull requests / merge requests in a **separate "PRs" tab or panel** inside the main app window. GitHub Desktop has a Pull Requests dropdown; GitKraken has a PR panel; Tower has a Pull Requests sidebar. That pattern is incompatible with Sprig's Finder/Explorer-first invariant (ADRs 0030, 0034) — Sprig has no main app window with tabs.

The competitive review (master plan §13.3-F) cites Magit Forge as the design hint: PRs and issues live as **foldable sections in the same status buffer as local changes**. The lesson: don't split "git stuff" and "PR stuff" into separate apps. Reframed for Finder/Explorer-first, this becomes: **forge integration is a verb, not a place.**

## Decision drivers

- Preserve the Finder/Explorer-first invariant — no main-window PRs tab/panel/sidebar.
- Make forge integration discoverable from the right-click menu (where users already are).
- Cover GitHub, GitLab, Bitbucket, Gitea uniformly via a small forge-abstraction layer.
- Don't require a forge to be configured for any local operation to work.

## Considered options

1. **Right-click verbs + side-data badges in existing windows** (this ADR — three of four originally proposed sub-items).
2. Right-click verbs only — no badges anywhere. Less integrated; users don't see PR state when browsing branches.
3. Forge as a separate "PRs" tab in a main app window. Rejected — violates Finder/Explorer-first.
4. Skip forge integration; users go to the browser. Cheapest; loses a major feature.

## Decision

**Option 1** — three coordinated surfaces, no main-window tab, no persistent panel.

### 1. Right-click → Sprig ▶ → Open PR for this branch (when one exists)

When the right-clicked path is inside a worktree whose current branch (or the explicitly-selected remote-tracking branch) has an open PR/MR on the configured forge, this verb appears. It opens a **PR Review task window**:

- Header: PR title, number, author, state (open/draft/approved/changes-requested/merged).
- Tab-less body: file-tree (changed files in the PR), inline diff, comments rendered next to the lines they target, CI status block.
- Action row (per ADR 0058 chip patterns): "Approve", "Request changes", "Comment", "Merge…" (the last opens a confirmation task window with merge-style chips).
- The task window opens, the user reviews, the user closes. Per ADR 0030, no persistent state.

### 2. Right-click → Sprig ▶ → Create PR… (when branch has no open PR)

Opens a **PR Composer task window**:

- Title, description (pre-filled from the branch's commit list — first-commit-subject as title, joined commit bodies as description), base branch (default: repo's default branch, overridable), draft toggle, reviewers chip-list.
- "Create" runs the forge's create-PR API, then either closes (if successful) or surfaces the API error inline.
- Post-create: the task window transitions seamlessly into the PR Review surface from §1, so the user can review their own PR if they want.

### 3. PR status badges in BranchSwitcher

When BranchSwitcher renders remote-tracking branches, branches that have associated open PRs/MRs get a small badge: `Open / Draft / Approved / Changes Requested / Merged`. The badge is clickable to open the PR Review surface.

This is "side data," not a panel — the badges decorate existing UI rather than adding new persistent UI.

### 4. Forge abstraction layer

`packages/IPCSchema/Sources/IPCSchema/Forge/` (or a new Tier-1 `ForgeKit` package — decided at implementation time) defines:

- `Forge` protocol (Sendable): `func openPullRequest(ref:base:title:body:draft:) async throws -> PullRequest`, `getPullRequest(branch:) async throws -> PullRequest?`, etc.
- Conformances: `GitHubForge`, `GitLabForge`, `BitbucketForge`, `GiteaForge`.
- Forge detection: from `git remote get-url origin`, classify the host (`github.com` / `*.githubusercontent.com` for Enterprise / `gitlab.com` / `*.gitlab.com` self-hosted / `bitbucket.org` / `*.atlassian.com` / arbitrary Gitea host via probe).
- Authentication: per-forge credential per ADR 0043 (Keychain-backed); device-flow OAuth supported for GitHub and GitLab.

Forge calls are issued by the Sprig agent (not the task window) so the credential never leaves the agent's address space; task windows render results delivered over IPC.

### Deliberately excluded (deferred past 1.0)

A fourth originally-proposed sub-item — **draft PR description scaffold in CommitComposer footer** — was deferred. Rationale: it couples to ADR 0035's AI surface; pre-filling a draft description from staged commits is straightforward, but generating one *with* AI assistance overlaps with M7's commit-message-AI work. Revisit at M7 to integrate consistently with the AI feature scope.

## Consequences

**Positive**
- Forge integration as first-class without a "PRs" tab — preserves Finder/Explorer-first.
- Right-click discoverability matches the rest of Sprig.
- The PR Review task window is the most-feature-rich PR surface in any non-browser tool because it's a dedicated window, not a side panel: full diff layout, syntax highlighting, comment threads inline.
- One forge abstraction lets all 4 surfaces (Open PR, Create PR, BranchSwitcher badges, future Stack Manager forge calls per ADR 0062) reuse the same code path.

**Negative / trade-offs**
- BranchSwitcher's badge rendering needs forge API calls; rate limits affect repos with many remote branches. Mitigation: cache aggressively (30s TTL for status; ETag-based conditional GET); render "—" when uncached and update progressively.
- The PR Review task window has a lot of surface area: diff renderer, comment-thread rendering, action chips, merge-style options. Multi-PR design + a11y review.
- Bitbucket Cloud and Gitea have inconsistent API capabilities (e.g., suggested-changes-as-commits is GitHub-only). Per-forge feature matrix lives in `docs/architecture/shell-integration.md`.
- Forge auth tokens scope risk — per-forge OAuth grants need clear "what can Sprig do" copy in onboarding.
- Forge-down outages (e.g., GitHub status incident) need graceful degradation: badges show "Forge unreachable," PR Review surfaces a retry banner, local ops continue working.

## Links

- Master plan §13.3-F.
- Related ADRs: 0030 (Finder-first), 0034 (no menu-bar), 0035 (AI scope — informs deferred scaffold), 0043 (Keychain-backed credentials), 0044 (signing), 0058 (chip-style action row in PR Review window), 0062 (stacks reuse the forge layer for PR-base-branch updates).
- Magit Forge reference: <https://magit.vc/manual/forge/>
