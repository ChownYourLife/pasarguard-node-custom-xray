#!/usr/bin/env bash
# Runtime smoke for the custom PasarGuard node image.
#
#   scripts/smoke.sh IMAGE
#   PLATFORM=linux/amd64 scripts/smoke.sh IMAGE
#
# Proves the image's Node v0.5.5 service controls the baked-in Xray fork:
#   - /usr/local/bin/xray version contains the pinned fork commit
#   - a config using geoip:cn and geosite:cn starts (both geodata files load)
#   - GetBaseInfo goes stopped -> started -> stopped
#   - GetBackendStats returns live counters from Xray's stats service
# The default gRPC service (SERVICE_PROTOCOL is not set) is used. Everything
# runs on a throwaway Docker network with no published ports; the throwaway
# certificate, containers, network and temp files are removed on exit.
#
# Prerequisites: Docker with a running daemon, curl, openssl.

set -euo pipefail

CORE_COMMIT=c8768463568d9655a67228531d4ed2690ee49dd7
# The gRPC schema of the official node release this image extends.
NODE_COMMIT=47857d43fe777f30f9ecc5f2ffe4ca0b037507cb
PROTO_URL="https://raw.githubusercontent.com/PasarGuard/node/${NODE_COMMIT}/common/service.proto"
# grpcurl v1.9.3 multi-arch index, pinned by digest.
GRPCURL_IMAGE='fullstorydev/grpcurl:v1.9.3@sha256:085e183ca334eb4e81ca81ee12cbb2b2737505d1d77f5e33dabc5d066593d998'

usage() {
  echo "usage: scripts/smoke.sh IMAGE"
  echo "       PLATFORM=linux/amd64|linux/arm64 scripts/smoke.sh IMAGE"
  echo "requires: docker, curl, openssl"
}

fail() {
  echo "smoke: FAIL: $*" >&2
  exit 1
}

[ "$#" -eq 1 ] || { usage >&2; exit 2; }
image=$1
[ -n "$image" ] || { usage >&2; exit 2; }

for tool in docker curl openssl; do
  command -v "$tool" >/dev/null 2>&1 || fail "missing prerequisite: $tool"
done

platform_args=()
case "${PLATFORM:-}" in
  '') ;;
  linux/amd64|linux/arm64) platform_args=(--platform "$PLATFORM") ;;
  *) fail "PLATFORM must be linux/amd64 or linux/arm64" ;;
esac

tmpdir=''
net=''
node_container=''
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ "$status" -ne 0 ] && [ -n "$node_container" ] \
    && docker inspect "$node_container" >/dev/null 2>&1; then
    echo "smoke: node logs (last 80 lines):" >&2
    docker logs "$node_container" 2>&1 | tail -n 80 >&2 || true
  fi
  [ -z "$node_container" ] || docker rm -f "$node_container" >/dev/null 2>&1 || true
  [ -z "$net" ] || docker network rm "$net" >/dev/null 2>&1 || true
  [ -z "$tmpdir" ] || rm -rf "$tmpdir" || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tmpdir=$(mktemp -d /tmp/pg-node-smoke.XXXXXX)
chmod 755 "$tmpdir" # grpcurl runs as an unprivileged user and reads the proto
proto=$tmpdir/service.proto
cert=$tmpdir/cert.pem
key=$tmpdir/key.pem
start_request=$tmpdir/start.json

echo "smoke: fetching pinned node service.proto"
curl -fsSL --proto '=https' --tlsv1.2 "$PROTO_URL" -o "$proto"
chmod 644 "$proto"
grep -q '^service NodeService' "$proto" || fail "downloaded proto is not the node service"

echo "smoke: generating throwaway TLS certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
  -keyout "$key" -out "$cert" -subj '/CN=localhost' >/dev/null 2>&1 \
  || fail "openssl could not create a test certificate"
[ -s "$cert" ] && [ -s "$key" ] || fail "openssl did not create cert/key"
chmod 600 "$key"

api_key_hex=$(openssl rand -hex 16)
api_key="${api_key_hex:0:8}-${api_key_hex:8:4}-4${api_key_hex:12:3}-a${api_key_hex:16:3}-${api_key_hex:20:12}"
[ -n "$api_key" ] || fail "openssl produced an empty API key"

net="pg-node-smoke-$$"
node_container="pg-node-smoke-$$"
docker network create "$net" >/dev/null

echo "smoke: starting node (default gRPC protocol)"
# No SERVICE_PROTOCOL: exercise the production default. No ports are published.
docker run -d \
  ${platform_args[@]+"${platform_args[@]}"} \
  --name "$node_container" \
  --network "$net" \
  --network-alias node \
  -e SERVICE_PORT=62050 \
  -e NODE_HOST=0.0.0.0 \
  -e API_KEY="$api_key" \
  -e SSL_CERT_FILE=/smoke/cert.pem \
  -e SSL_KEY_FILE=/smoke/key.pem \
  -e GENERATED_CONFIG_PATH=/tmp/pg-node-generated \
  -v "$tmpdir:/smoke:ro" \
  "$image" >/dev/null

grpc() {
  local method=$1
  shift
  docker run --rm \
    ${platform_args[@]+"${platform_args[@]}"} \
    --network "$net" \
    -v "$tmpdir:/smoke:ro" \
    "$GRPCURL_IMAGE" \
    -insecure \
    -emit-defaults \
    -import-path /smoke \
    -proto service.proto \
    -H "x-api-key: $api_key" \
    -max-time "${GRPC_TIMEOUT:-120}" \
    "$@" \
    node:62050 \
    "$method"
}

echo "smoke: waiting for node gRPC"
base_info=''
ready=0
i=0
while [ "$i" -lt 30 ]; do
  i=$((i + 1))
  if base_info=$(GRPC_TIMEOUT=5 grpc service.NodeService/GetBaseInfo -d '{}' 2>&1); then
    ready=1
    break
  fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$node_container" 2>/dev/null || true)" != "true" ]; then
    fail "node exited before serving gRPC"
  fi
  sleep 1
done
[ "$ready" -eq 1 ] || fail "node gRPC not ready after 30s: $base_info"

echo "smoke: checking initial stopped state"
grep -Eq '"started"[[:space:]]*:[[:space:]]*false' <<<"$base_info" \
  || fail "initial GetBaseInfo does not report stopped: $base_info"

echo "smoke: checking baked Xray commit"
xray_version=$(docker exec "$node_container" /usr/local/bin/xray version 2>&1) \
  || fail "cannot run /usr/local/bin/xray version"
grep -Fq "$CORE_COMMIT" <<<"$xray_version" \
  || fail "xray version does not contain $CORE_COMMIT: $xray_version"

echo "smoke: starting Xray through node"
# geoip:cn and geosite:cn force both geodata files to load at config parse.
cat > "$tmpdir/xray.json" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "smoke-socks",
      "listen": "127.0.0.1",
      "port": 9000,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": false}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "BLOCK", "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "BLOCK"},
      {"type": "field", "ip": ["geoip:cn"], "outboundTag": "direct"},
      {"type": "field", "domain": ["geosite:cn"], "outboundTag": "direct"}
    ]
  }
}
JSON
escaped_config=$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$tmpdir/xray.json" | tr -d '\n')
printf '{"type":"XRAY","config":"%s"}\n' "$escaped_config" > "$start_request"

start_resp=$(grpc service.NodeService/Start -d "$(cat "$start_request")") \
  || fail "Start RPC failed"
grep -Eq '"started"[[:space:]]*:[[:space:]]*true' <<<"$start_resp" \
  || fail "Start did not report a started core: $start_resp"
grep -Eq '"(coreVersion|core_version)"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$start_resp" \
  || fail "Start did not report a core version: $start_resp"

echo "smoke: checking started state"
base_info=$(grpc service.NodeService/GetBaseInfo -d '{}') || fail "GetBaseInfo after Start failed"
grep -Eq '"started"[[:space:]]*:[[:space:]]*true' <<<"$base_info" \
  || fail "GetBaseInfo does not report started: $base_info"
grep -Eq '"(coreVersion|core_version)"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$base_info" \
  || fail "GetBaseInfo does not report a core version: $base_info"

echo "smoke: checking backend statistics"
backend_stats=$(grpc service.NodeService/GetBackendStats -d '{}') \
  || fail "GetBackendStats failed"
grep -Eq '"(numGoroutine|num_goroutine)"[[:space:]]*:[[:space:]]*"?[1-9][0-9]*"?' <<<"$backend_stats" \
  || fail "GetBackendStats returned no live Xray goroutine count: $backend_stats"
grep -Eq '"(alloc|totalAlloc|total_alloc|sys)"[[:space:]]*:[[:space:]]*"?[1-9][0-9]*"?' <<<"$backend_stats" \
  || fail "GetBackendStats returned no live Xray memory stats: $backend_stats"

echo "smoke: stopping Xray through node"
grpc service.NodeService/Stop -d '{}' >/dev/null || fail "Stop RPC failed"
base_info=$(grpc service.NodeService/GetBaseInfo -d '{}') || fail "GetBaseInfo after Stop failed"
grep -Eq '"started"[[:space:]]*:[[:space:]]*false' <<<"$base_info" \
  || fail "GetBaseInfo still reports started after Stop: $base_info"

echo "smoke: PASS"
