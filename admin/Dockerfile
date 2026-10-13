# full names: Podman does not resolve short ones
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.26 AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG VERSION=dev
RUN go test ./... && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /ffs-admin .

# no shell, no package manager, runs as nobody
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /ffs-admin /ffs-admin
USER nonroot
EXPOSE 8080 8081
HEALTHCHECK --interval=30s --timeout=5s CMD ["/ffs-admin", "healthcheck"]
ENTRYPOINT ["/ffs-admin"]
CMD ["serve"]
