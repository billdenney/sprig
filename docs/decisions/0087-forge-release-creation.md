---
status: proposed
date: 2026-06-18
deciders: maintainer
consulted: —
informed: —
---

# 0087. Forge release creation — GitHub/GitLab releases (tag + notes + assets) as a task-window verb

## Context and problem statement

`git tag` is in the MVP feature inventory, but creating a **forge Release** (a GitHub/GitLab
Release object with notes and uploaded assets) is unscoped — the existing "release" material
is all about Sprig's own release *cadence* (ADR 0046), not the artifact. Maintainers and
many ordinary users expect "tag a version and publish a release with notes" to be a single
guided action; `ForgeKit` already handles browse (ADR 0078) and sign-in (ADR 0081), so the
remaining piece is the release client + a task window.

## Considered options

1. **A `ForgeKit` release client + `CreateReleaseViewModel`, surfaced as a verb** (this ADR).
2. Plain `git tag` push only, no forge object — fails the "publish a release with notes" need.
3. Shell out to `gh`/`glab` — adds a tool dependency and diverges from the in-app forge flows.

## Decision

**Add a provider-agnostic release client to `ForgeKit` (GitHub Releases API and GitLab
Releases API behind one protocol) and a `CreateReleaseViewModel` (TaskWindowKit), surfaced
from a tag/commit context as "Create Release…".** Inputs: target tag (existing, or create a
new annotated tag at a commit), title, notes (optional — the AI draft path rides ADR
0095/0035 later), and assets (file picker → upload). Auth reuses `ForgeKit.ForgeDeviceFlow`
and `CredentialKit` with the established **tokens-injected-never-persisted** pattern (ADR
0078). Network/HTTP transport goes through `TransportKit`.

**Publishing is consent.** Release creation is a publish action: it falls in the
explicit-permission category and always shows a confirmation summarizing what will be created
where; it is never automatic and never implied by another verb.

Deferred: editing/deleting existing releases, pre-release/draft toggles beyond the basic
flag, and Bitbucket/Gitea providers (add behind the same protocol when their forge verbs land).

## Consequences

**Positive**
- Completes the "ship a version" workflow without a CLI or a browser detour.
- Natural follow-on to the stacked-PR/merge flows (ADR 0051/0062).

**Negative / trade-offs**
- Per-provider API drift (asset upload differs between GitHub and GitLab) lives in `ForgeKit`.
- Asset upload needs progress/resumability thinking for large files (note for the impl).

## Links

- ADR 0063 (forge integration as task-window verbs), 0078 (forge browse / token handling),
  0081 (forge sign-in device flow), 0046 (Sprig's own release cadence — distinct concern),
  0095 (optional AI-drafted release notes). Transport via `TransportKit`.
