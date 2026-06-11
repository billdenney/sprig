---
status: accepted
date: 2026-06-11
deciders: maintainer ("lean in further and proceed"; 3.2 named next), engineering
consulted: —
informed: —
---

# 0078. Clone wizard forge browse — pick from a list, tokens injected

## Context and problem statement

Affordance 3.2: beginners shouldn't need to find, copy, and paste a clone URL — show them
their own repositories and let them pick. ADR 0063 frames forge integration broadly (PR
verbs, badges); this is its first engine piece, and it forces the layering question: where
do forge tokens live?

## Decision

**A new Tier-1 `ForgeKit` package lists the authenticated user's repositories; tokens are
INJECTED, never persisted here.** The layering:

- **`ForgeKit.ForgeRepoBrowser`** (portable, Foundation + FoundationNetworking) — GitHub
  first: `GET /user/repos?per_page=100&sort=pushed` with a bearer token, decoded into the
  provider-neutral `ForgeRepo` (fullName, clone/ssh URLs, description, private). Typed
  errors: `unauthorized` (401 — the UI's "reconnect your account" signal), `httpStatus`,
  `malformedResponse`. `baseURL` is injectable (GitHub Enterprise + tests). The HTTP seam
  mirrors AIKit's proven `HTTPClient` shape — injectable; only *git* is never-mocked here.
- **`CloneDialogViewModel`** gains `browseRepos(provider:token:)` → `browseResults` +
  `browseError` (kept off `state`: browsing is a form aid and must never clobber an
  in-flight clone's lifecycle), and `selectBrowsed(_:)` — the HTTPS URL becomes the source
  and the repo name seeds an EMPTY target directory (a user-typed target is never
  clobbered).
- **Token acquisition is shell/onboarding work** (OAuth device flow, "what can Sprig do"
  copy per ADR 0063's consequences) and **storage is CredentialKit's platform adapters**
  (Keychain / DPAPI / Secret Service — stubs today). Recording that boundary is half this
  ADR's point: the portable layer treats the token as an opaque input.

Pagination beyond the first 100 (Link header) and GitLab/Bitbucket/Gitea providers are
noted follow-ups; the enum is where they join.

## Considered options

1. **Tier-1 listing client + injected tokens** (this ADR).
2. Storage in ForgeKit (e.g. a token file) — duplicates CredentialKit's reason to exist and
   puts secrets on disk without platform keystores. Rejected.
3. Shell-side API calls (each shell hits the forge directly) — duplicates per-forge wire
   code three ways and leaves sprigctl without a future face. Rejected.
4. `gh`/`glab` CLI shell-out — adds binary dependencies with their own auth state; the
   defer-to-git principle doesn't extend to forge CLIs (ADR 0023 is about git's own
   behaviors).

## Consequences

- The Clone window can offer "browse your GitHub repos" the moment a shell can produce a
  token; the engine and tests don't wait for that.
- ForgeKit is the natural home for ADR 0063's later verbs (PR list/create, badge queries) —
  same client seam, same token boundary.
- A `sprigctl clone --browse` face needs a token source (env var or CredentialKit) — rides
  the CredentialKit slice.

## Links

- Implements `docs/research/git-beginner-affordances.md` item 3.2 (engine half).
- ADR 0063 (forge integration umbrella), 0048 (tier discipline — new Tier-1 package),
  0036 (BYOK consent pattern the token onboarding will mirror).
