# IPCSchema — wire-format stability policy

`IPCSchema` defines the on-the-wire JSON envelope that `SprigAgent` exchanges with every consumer: the macOS `FinderSync` extension, the Windows shell extension, `sprigctl`, and the task-window app. Once this format is frozen, a Sprig 1.0 agent must be able to talk to a Sprig 1.0 shell extension regardless of independent point releases on either side. This document is the contract.

## Versioning

`IPCSchema.currentSchemaVersion` and `IPCSchema.minimumSupportedSchemaVersion` define the receiver's accepted range. Today:

| | Value |
|---|---|
| `currentSchemaVersion` | `1` |
| `minimumSupportedSchemaVersion` | `1` |

The `Envelope` decoder rejects any envelope with `schemaVersion` outside `[minimumSupportedSchemaVersion, currentSchemaVersion]` with `IPCError.unsupportedSchemaVersion`. This is hard-enforced; a future receiver cannot silently downgrade to an older parser if the publisher claims a newer version.

## What's wire-stable

Anything in this list is **guaranteed not to change** within a major schema version. Changing one is a v2 wire-format event — bump `currentSchemaVersion`, raise `minimumSupportedSchemaVersion` (or keep the v1 decoder alongside, time-bounded), and ratify via an ADR amendment.

- The envelope's outer key set: `schemaVersion`, `id`, `kind`, `payload`, `deadline`.
- The discriminator value for every `EnvelopeMessage` variant (e.g. `"badgeQuery"`, `"badgeReply"`, `"badgeChanged"`). These appear in the on-disk wire bytes and in log greps; renaming one is a wire-break.
- The payload field names for every `*Payload` struct (e.g. `path`, `roots`, `badge`, `subscriptionId`, `code`, `message`, `reason`).
- Sorted-key JSON encoding (`JSONEncoder.outputFormatting = [.sortedKeys]`). Field order is deterministic and part of the encoded bytes for golden-test purposes.
- ISO-8601 `deadline` encoding (when present).
- Forward-slash escaping in path strings (`\/`) — Foundation's `JSONEncoder` default; stable across platforms.
- The `IPCError` cases: `unsupportedSchemaVersion`, `unknownMessageKind`, `parseFailure`. Removing one or renaming an associated-value label is a source-break for callers pattern-matching the enum.

## What's wire-extensible (not a version bump)

These changes are backward-compatible with older receivers. They do **not** bump the schema version:

- **Adding a new `EnvelopeMessage` enum case** (a new `kind`). Older receivers raise `IPCError.unknownMessageKind` and continue; newer senders gracefully avoid the new case until they detect a newer receiver. New `kind` strings must not collide with existing ones in the same direction's enum.
- **Adding a new optional field to an existing payload struct.** Older receivers ignore the new field. The field MUST be `Codable` with a sensible decode-as-nil default; otherwise a v1 receiver decoding a v2-with-required-new-field payload fails the decode, which is a wire-break.
- **Adding a new value to a wire-stable string enum** (`reason` codes in `SubscriptionEndedPayload`, `code` strings in `ErrorPayload`). Pattern-matching callers should treat unknown values as `unknown_*` / pass-through, not as failure.

## What's not on the wire

These can change freely without any wire-format implication:

- The Swift struct's `internal` / `private` members.
- The `ErrorPayload.message` human-readable string (the `code` is wire-stable; the message text is not).
- Doc-comment wording, error descriptions, log lines.
- Test fixture data inside `Tests/IPCSchemaTests/` that isn't the golden-tests file.

## Enforcement

`WireFormatGoldenTests.swift` is the load-bearing test file. Every `EnvelopeMessage` variant has both an **encode-golden** (typed value → exact bytes) and a **decode-golden** (exact bytes → typed value) test. The two-directional coverage is deliberate: round-trip-only tests pass even if encoder and decoder co-evolve a breaking change in lockstep, which is exactly the failure mode that breaks cross-version interop.

**Adding a new `EnvelopeMessage` variant** — the same PR that adds the case MUST add both an encode-golden and a decode-golden test in `WireFormatGoldenTests.swift`. Lint and CI won't catch the omission, but milestone-exit review will. The PR also updates the "what's wire-stable" / "wire-extensible" lists above.

**Changing an existing golden assertion's expected string** — you're changing wire format. Either:

1. The change is intentional and a wire break → bump `currentSchemaVersion`, raise `minimumSupportedSchemaVersion` or arrange dual-version support, and amend ADR 0048.
2. The change is unintended → fix the producing code, don't update the golden.

## Roadmap

- v1: today. Six message variants across three enums (`ClientRequest`, `AgentResponse`, `AgentEvent`).
- v2 candidates (not committed): batched envelopes, streaming payloads for large diffs, signed envelopes for cross-process trust (per ADR 0048 §security). These would each bump the schema version. None are scheduled before M9 (1.0).

## Cross-references

- ADR 0048 — cross-platform extensibility rules (Tier 1, schema-agnostic transports).
- `docs/architecture/agent-host.md` — single-client and multi-client agent host wiring.
- `packages/IPCSchema/Sources/IPCSchema/IPCSchema.swift` — version constants.
- `packages/IPCSchema/Tests/IPCSchemaTests/WireFormatGoldenTests.swift` — enforcement.
