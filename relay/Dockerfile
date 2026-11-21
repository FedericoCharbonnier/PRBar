# Contexto de build: la raíz del repo (necesita relay/ y web/). En el VPS: docker build -f src/relay/Dockerfile src
# (deploy.sh). Los archivos que no entran al contexto están en Dockerfile.dockerignore, al lado de este archivo.

# 1. La web app del teléfono (spec W.2): web/dist.
FROM node:24 AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# 2. Binario estático para linux/arm64 (el VPS) con la web embebida (internal/web/dist).
FROM golang:1.27 AS build
WORKDIR /src
COPY relay/go.mod relay/go.sum ./
RUN go mod download && go mod verify
COPY relay/ ./
# La web construida reemplaza al placeholder del repo.
RUN rm -rf internal/web/dist
COPY --from=web /src/web/dist/ internal/web/dist/
RUN test -f internal/web/dist/index.html \
 && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o /out/prbar-relay ./cmd/prbar-relay \
 && mkdir -p /out/data

# 3. Imagen distroless sin shell, como usuario sin privilegios.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/prbar-relay /prbar-relay
COPY --from=build --chown=65532:65532 /out/data /data
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/prbar-relay"]
