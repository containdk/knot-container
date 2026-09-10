# syntax=docker/dockerfile:1

# renovate: datasource=gitlab-tags depName=knot/knot-dns registryUrl=https://gitlab.nic.cz
ARG KNOT_VERSION="3.6.0"

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
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${KNOT_RELEASE_FINGERPRINT}" \
        | gpg --dearmor > /tmp/knot-release.gpg && \
    # The keyring holds this one key, so a signature by anyone else does not
    # verify. The fingerprint is asserted as well, in case the keyserver
    # answers with something other than what was asked for.
    gpg --no-default-keyring --keyring /tmp/knot-release.gpg --batch --with-colons --fingerprint \
        | grep -q "^fpr:::::::::${KNOT_RELEASE_FINGERPRINT}:" && \
    gpg --no-default-keyring --keyring /tmp/knot-release.gpg --batch --verify \
        "knot-${KNOT_VERSION}.tar.xz.asc" "knot-${KNOT_VERSION}.tar.xz" && \
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

FROM cgr.dev/chainguard/wolfi-base
ARG KNOT_VERSION
ARG UID=53

RUN apk add --no-cache \
        gnutls \
        jansson \
        libcap-ng \
        libedit \
        libidn2 \
        lmdb \
        nghttp2 \
        ngtcp2 \
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

USER ${UID}:${UID}
EXPOSE 53/udp 53/tcp 853/udp 853/tcp
ENTRYPOINT ["/sbin/knotd"]
