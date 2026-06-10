---
status: accepted
date: 2026-06-11
deciders: engineering (per the M2 substrate track ratified 2026-06-10)
consulted: —
informed: —
---

# 0076. Linux IPC — Unix domain sockets, not D-Bus

## Context and problem statement

`TransportKit` needs a Linux implementation of the byte-oriented `Transport` protocol so the
agent ↔ client connection (badge events, verb invocations) works on the third platform. The
Windows adapter shipped as named pipes (ADR 0067); macOS will be XPC. The original sketch
("D-Bus or UNIX socket") deferred the choice.

## Decision

**Unix domain sockets** (`AF_UNIX`/`SOCK_STREAM`), with the **same wire framing as the
named-pipe transport byte-for-byte**: 4-byte little-endian length prefix + payload, 16 MB
frame cap. ADR 0048's covenant — the `IPCSchema` envelope bytes survive any transport swap —
is upheld by construction.

Implementation shape (`UnixSocketTransport` + `UnixSocketServer` in
`TransportKit/Sources/Linux/`):

- **Compiled on Linux AND macOS** (`#if os(Linux) || os(macOS)` + a `canImport(Glibc)`
  split). Hosted macOS CI exercises the suite too, and the Mac gets a non-sandboxed fallback
  transport for free; the FinderSync extension itself still gets XPC (sandbox requirement).
- **Blocking POSIX I/O off the cooperative pool**: one detached reader thread per connection
  feeds `messages()`; sends hop to a per-connection serial `DispatchQueue` (serialization
  doubles as frame-interleaving protection).
- **SIGPIPE suppressed** — `MSG_NOSIGNAL` per send on Linux, `SO_NOSIGPIPE` at socket
  creation on Darwin. A dead peer surfaces as `TransportError.peerClosed`, never a
  process-killing signal.
- **fd lifecycle without races**: `close()` only `shutdown(2)`s (which wakes a blocked
  `read`/`accept` on both platforms); the reader/accept thread is the single owner that
  `close(2)`s the descriptor on loop exit — the fd can never be closed mid-syscall.
- **Stale-socket policy**: the server unlinks a leftover path before `bind` — but only when
  the existing file is a socket (`S_IFSOCK`); a regular file at the path is somebody's data
  and init refuses. `sun_path` length is validated (≤100 bytes, under both platforms'
  limits).

## Considered options

1. **Unix domain sockets** (this ADR).
2. **D-Bus** — the desktop-Linux native bus. Costs: a bus-daemon dependency (or
   `libdbus`/`sd-bus` bindings — C interop we'd own), a message model that fights the
   byte-oriented `Transport` protocol (typed signatures vs opaque envelopes), and an
   activation model Sprig doesn't need (the agent is a systemd user unit, not bus-activated).
   D-Bus remains the right tool *later* for desktop integration points (notifications,
   portals) — as a consumer, not as the agent transport.
3. **TCP on localhost** — works everywhere but adds a port-allocation story, firewall-prompt
   risk, and a network attack surface where filesystem permissions already solve peer
   trust. UDS file modes (0700 socket directory) are the natural ACL.
4. **Reuse the named-pipe code via Wine-style abstraction** — there is no portable named-pipe
   on Linux; FIFOs are unidirectional and connectionless. Not real.

## Consequences

- The Linux production host (systemd user unit running AgentKit) has its transport; the
  TransportKit stub count drops to one (Mac XPC).
- Peer authentication rides filesystem permissions for now; `SO_PEERCRED` validation (the
  named-pipe transport's peer-SID analogue) is a follow-up noted for the Linux host slice.
- The macOS CI matrix now compiles + tests this code, catching Darwin/Glibc drift on every
  PR.

## Links

- ADR 0048 (transport-swap covenant), 0067 (named-pipe sibling — framing source of truth),
  0034/0030 (agent architecture).
- `docs/architecture/cross-platform.md` — Linux port status.
