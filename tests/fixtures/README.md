# Test fixtures

Hash-pinned repo snapshots used by integration, E2E, and benchmark suites.

Format: `tests/fixtures/repos/<name>.tar.zst` stored via Git LFS with a corresponding SHA-256 checksum in `checksums.txt`. The test helper extracts on demand to `tests/fixtures/repos/<name>.extracted/` (gitignored).

## Adding a fixture

1. Create the repo state, tar it with `zstd -19`.
2. Compute the SHA-256 and add to `checksums.txt`.
3. Add the tarball via `git lfs track` then `git add`.
4. Document the fixture's purpose and shape in a per-fixture `.md` next to the tarball.
