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
| Size | 159 MB | 58 MB |
| Packages | 107 | 37 |
| Vulnerabilities | 213, six critical | 0 |

Of the upstream image's 213 findings, only 20 had a fixed version available, so
most could not be resolved by updating anything.

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

## The exporter

`knot-exporter` is built into the same image and lives at `/bin/knot-exporter`.
It reads the `knotd` control socket, so it runs as a sidecar sharing the pod's
`rundir`, and it needs Knot's `mod-stats` module enabled to report anything
beyond zone serials and memory. It listens on 9433 and serves `/metrics` and
`/health`.

It shares the image rather than having one of its own, because it is CGO code
against `libknot` and upstream does not promise that a mismatched exporter and
daemon work together. Compiling it here, against the `libknot` built two stages
earlier, makes the pair match by construction — a real API break fails the build
instead of misbehaving at runtime. A separate image would have to carry
`libknot` and its whole dependency chain anyway, so it would save little and
reintroduce exactly the skew this avoids.

Upstream releases the exporter in step with Knot and does not guarantee
cross-version compatibility. That warning is about the prebuilt binaries; it
does not apply to a build from source against a known library. The image test
asserts the exporter reports the same `libknot` version the server was built
from, so a mismatch fails rather than ships.

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
DNS releases. The keyring holds that one key, so a tarball signed by anyone else
does not verify.

Pinning the key rather than a tarball checksum means a version bump is a
one-line change and the tarball is still verified.

Released images are multi-arch, signed with cosign keyless OIDC, and carry an
SBOM and provenance attestation.

## Building and testing

```bash
docker build -t knot-container:test .
./hack/test-image.sh knot-container:test
```

The test script runs a hidden primary and a secondary against each other and
checks what the platform relies on: the apex seeds through `knotc`, the
secondary transfers the zone, an RFC 2136 update propagates over NOTIFY and
IXFR, the transfer key cannot write to the zone, unsigned transfers are refused,
and queries outside the zone are refused.

## Releasing

Push a `v*` tag. CI builds for amd64 and arm64, pushes to
`ghcr.io/containdk/knot-container`, signs the digest and drafts a release. The
arm64 build is emulated and takes considerably longer than the native one.

## Licensing

The packaging in this repository is MIT licensed. Knot DNS itself is
GPL-2.0-or-later and is not modified here.

[knot]: https://www.knot-dns.cz/
[wolfi]: https://github.com/wolfi-dev
[component]: https://github.com/containdk/component-knot-authoritative
[scr26]: https://github.com/neticdk/scrolls/tree/main/scr/0026
