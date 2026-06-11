---
status: accepted
date: 2026-06-11
deciders: maintainer (standing "lean in further and proceed"), engineering
consulted: —
informed: —
---

# 0081. Forge sign-in — OAuth device flow, client ids injected

## Context and problem statement

ADR 0078 deferred token *acquisition* to "shell/onboarding work"; ADR 0080 built the
storage. The acquisition mechanism determines how much shell is actually required: an
authorization-code flow needs a localhost redirect listener or a custom URL scheme per
OS, while the device authorization grant (RFC 8628) needs only "show a code, poll an
endpoint" — which a CLI, a task window, or a Finder-launched dialog can all do with the
same portable engine.

## Decision

**`ForgeKit.ForgeDeviceFlow` implements RFC 8628 for GitHub and GitLab; client ids are
injected like tokens; the resulting access token goes straight into CredentialKit
(ADR 0080).**

- `begin(provider:clientID:baseURL:)` → `DeviceAuthorization` (user code, verification
  URI + the pre-filled `_complete` variant when offered, polling interval, expiry).
  `baseURL` is the forge's **web** base (GitHub Enterprise, self-managed GitLab) — not
  the API base the repo listing uses.
- `awaitToken(...)` polls the token endpoint honoring the protocol's timing contract,
  which is **pinned deterministically via an injected sleeper** (no wall clock in
  tests): sleep `interval` before every poll, `slow_down` → interval +5 s (§3.5), stop
  with the typed `.expired` once total sleep would exceed `expiresIn`. Mid-flow
  "errors" are classified by **body before status** — GitLab delivers
  `authorization_pending` as HTTP 400 (per RFC), GitHub as 200; both are normal flow.
- **Scopes:** GitHub `repo` (classic scopes have no finer private-read), GitLab
  `read_api` (listing; clone auth stays with the user's git credential setup).
- **Client ids are injected.** Registering OAuth apps is a distribution concern, and
  self-hosted forges need their own registration regardless. `sprigctl forge login
  --client-id <id>` for now; a Sprig-registered id ships with the macOS bundle later
  and simply becomes that surface's default.
- **Bitbucket Cloud has no device grant and Gitea's is too version-dependent to rely
  on** — both are the typed `unsupportedProvider`, worded as guidance to store a
  personal access token via `sprigctl credential --set` (same key, so every downstream
  consumer is provider-uniform).
- **Version floor (noted 2026-06-11):** GitLab's device grant requires **GitLab ≥ 17.2**
  (`/oauth/authorize_device` landed there). On an older self-managed instance, `begin`
  surfaces `httpStatus(404)`; callers should word that as the same PAT guidance the
  unsupported providers get. Improving that wording at the `forge login` face is a
  noted follow-up.

CLI face: **`sprigctl forge login|logout|status --provider <p>`** — login prints the
code + URL, polls, stores under service `forge.<provider>` / account `token` (the one
key convention shared with `sprigctl credential`); `status` exits 0/1 for scripting;
`logout` is idempotent. A `noUsableBackend` from storage is worded as
configure-a-credential-helper guidance, not a stack trace.

## Considered options

1. **Device authorization grant** (this ADR) — works headless and in-app alike, no
   listener, no URL-scheme registration; the trade-off (user types a short code) is
   acceptable for a once-per-forge action.
2. Authorization-code + localhost redirect — better UX (no code to type) but requires a
   loopback HTTP listener, a free-port dance, and per-OS browser hand-off; right for
   the polished macOS onboarding later, as an *addition* behind the same storage key,
   not as the portable baseline.
3. PAT-only (no OAuth at all) — already supported via `sprigctl credential --set` and
   remains the Bitbucket/Gitea answer, but as the *only* path it pushes scope and
   expiry management onto beginners.

## Consequences

- The 3.2 affordance is now end-to-end at the engine/CLI level: `forge login` →
  `ForgeRepoBrowser.listRepos` with the stored token → clone. The interactive
  `clone --browse` CLI face and the shells' onboarding UI are mechanical consumers.
- `login`'s happy path is engine-tested (deterministic fake + sleeper); the CLI pins
  validation, guidance wording, and the storage verbs against real git. No network in
  tests, ever.
- Device-flow support requires the OAuth app to have it enabled (GitHub: a checkbox on
  the app registration) — documented for whoever registers the distribution app.

## Links

- ADR 0078 (the deferred acquisition this implements), 0080 (storage), 0036 (the BYOK
  consent pattern the cloud-AI side uses; forge tokens follow the same injected-secret
  philosophy).
- `packages/ForgeKit/Sources/ForgeKit/ForgeDeviceFlow.swift`,
  `cli/sprigctl/Sources/ForgeCommand.swift`.
