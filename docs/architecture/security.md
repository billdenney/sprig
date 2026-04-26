# Security

Sprig's security posture, distilled from the relevant ADRs. **This is a living index, not the authoritative spec** — for any specific decision the linked ADR is canonical. Substantive expansion lands in M5/M6 when credentials and signing flows ship.

ADR cross-references: 0014 (telemetry), 0033 (destructive-op safety), 0036 (AI privacy), 0043 (auth/credentials), 0044 (commit signing), 0050 (hook trust), 0052 (force-with-lease aliasing).

Companion: [`../research/git-best-practices.md`](../research/git-best-practices.md) §11.3, §11.6, §11.11. See also `CLAUDE.md` "Hard rules."

## Threat model summary

Sprig is a local desktop tool. The threats we take seriously, in priority order:

1. **Code exfiltration via AI providers.** Cloud LLM calls send code somewhere; users need clarity, not surprise. Mitigations: ADR 0036 (local-first default; per-provider per-session confirmation; data-handling matrix surfaced in AI settings).
2. **Credential theft.** OAuth tokens, SSH keys, signing keys all live on the user's device; Sprig should make them more secure than the typical setup, not less. Mitigations: ADR 0043 (Keychain on macOS, Credential Manager + DPAPI on Windows, libsecret on Linux; honor existing `git-credential-manager`; OAuth device flow rather than password-in-Keychain).
3. **Malicious git hooks.** A repo's `.git/hooks/*` can run arbitrary code on `git commit` etc. Mitigations: ADR 0050 (trust prompt on first encounter for any hook not authored by Sprig; cache decision by hook hash; Sprig-managed hooks live as thin shims that exec scripts in `.sprig/hooks/` so they're checked-in and reviewable).
4. **Destructive history loss.** `reset --hard`, `push --force`, `filter-repo` can lose work. Mitigations: ADR 0033 (snapshot refs under `refs/sprig/snapshots/...` before every destructive op, 30-day default TTL, undo banner in Notification Center) and ADR 0052 (raw `--force` never emitted; always `--force-with-lease --force-if-includes`).
5. **Accidental secret commits.** A file with API keys / private keys gets staged. Mitigations: gitleaks-style pre-commit scan (M6), `.gitignore` warnings on names like `.env` / `*.pem` / `id_rsa`, recovery wizard for "remove file from history" that emphasizes revocation-first.
6. **Repo trust on a shared device.** `safe.directory` mismatches when a repo is owned by a different UID (ADR 0049's git defaults; user prompted to trust, never auto-`*`).
7. **Supply-chain on the Sprig binary itself.** Notarized + signed; reproducible builds aspirational; SBOM published with each release.

## What Sprig does *not* try to be

- A secret manager (we use Keychain / Credential Manager / libsecret; we don't roll our own).
- An audit logger (DiagKit logs are local-only and opt-in to share — ADR 0014).
- A sandboxer for the user's git operations (we trust the user's git binary; we don't try to constrain what it can do).
- A code reviewer (AI suggestions for merge / commit messages are not security review).

## Privacy invariants (ADR 0014, 0036)

- **No telemetry by default.** Crash reports are opt-in and shown to the user before send.
- **No third-party analytics SDK.** Ever.
- **AI calls are explicit.** First cloud-provider call per session shows a "this will send code to <provider>" confirmation. Local providers (Ollama, Apple Foundation Models) require no confirmation.
- **Diagnostic bundles are user-initiated.** When the user clicks "Generate diagnostic bundle," they review the contents before any upload (ADR 0014).

## Networking

- **Sprig itself makes network calls in three places:** Sparkle/WinSparkle update checks, AI provider APIs (when user enables a cloud provider), GitHub/GitLab API (when user signs in via OAuth for PR/MR features).
- **The shell extension never makes network calls.** Sandboxing on macOS enforces this; we audit the same on Windows.
- **The watcher and the agent never make network calls.** Git transport (fetch/push) is delegated to the user's git binary, which uses its own configured transport stack.

## Where to expand

- **M5 / M6** is when the credential and signing flows actually ship. Substantive expansion of this doc happens then; specifically, the per-platform credential-store-adapter implementations and the SSH-signing onboarding flow.
- **M7** is when AI features ship, at which point the data-handling matrix and per-provider privacy doc gets a deeper write-up here vs the brief reference in [`ai-integration.md`](ai-integration.md).
- **Pre-1.0**, a published threat model in `SECURITY.md` (already present at the repo root) gets cross-linked from this file.

## Open questions

- Hardware-key SSH (FIDO/U2F via `ssh-sk`) — first-class onboarding option or document-only? Decision pending until we see real-user demand.
- Per-repo signing-key overrides for users who maintain multiple identities (ADR 0041) — UX details TBD.
- Reproducible builds for the macOS/Windows binaries — aspirational; tracked as a post-1.0 stretch goal in the risk register.
