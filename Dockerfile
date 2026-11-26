# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18 AS core

ARG TARGETOS
ARG TARGETARCH

WORKDIR /src
ADD --checksum=sha256:c600a973a3e0c954f184133763c95c8f15a24ef6bf466d956d1eb985ca10cbf4 https://codeload.github.com/T3ST3ST3R0N/Xray-core/tar.gz/7e50e6084bdfe5713a5848f3b6317e4f0a57dbe4 /tmp/xray.tar.gz

RUN tar -xzf /tmp/xray.tar.gz --strip-components=1 -C /src && \
    rm /tmp/xray.tar.gz && \
    mkdir -p /out && \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} GOTOOLCHAIN=local \
    go build -trimpath -buildvcs=false \
    -ldflags="-s -w -buildid= -X github.com/xtls/xray-core/core.build=7e50e6084bdfe5713a5848f3b6317e4f0a57dbe4" \
    -o /out/xray ./main

FROM docker.io/pasarguard/node:v0.5.5@sha256:5f41e456ad68c84f42855b41eb41d69a79e8b3795bbe6a739ed74c4627eaa99b

LABEL org.opencontainers.image.source="https://github.com/ChownYourLife/pasarguard-node-custom-xray" \
      org.opencontainers.image.licenses="GPL-3.0-only AND MPL-2.0" \
      org.opencontainers.image.base.name="docker.io/pasarguard/node:v0.5.5" \
      org.opencontainers.image.base.digest="sha256:5f41e456ad68c84f42855b41eb41d69a79e8b3795bbe6a739ed74c4627eaa99b" \
      io.github.chownyourlife.pasarguard-node.source="https://github.com/PasarGuard/node" \
      io.github.chownyourlife.xray.source="https://github.com/T3ST3ST3R0N/Xray-core" \
      io.github.chownyourlife.xray.commit="7e50e6084bdfe5713a5848f3b6317e4f0a57dbe4" \
      io.github.chownyourlife.pasarguard-node.version="v0.5.5"

COPY --from=core --chmod=0755 /out/xray /usr/local/bin/xray
COPY --from=core /src/LICENSE /usr/share/licenses/xray/LICENSE
