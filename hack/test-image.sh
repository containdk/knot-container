#!/usr/bin/env bash
#
# Exercises a built image the way the platform actually uses it: a hidden
# primary that takes RFC 2136 updates, and a secondary that transfers the zone
# and answers queries.
#
# Usage: hack/test-image.sh [image]

set -euo pipefail

IMAGE="${1:-knot-container:test}"
NET="knot-image-test"
ZONE="example.test"
TSIG="$(head -c 32 /dev/urandom | base64)"

pass() { echo "  ✅ $*"; }
fail() { echo "  ❌ $*" >&2; exit 1; }

cleanup() {
    docker rm -f knot-test-primary knot-test-secondary >/dev/null 2>&1 || true
    docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
docker network create "${NET}" >/dev/null

docker run -d --name knot-test-secondary --network "${NET}" \
    --entrypoint sleep "${IMAGE}" infinity >/dev/null
docker run -d --name knot-test-primary --network "${NET}" \
    --entrypoint sleep "${IMAGE}" infinity >/dev/null

primary_ip=$(docker inspect -f "{{ (index .NetworkSettings.Networks \"${NET}\").IPAddress }}" knot-test-primary)
secondary_ip=$(docker inspect -f "{{ (index .NetworkSettings.Networks \"${NET}\").IPAddress }}" knot-test-secondary)

for c in knot-test-primary knot-test-secondary; do
    docker exec -u 0 "${c}" sh -c \
        'mkdir -p /etc/knot-keys && chown -R 53:53 /etc/knot-keys /config /rundir /storage'
    docker exec -i "${c}" sh -c "cat > /etc/knot-keys/keys.conf" <<KEYS
key:
  - id: update-key
    algorithm: hmac-sha256
    secret: ${TSIG}
  - id: transfer-key
    algorithm: hmac-sha256
    secret: ${TSIG}
KEYS
done

docker exec -i knot-test-primary sh -c "cat > /config/knot.conf" <<CONF
server:
    rundir: "/rundir"
    listen: [ 0.0.0.0@53 ]
    udp-max-payload: 1232
    automatic-acl: off
log:
  - target: stdout
    any: info
include: /etc/knot-keys/keys.conf
acl:
  - id: update-acl
    key: update-key
    action: update
  - id: transfer-acl
    key: transfer-key
    action: transfer
remote:
  - id: secondary
    address: ${secondary_ip}
    key: transfer-key
template:
  - id: default
    storage: "/storage"
    zonefile-sync: -1
    zonefile-load: none
    journal-content: all
    semantic-checks: on
    acl: [ update-acl, transfer-acl ]
    notify: [ secondary ]
zone:
  - domain: ${ZONE}
    template: default
CONF

docker exec -i knot-test-secondary sh -c "cat > /config/knot.conf" <<CONF
server:
    rundir: "/rundir"
    listen: [ 0.0.0.0@53 ]
    udp-max-payload: 1232
    automatic-acl: off
log:
  - target: stdout
    any: info
include: /etc/knot-keys/keys.conf
acl:
  - id: primary-acl
    key: transfer-key
    action: [ transfer, notify ]
mod-rrl:
  - id: default
    rate-limit: 200
    slip: 2
remote:
  - id: primary
    address: ${primary_ip}
    key: transfer-key
template:
  - id: default
    storage: "/storage"
    zonefile-sync: -1
    zonefile-load: none
    journal-content: all
    master: primary
    acl: [ primary-acl ]
    global-module: mod-rrl/default
zone:
  - domain: ${ZONE}
    template: default
CONF

for c in knot-test-primary knot-test-secondary; do
    docker exec -d "${c}" sh -c '/sbin/knotd -c /config/knot.conf > /tmp/knotd.log 2>&1'
done
sleep 5

docker exec knot-test-primary /sbin/knotd --version | grep -q "Knot DNS" \
    || fail "knotd does not report a version"
pass "$(docker exec knot-test-primary /sbin/knotd --version)"

docker exec knot-test-primary id | grep -q "uid=53(knot)" \
    || fail "the image does not run as uid 53"
pass "runs as uid 53"

# An RFC 2136 update cannot create a zone, so seed the apex the way the
# component's bootstrap sidecar does.
docker exec knot-test-primary sh -c "
    /sbin/knotc -c /config/knot.conf zone-begin ${ZONE} &&
    /sbin/knotc -c /config/knot.conf zone-set ${ZONE} @ 3600 SOA ns1.${ZONE}. hostmaster.${ZONE}. 1 3600 600 1209600 300 &&
    /sbin/knotc -c /config/knot.conf zone-set ${ZONE} @ 3600 NS ns1.${ZONE}. &&
    /sbin/knotc -c /config/knot.conf zone-set ${ZONE} ns1.${ZONE}. 3600 A 198.51.100.1 &&
    /sbin/knotc -c /config/knot.conf zone-commit ${ZONE}" >/dev/null \
    || fail "could not seed the zone apex"
pass "seeded the zone apex through knotc"

if docker exec knot-test-primary grep -q "missing glue" /tmp/knotd.log; then
    fail "the seeded apex failed a semantic check"
fi
pass "the seeded apex passes semantic checks"

for attempt in $(seq 1 30); do
    status=$(docker exec knot-test-secondary /sbin/knotc -c /config/knot.conf zone-status "${ZONE}" || true)
    [[ "${status}" == *"serial: 1"* ]] && break
    sleep 1
done
[[ "${status}" == *"serial: 1"* ]] || fail "the secondary never transferred the zone"
pass "the secondary transferred the zone"

docker exec knot-test-primary sh -c "
    printf 'server ${primary_ip}\nzone ${ZONE}\nupdate add api.${ZONE}. 300 A 198.51.100.10\nsend\n' > /tmp/update.txt
    /usr/bin/knsupdate -y hmac-sha256:update-key:${TSIG} /tmp/update.txt" \
    || fail "the primary refused an update signed with the update key"

for attempt in $(seq 1 30); do
    answer=$(docker exec knot-test-secondary /usr/bin/kdig @127.0.0.1 "api.${ZONE}" A +short || true)
    [[ "${answer}" == *198.51.100.10* ]] && break
    sleep 1
done
[[ "${answer}" == *198.51.100.10* ]] || fail "the update never reached the secondary"
pass "an update reached the secondary over NOTIFY and IXFR"

docker exec knot-test-primary sh -c "
    printf 'server ${primary_ip}\nzone ${ZONE}\nupdate add refused.${ZONE}. 300 A 203.0.113.1\nsend\n' > /tmp/bad.txt
    /usr/bin/knsupdate -y hmac-sha256:transfer-key:${TSIG} /tmp/bad.txt" >/dev/null 2>&1 || true
docker exec knot-test-primary /sbin/knotc -c /config/knot.conf zone-read "${ZONE}" refused A >/dev/null 2>&1 \
    && fail "an update signed with the transfer key was accepted"
pass "the transfer key cannot write to the zone"

# kdig exits non-zero on a refused query, so capture before matching.
transfer=$(docker exec knot-test-secondary /usr/bin/kdig "@${primary_ip}" "${ZONE}" AXFR 2>&1 || true)
grep -q NOTAUTH <<<"${transfer}" || fail "an unsigned AXFR was not refused"
pass "an unsigned zone transfer is refused"

outside=$(docker exec knot-test-secondary /usr/bin/kdig @127.0.0.1 www.example.net A 2>&1 || true)
grep -q REFUSED <<<"${outside}" || fail "a query outside the zone was not refused"
pass "queries outside the zone are refused"

docker exec knot-test-primary sh -c '
    printf "server:\n    rundir: \"/rundir\"\nmod-stats:\n  - id: default\n    request-protocol: on\nmod-cookies:\n  - id: default\ntemplate:\n  - id: default\n    storage: \"/storage\"\n    global-module: [ mod-stats/default, mod-cookies/default ]\n" > /tmp/modules.conf
    /sbin/knotc -c /tmp/modules.conf conf-check' >/dev/null \
    || fail "mod-stats or mod-cookies is not built in"
pass "mod-rrl, mod-stats and mod-cookies are available"

echo
echo "All image tests passed. ✅"
