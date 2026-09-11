# syntax=docker/dockerfile:1

# renovate: datasource=gitlab-tags depName=knot/knot-dns registryUrl=https://gitlab.nic.cz
ARG KNOT_VERSION="3.6.0"

# extractVersion strips the tag's v prefix, which this ARG does not carry -- the
# URL built from it would 404 otherwise. Bumping it requires updating the commit
# below in the same change; the build asserts the two agree.
# renovate: datasource=github-releases depName=CZ-NIC/knot-exporter extractVersion=^v(?<version>.*)$
ARG KNOT_EXPORTER_VERSION="3.5.3"
# The commit that tag points at. Git object hashes are stable; the bytes of
# GitHub's generated tag archives are not, so the commit is what can be checked.
ARG KNOT_EXPORTER_COMMIT="e9b4344da7f53bb38cc34928705e920b93922ca3"
# renovate: datasource=go depName=golang.org/x/sys
ARG XSYS_VERSION="v0.48.0"

# Daniel Salzman <daniel.salzman@nic.cz>, who signs the Knot DNS releases.
# Pinning the key rather than a tarball checksum means a version bump needs no
# second edit, and the tarball is still verified.
ARG KNOT_RELEASE_FINGERPRINT="742FA4E95829B6C5EAC6B85710BB7AF6FEBBD6AB"

FROM cgr.dev/chainguard/wolfi-base AS builder
ARG KNOT_VERSION
ARG KNOT_RELEASE_FINGERPRINT

RUN apk add --no-cache \
        build-base \
        curl \
        gpg \
        gnutls-dev \
        jansson-dev \
        libcap-ng-dev \
        libedit-dev \
        libidn2-dev \
        lmdb-dev \
        nghttp2-dev \
        ngtcp2-dev \
        pkgconf \
        userspace-rcu-dev \
        xz \
        zlib-dev

WORKDIR /build
RUN curl -fsSLO "https://secure.nic.cz/files/knot-dns/knot-${KNOT_VERSION}.tar.xz" && \
    curl -fsSLO "https://secure.nic.cz/files/knot-dns/knot-${KNOT_VERSION}.tar.xz.asc" && \
    export GNUPGHOME=/tmp/gnupg && mkdir -p -m 700 "${GNUPGHOME}" && \
    # Wolfi's gpg enables keyboxd, which makes it ignore --keyring. An empty
    # common.conf in our own home directory turns that back off.
    : > "${GNUPGHOME}/common.conf" && \
    curl -fsSL -o /tmp/knot-release.asc \
        "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${KNOT_RELEASE_FINGERPRINT}" && \
    gpg --dearmor < /tmp/knot-release.asc > /tmp/knot-release.gpg && \
    # Assert on gpg's machine-readable status rather than its exit code. A
    # keyring built from a keyserver response can hold more keys than the one
    # asked for, and --verify is happy with a signature from any of them, so
    # checking that the pinned fingerprint is present says nothing about which
    # key actually signed. VALIDSIG names that key -- the signing subkey first
    # and its primary last, so the pinned primary matches either way -- and
    # GOODSIG rather than EXPKEYSIG or REVKEYSIG is what rejects a key that has
    # since expired or been revoked.
    gpg --no-default-keyring --keyring /tmp/knot-release.gpg --batch --status-fd 1 --verify \
        "knot-${KNOT_VERSION}.tar.xz.asc" "knot-${KNOT_VERSION}.tar.xz" > /tmp/knot-verify.status && \
    grep -q "^\[GNUPG:\] GOODSIG " /tmp/knot-verify.status && \
    grep -q "^\[GNUPG:\] VALIDSIG .*${KNOT_RELEASE_FINGERPRINT}" /tmp/knot-verify.status && \
    tar -xf "knot-${KNOT_VERSION}.tar.xz"

WORKDIR /build/knot-${KNOT_VERSION}
RUN CFLAGS="-g -O2 -DNDEBUG -D_FORTIFY_SOURCE=3 -fstack-protector-strong" \
    ./configure \
        --prefix=/ \
        --with-rundir=/rundir \
        --with-storage=/storage \
        --with-configdir=/config \
        --enable-quic=yes \
        --enable-xdp=no \
        --enable-redis=no \
        --enable-dnstap=no \
        --enable-maxminddb=no \
        --enable-systemd=no \
        --enable-dbus=no \
        --with-module-dnstap=no \
        --with-module-geoip=no \
        --disable-static \
        --disable-documentation && \
    make -j"$(nproc)" && \
    make install-strip DESTDIR=/tmp/knot-install && \
    find /tmp/knot-install -name '*.a' -o -name '*.la' | xargs -r rm -f

# The exporter is CGO code against libknot, and upstream does not promise that a
# mismatched exporter and daemon work together, so it is built here against the
# libknot produced by the stage above.
#
# Built FROM builder rather than a fresh base: the two need all but one of the
# same packages, and keeping the install tree where it was put means the include
# and library paths are stated outright. Copying it into /usr instead made the
# build succeed on the compiler's default search paths while libknot.pc pointed
# at /include, which does not exist — working by coincidence, and one transitive
# libknot from the distro away from linking the wrong library.
FROM builder AS exporter
ARG KNOT_EXPORTER_VERSION
ARG KNOT_EXPORTER_COMMIT
ARG XSYS_VERSION

RUN apk add --no-cache git go
# The Go build below mounts its module and build caches rather than baking them
# into a layer: they run to a few hundred megabytes, and release.yml exports
# this stage to the shared Actions cache.

# A directory of its own: /build already holds the Knot source in this stage.
WORKDIR /build/exporter
# Cloned rather than fetched as a tarball so the content can be verified: the
# commit hash covers the tree, and git checks it. The Knot half of this image is
# verified against a signature; this half should not be the exception.
RUN git clone --quiet https://github.com/CZ-NIC/knot-exporter.git . && \
    git checkout --quiet "${KNOT_EXPORTER_COMMIT}" && \
    test "$(git rev-parse HEAD)" = "${KNOT_EXPORTER_COMMIT}" && \
    test "$(git rev-parse "v${KNOT_EXPORTER_VERSION}^{commit}")" = "${KNOT_EXPORTER_COMMIT}"

# Upstream's go.mod carries an x/sys with a Windows-only advisory, unreachable in
# a Linux binary but noisy at every scan. Pinned to an exact version rather than
# @latest: a floating fetch inside a cached layer is unpinned on a cache miss and
# frozen on a hit, which is the worst of both and breaks reproducibility of an
# artifact this repository signs.
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/root/go/pkg/mod \
    go get "golang.org/x/sys@${XSYS_VERSION}" && \
    PKG_CONFIG_PATH=/tmp/knot-install/lib/pkgconfig \
    PKG_CONFIG_SYSROOT_DIR=/tmp/knot-install \
    CGO_CFLAGS="-I/tmp/knot-install/include -O2 -D_FORTIFY_SOURCE=3 -fstack-protector-strong" \
    CGO_LDFLAGS="-L/tmp/knot-install/lib -Wl,-z,relro,-z,now" \
    CGO_ENABLED=1 go build -trimpath -buildmode=pie \
        -ldflags "-s -w -X main.version=${KNOT_EXPORTER_VERSION}" \
        -o /knot-exporter ./cmd/knot-exporter

FROM cgr.dev/chainguard/wolfi-base
ARG UID=53

RUN apk add --no-cache \
        gnutls \
        jansson \
        libcap-ng \
        libedit \
        libidn2 \
        lmdb \
        # kdig, khost and knsupdate need libnghttp2 for DNS over HTTPS. The
        # nghttp2 package is the tools build: it adds an HTTP/2 server and a
        # reverse proxy, and c-ares and libev under them. ngtcp2 is not needed
        # at all -- Knot links its QUIC support statically, so nothing in the
        # image has a DT_NEEDED on libngtcp2, and the package's only effect is
        # to pull OpenSSL into an image built entirely against GnuTLS.
        libnghttp2-14 \
        userspace-rcu \
        zlib && \
    # Wolfi's nettle declares a runtime dependency on gmp-dev, which drags a
    # static library into a runtime image that has no use for one.
    find /usr/lib -name '*.a' -delete && \
    addgroup -g ${UID} -S knot && \
    adduser -u ${UID} -G knot -S -H -h /storage knot && \
    install -o knot -g knot -d /config /rundir /storage

COPY --from=builder /tmp/knot-install/bin/  /bin/
COPY --from=builder /tmp/knot-install/sbin/ /sbin/
COPY --from=builder /tmp/knot-install/lib/  /lib/
COPY --from=exporter /knot-exporter         /bin/knot-exporter

USER ${UID}:${UID}
# 9433 is the exporter's metrics port. It binds loopback unless told
# otherwise, so a sidecar must pass -web-listen-addr.
EXPOSE 53/udp 53/tcp 853/udp 853/tcp 9433/tcp
ENTRYPOINT ["/sbin/knotd"]
