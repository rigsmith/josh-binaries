# josh-binaries

Unofficial, **behaviorally tested** binaries of [josh](https://github.com/josh-project/josh)
(`josh-proxy` and, where it compiles, `josh-cli`), built automatically from
upstream tags. Upstream distributes source and Linux Docker images only; this
repo exists so tools that shell out to josh — [rig](https://github.com/rigsmith/rigsmith)'s
`stack` verb in particular — can download a pinned, checksummed, provenance-attested
engine on any platform in seconds instead of requiring a Rust toolchain.

Every release is gated on functional suites run on each platform. The proxy
suite (`test/roundtrip.sh`) covers boot/teardown, filtered clone (`:prefix`),
pinned-SHA fetch (`@sha`), reverse-filter push (the history round-trip
everything depends on), and warm-cache reuse across a proxy restart. The CLI
suite (`test/cli.sh`) covers `josh-filter`, `josh clone` (into a relative
directory — the [josh#2288](https://github.com/josh-project/josh/issues/2288)
trigger shape), `josh pull`, and `josh push --base` with an exact-parent
assertion. On Windows the proxy suite additionally reruns against relative,
space-laden and subst-drive cache paths. "Compiled" is
not the bar; "round-trips history correctly on this OS" is.

## Platforms

| target | josh-proxy | josh-cli |
|---|---|---|
| linux-x64 | built + tested | built + tested |
| linux-arm64 | built + tested | built + tested |
| macos-arm64 | built + tested | built + tested |
| macos-x64 | built + tested | built + tested |
| windows-x64 | built + tested (patched builds) | built + tested (patched builds) |

**Windows works — from the patched builds only.** Upstream josh does not compile
on Windows at `r26.07.19` ([josh#2235](https://github.com/josh-project/josh/issues/2235);
the maintainers note they have no infrastructure to test the platform), so
releases built from unmodified upstream carry no Windows assets. Releases
tagged `<tag>-win.N` are built from the
[rigsmith/josh](https://github.com/rigsmith/josh) fork's Windows port branch,
and their Windows binaries pass both suites plus the path-forms regression for
[josh#2288](https://github.com/josh-project/josh/issues/2288) — which the port
also fixes. The port is validated on x86-64 in CI and on ARM64 by hand; the
intent is to upstream it, after which plain tags build everywhere and the
`-win.N` line retires.

Windows legs run `continue-on-error` on their individual steps (job-level would
render a failed leg as a green check —
[actions/runner#2347](https://github.com/actions/runner/issues/2347)): a red leg
never blocks a release, and the job summary states the real per-step verdict.

## How releases happen

1. `watch.yml` (daily cron) diffs upstream `r*` tags against this repo's
   releases and dispatches a build for anything new.
2. `build.yml` builds each matrix leg with `cargo install --locked` from the
   exact tag, runs the round-trip suite against the built binary, and uploads
   artifacts.
3. A `validate` job re-downloads each artifact as a consumer would and reruns
   the suite against the shipped file (exec bit restored) on its own platform.
4. The release job publishes a GitHub Release named after the upstream tag:
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
