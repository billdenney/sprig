---
status: accepted
date: 2026-06-11
deciders: maintainer (standing "lean in further and proceed"), engineering
consulted: —
informed: —
---

# 0080. Credential storage defers to git's helper chain

## Context and problem statement

ADR 0078 drew the boundary: forge tokens are injected into ForgeKit, acquired by
shell/onboarding, and *stored by CredentialKit*. The scaffolding plan (ADR 0053) sketched
native keystore adapters — Keychain, Windows Credential Manager, Secret Service — as
fatalError stubs. Building those now means: a macOS impl this repo cannot run, a Linux
impl that needs either a libsecret system dependency or a D-Bus protocol client plus a
running secrets daemon (absent on headless CI), and three codepaths where one would do.
Meanwhile the project's own foundation (ADR 0023, "defer to git") already names
credentials as something that "just works" when you ride the user's git.

## Decision

**`CredentialKit.CredentialStore` (portable protocol) with `GitCredentialChainStore` as
the default implementation everywhere: secrets ride the user's `git credential` helper
chain** (`fill` / `approve` / `reject` over the line-based stdin wire). The user's
existing keystore does the platform work — osxkeychain on macOS, Git Credential Manager
on Windows (both ship with git), libsecret/cache/store on Linux — and the user can
inspect or clear Sprig's entries with git tooling they already know.

Three invariants, all test-pinned with real git and the real `git-credential-store`
helper:

1. **Isolation.** Entries live under the synthetic host `<service>.sprig.invalid` —
   `.invalid` is RFC 2606-reserved, never a real host — so helpers (which match on host)
   can neither return the user's real `github.com` credential to Sprig nor let Sprig
   clobber it.
2. **Fail loudly.** `git credential approve` exits 0 even with *no helper configured*
   (the write silently goes nowhere), so `store()` verifies with a read-back and throws
   `noUsableBackend` instead of letting onboarding believe a token was kept. One extra
   spawn, bought honesty.
3. **No wire injection.** The format is newline-delimited `key=value`; newlines/NULs in
   any field are rejected before anything spawns, and `service` doubles as a hostname
   label so it is restricted to `[a-z0-9.-]`.

Prompting is disabled in depth (the Runner's `GIT_TERMINAL_PROMPT=0` plus stripped
`GIT_ASKPASS`/`SSH_ASKPASS`), so a fill with nothing stored returns nil rather than
blocking on a prompt. The CLI face is **`sprigctl credential --set|--get|--remove
--service <s> --account <a>`**; `--set` reads the secret from stdin, never argv (argv is
world-readable via `ps`).

## Considered options

1. **Defer to the git credential helper chain** (this ADR).
2. Native keystore adapters per platform — **deferred, not rejected**: they remain the
   upgrade path *behind the same protocol* if helper-chain coverage proves insufficient.
   The known gap: a fresh Linux box with no helper configured (macOS and Windows git
   ship with one). `noUsableBackend` makes that gap visible, and onboarding can guide
   helper setup; if that guidance proves too weak, a Secret Service adapter is the fix.
3. Sprig-owned encrypted token file — rejected: no OS key source means the key sits
   beside the ciphertext (obfuscation, not encryption); ADR 0078 already rejected
   plain files.
4. libsecret / `secret-tool` dependency for Linux — rejected for v1: a new system
   dependency that headless CI can't exercise, for one platform, when option 1 covers it
   wherever the user's git already does.

## Consequences

- Sprig's token storage is exactly as strong as the user's git credential setup — by
  design: one credential story per machine, not two.
- Entries are visible in the user's credential store under `*.sprig.invalid` hosts —
  transparency over hiding; documented here for anyone auditing their keystore.
- ForgeKit's `sprigctl clone --browse` face (noted in ADR 0078) is now unblocked: the
  token source is `sprigctl credential` / `GitCredentialChainStore`.
- The onboarding flow (M3 shell work) owns the `noUsableBackend` UX: per-OS guidance for
  configuring a helper.

## Links

- ADR 0023 (defer to git — this extends it to secret storage), 0078 (the token
  boundary this fills), 0053 (the stub scaffolding this supersedes for v1).
- `packages/CredentialKit/Sources/CredentialKit/GitCredentialChainStore.swift`,
  `cli/sprigctl/Sources/CredentialCommand.swift`.
