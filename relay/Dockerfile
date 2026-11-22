# Contexto de build: la raíz del repo (necesita relay/ y web/). En el VPS: docker build -f src/relay/Dockerfile src
# (deploy.sh). Los archivos que no entran al contexto están en Dockerfile.dockerignore, al lado de este archivo.
# Las imágenes base van fijadas por digest (dos builds del mismo commit dan la misma base); se actualizan a propósito:
#   docker buildx imagetools inspect <imagen:tag>   → el "Digest:" del índice

# 1. La web app del teléfono (spec W.2): web/dist.
FROM node:24.21.0@sha256:3d27e5c11e5786e309ec3e03f93ae536eb36e6e5eb3714d5eb3300a36157add0 AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --ignore-scripts
COPY web/ ./
RUN npm run build

# 2. Binario estático con la web embebida (internal/web/dist). GOARCH: la arquitectura de la imagen final (la de la
# plataforma de destino de BuildKit; arm64, la del VPS, si no hay). En otro server: --build-arg GOARCH=amd64.
FROM golang:1.27.4@sha256:205c7636d74e0ffbe3d007162df7d74f859f5a8c8322dfb9f907977686c126cf AS build
ARG TARGETARCH
ARG GOARCH=${TARGETARCH:-arm64}
WORKDIR /src
COPY relay/go.mod relay/go.sum ./
RUN go mod download && go mod verify
COPY relay/ ./
# La web construida reemplaza al placeholder del repo.
RUN rm -rf internal/web/dist
COPY --from=web /src/web/dist/ internal/web/dist/
RUN test -f internal/web/dist/index.html \
 && CGO_ENABLED=0 GOOS=linux GOARCH=${GOARCH} go build -trimpath -ldflags="-s -w" -o /out/prbar-relay ./cmd/prbar-relay \
 && mkdir -p /out/data

# 3. Imagen distroless sin shell, como usuario sin privilegios.
# El healthcheck lo corre el mismo binario (prbar-relay -healthcheck): la imagen no tiene shell ni curl.
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/prbar-relay /prbar-relay
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/prbar-relay"]
