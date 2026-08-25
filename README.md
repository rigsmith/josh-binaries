# josh-binaries

Unofficial, **behaviorally tested** binaries of [josh](https://github.com/josh-project/josh)
(`josh-proxy` and, where it compiles, `josh-cli`), built automatically from
upstream tags. Upstream distributes source and Linux Docker images only; this
repo exists so tools that shell out to josh — [rig](https://github.com/rigsmith/rigsmith)'s
`stack` verb in particular — can download a pinned, checksummed, provenance-attested
engine on any platform in seconds instead of requiring a Rust toolchain.

Every release is gated on a functional round-trip suite run on each platform:
proxy boot/teardown, filtered clone (`:prefix`), pinned-SHA fetch (`@sha`),
reverse-filter push (the history round-trip everything depends on), warm-cache
reuse, and — on Windows — the path-form regression cases for
[josh#2288](https://github.com/josh-project/josh/issues/2288). "Compiled" is
not the bar; "round-trips history correctly on this OS" is.

## Platforms

| target | josh-proxy | josh-cli |
|---|---|---|
| linux-x64 | built + tested | built |
| linux-arm64 | built + tested | built |
| macos-arm64 | built + tested | built |
| windows-x64 | experimental — the frontier | blocked upstream ([josh#2235](https://github.com/josh-project/josh/issues/2235)) |

Upstream has [no Windows infrastructure at all](https://github.com/josh-project/josh/issues/2235#issuecomment)
(maintainer, July 2026), so the Windows column here is the only tested signal
that exists anywhere. Windows legs run `continue-on-error`: a red leg never
blocks a release, and the josh-cli step doubles as a canary that flips green
the day josh#2235 is fixed. Patched builds can be produced from the
[rigsmith/josh](https://github.com/rigsmith/josh) fork via the build workflow's
`source` input.

## How releases happen

1. `watch.yml` (daily cron) diffs upstream `r*` tags against this repo's
   releases and dispatches a build for anything new.
2. `build.yml` builds each matrix leg with `cargo install --locked` from the
   exact tag, runs the round-trip suite against the built binary, and uploads
   artifacts.
3. The release job publishes a GitHub Release named after the upstream tag:
   `josh-proxy-<tag>-<target>[.exe]`, a `SHA256SUMS` file, and GitHub
   build-provenance attestations (`gh attestation verify <file> --repo rigsmith/josh-binaries`).

Releases mirror upstream tag names (e.g. `r26.07.19`). Consumers should pin an
exact tag **and** its sha256 on their own side — rig does — rather than
trusting "latest".

## Consuming from rig

`rig stack doctor --fix` downloads
`https://github.com/rigsmith/josh-binaries/releases/download/<tag>/josh-proxy-<tag>-<target>`
for the host platform, verifies the checksum pinned in rig, and falls back to
a local `cargo install` only when no artifact exists for the platform.

## Relationship to upstream

Binaries are built from **unmodified upstream source** at the stated tag (the
release notes record the upstream commit SHA); upstream's license applies to
them. The intent is to upstream this workflow — a project whose maintainers
want platform coverage but lack the infrastructure gets a working, tested
release pipeline to adopt; this repo keeps running as the proving ground and
fallback either way. Patched builds, if ever published, will be clearly marked
with their `rigsmith/josh` source tag.
