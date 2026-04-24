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
