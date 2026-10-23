# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.27.1-alpine@sha256:8a5910f31396cd4d89662f56c68b3ae31d374308270a1c3bd96672ee5ed43414 AS core

ARG TARGETOS
ARG TARGETARCH

WORKDIR /src
ADD --checksum=sha256:fedfd3d5fa3169361dcdb5fbf91e94a28f853e684bc2b055acc52fb176b7fdbd https://codeload.github.com/T3ST3ST3R0N/Xray-core/tar.gz/c8768463568d9655a67228531d4ed2690ee49dd7 /tmp/xray.tar.gz

RUN tar -xzf /tmp/xray.tar.gz --strip-components=1 -C /src && \
    rm /tmp/xray.tar.gz && \
    mkdir -p /out && \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} GOTOOLCHAIN=local \
    go build -trimpath -buildvcs=false \
    -ldflags="-s -w -buildid= -X github.com/xtls/xray-core/core.build=c8768463568d9655a67228531d4ed2690ee49dd7" \
    -o /out/xray ./main

FROM docker.io/pasarguard/node:v0.5.5@sha256:5f41e456ad68c84f42855b41eb41d69a79e8b3795bbe6a739ed74c4627eaa99b

LABEL org.opencontainers.image.source="https://github.com/ChownYourLife/pasarguard-node-custom-xray" \
      org.opencontainers.image.licenses="GPL-3.0-only AND MPL-2.0" \
      org.opencontainers.image.base.name="docker.io/pasarguard/node:v0.5.5" \
      org.opencontainers.image.base.digest="sha256:5f41e456ad68c84f42855b41eb41d69a79e8b3795bbe6a739ed74c4627eaa99b" \
      io.github.chownyourlife.pasarguard-node.source="https://github.com/PasarGuard/node" \
      io.github.chownyourlife.xray.source="https://github.com/T3ST3ST3R0N/Xray-core" \
      io.github.chownyourlife.xray.commit="c8768463568d9655a67228531d4ed2690ee49dd7" \
      io.github.chownyourlife.pasarguard-node.version="v0.5.5"

COPY --from=core --chmod=0755 /out/xray /usr/local/bin/xray
COPY --from=core /src/LICENSE /usr/share/licenses/xray/LICENSE
