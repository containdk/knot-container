# knot-container

A [Knot DNS][knot] image for the Contain Platform, built from the
upstream release tarball on [Wolfi][wolfi].

Consumed by [component-knot-authoritative][component], which runs the
authoritative DNS tier described in [SCR 26][scr26].

## Why this exists

The official `cznic/knot` image is Debian trixie-slim with the Knot binaries
copied in. It carries a distribution's worth of packages that `knotd` never
calls, and the vulnerability scan reflects that:

| | `docker.io/cznic/knot:v3.6.0` | this image |
| --- | --- | --- |
| Knot DNS | 3.6.0 | 3.6.0 |
| libc | glibc | glibc |
| Size | 159 MB | 54 MB |
| Packages | 107 | 33 |
| Vulnerabilities | 213, six critical | 0 |

Of the upstream image's 213 findings, only 20 had a fixed version available, so
most could not be resolved by updating anything.

Read the last row for what it is. Knot is compiled from a tarball, so it carries
no package metadata and the scanner does not look at it — the comparison is
Debian's packages including Knot against Wolfi's packages excluding it. A Knot
DNS advisory would show up in the upstream image and not here. What covers that
is bumping `KNOT_VERSION`, not the scan.

Alpine packages Knot and would be smaller still, but its stable branch carries
3.4.9 and its edge branch 3.6.0's predecessor. Building from the release tarball
keeps us on the latest stable release and on glibc.

## What is built in

Compiled with QUIC, so DNS over TLS and over QUIC can be turned on in
configuration without rebuilding. `mod-rrl`, `mod-stats` and `mod-cookies` are
available.

Left out deliberately, because the platform does not use them and each one drags
libraries into the runtime image: dnstap, redis, XDP, GeoIP, systemd and D-Bus.
XDP would also need privileged networking.

The runtime packages are only the ones something links. QUIC is compiled into
`libknot` statically, so no `ngtcp2` package is installed; `libnghttp2-14` is
there for `kdig +https`, rather than the `nghttp2` tools package that would also
bring an HTTP/2 server and a reverse proxy. OpenSSL is still present because
`apk-tools` in the base image links it — nothing in Knot does.

## The exporter

`knot-exporter` is built into the same image and lives at `/bin/knot-exporter`.
It reads the `knotd` control socket, so it runs as a sidecar sharing the pod's
`rundir`. Two flags and the user it runs as all have to be set, or it does not
work at all:

```
/bin/knot-exporter -knot-socket-path /rundir/knot.sock -web-listen-addr 0.0.0.0
```

It looks for the socket at `/run/knot/knot.sock`, and a missing socket is fatal
rather than something it waits out. It binds `127.0.0.1`, so on the default
nothing can scrape it. And the socket is mode 0220 owned by `knot:knot`, so the
sidecar has to run as uid and gid 53 like the server — anything else gets
`EACCES` and exits. It serves `/metrics` and `/health` on port 9433; `/health`
answers 503 when the control socket is unreachable, which makes it usable as a
probe.

Without `mod-stats` it still reports zone serials, zone size and maximum TTL,
and the server's zone count. `mod-stats` is what adds the query and response
counters. `knot_memory_usage_bytes` is read from `/proc` rather than the control
socket, so it only appears when the exporter shares a PID namespace with
`knotd`; in a normal sidecar it is absent, and `process_resident_memory_bytes`
describes the exporter, not the server.

It shares the image rather than having one of its own, because it is CGO code
against `libknot` and upstream does not promise that a mismatched exporter and
daemon work together. Compiling it here, against the `libknot` built in the same
stage, makes the pair match by construction — a real API break fails the build
instead of misbehaving at runtime. A separate image would have to carry
`libknot` and its whole dependency chain anyway, so it would save little and
reintroduce exactly the skew this avoids.

Upstream releases the exporter in step with Knot and does not guarantee
cross-version compatibility. That warning is about the prebuilt binaries, and
compiling from source settles the ABI half of it. The other half it does not
settle: the exporter reads the zone timers positionally out of `knotc`
zone-status output, so a column-order change upstream drops those metrics
silently. It also decodes Knot's `KNOT_VERSION_PATCH`, which is the literal
`0x0<patch>`, only above 99 — from Knot 3.6.10 on it will report a patch level
the server does not have. The image test reproduces that arithmetic rather than
comparing the strings, so it stays meaningful without going red on a bump.

## Layout

The image keeps upstream's paths and user so that it is a drop-in replacement:

| | |
| --- | --- |
| Binaries | `/sbin/knotd`, `/sbin/knotc`, `/bin/knot-exporter`, `/usr/bin/kdig`, `/usr/bin/knsupdate`, `keymgr`, `kjournalprint` |
| Configuration | `/config` |
| Runtime state | `/rundir` |
| Zone storage | `/storage` |
| User | `knot`, uid and gid 53 |

It runs as uid 53 and needs a writable `/tmp`: `knotd` builds its configuration
database under a temporary directory, which fails on a read-only root filesystem
without one.

## Supply chain

The build downloads the release tarball and its detached signature from
`secure.nic.cz` and verifies the signature against a pinned fingerprint —
`742FA4E95829B6C5EAC6B85710BB7AF6FEBBD6AB`, Daniel Salzman, who signs the Knot
DNS releases. The build asserts on gpg's status output rather than its exit
code: a keyserver can answer with more keys than the one asked for, and
`--verify` accepts a signature from any key in the keyring it was handed. What
the build requires is `VALIDSIG` naming the pinned key and `GOODSIG` rather than
`EXPKEYSIG` or `REVKEYSIG`, so a signature by anyone else, or by that key after
it expires or is revoked, fails the build.

Pinning the key rather than a tarball checksum means a version bump is a
one-line change and the tarball is still verified.

Released images are multi-arch, signed with cosign keyless OIDC, and carry an
SBOM and provenance attestation.

The signature is an OCI 1.1 referrer rather than a `.sig` tag, which is what
cosign v3 writes. A v2 client looks only for the tag and reports "no signatures
found" against an image that is properly signed, so verify with v3 or newer.

## Building and testing

```bash
docker build -t knot-container:test .
./hack/test-image.sh knot-container:test
```

The test script runs a hidden primary and a secondary against each other and
checks what the platform relies on: the apex seeds through `knotc`, the
secondary transfers the zone, an RFC 2136 update propagates over NOTIFY and
IXFR, the transfer key cannot write to the zone, unsigned transfers are refused,
and queries outside the zone are refused. It then starts the exporter against
the primary's control socket and checks that the serial it exports is the one
`knotc zone-status` reports, and that the `mod-stats` counters appear once a
query has been answered.

## Releasing

Push a `v*` tag. CI builds amd64 natively, runs the image tests and the
vulnerability scan against it, and only then builds for amd64 and arm64, pushes
to `ghcr.io/containdk/knot-container`, signs the digest and publishes a release.
The arm64 build is emulated and takes considerably longer than the native one.
Only amd64 is tested; nothing runs the suite against the arm64 image.

Tags are `<knot version>-<packaging revision>`, and the revision is always
present — `v3.6.1-1`, not `v3.6.1`. Renovate reads the suffix as a compatibility
tag and only offers versions carrying the same one, so a release without it
drops out of the consumers' update path.

## Licensing

The packaging in this repository is MIT licensed. Knot DNS itself is
GPL-2.0-or-later and is not modified here.

[knot]: https://www.knot-dns.cz/
[wolfi]: https://github.com/wolfi-dev
[component]: https://github.com/containdk/component-knot-authoritative
[scr26]: https://github.com/neticdk/scrolls/tree/main/scr/0026
