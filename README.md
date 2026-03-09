# VGI Injector

Minimal download-and-execute binary for Linux. Downloads a binary via HTTPS and exec's it using memfd — no filesystem writes needed. Designed for `FROM scratch` containers with zero runtime dependencies.

Built in Zig with everything self-contained: DNS resolver, TLS, and embedded CA certificates.

## Features

- **Zero dependencies** — statically linked, no libc, runs in `FROM scratch` containers
- **Built-in DNS resolver** — raw UDP queries with retry and exponential backoff, supports IPv4 and IPv6 DNS servers (e.g. Fly.io's `fdaa::3`)
- **Embedded CA certificates** — full Mozilla CA bundle, downloaded at build time
- **TLS via Zig stdlib** — no OpenSSL dependency
- **memfd exec** — writes downloaded binary to memfd, exec's from `/proc/self/fd/N`
- **Small binary** — ~460 KB stripped, ~220 KB with UPX compression

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `VGI_INJECTOR_URL` | Yes | — | HTTPS URL of the binary to download and execute |
| `VGI_INJECTOR_DNS` | No | `1.1.1.1` | DNS server address (IPv4 or IPv6) |

## Build

Requires [Zig](https://ziglang.org/) 0.15.x. Cross-compiles to Linux from any platform.

```bash
# Download/update CA bundle (required before first build)
./update-ca-bundle.sh

# Build for amd64 (default)
zig build

# Build for arm64
zig build -Darch=aarch64

# Build with version string
zig build -Dversion=v1.0.0

# Output: zig-out/bin/vgi-injector
```

Optionally compress with UPX (amd64 only):

```bash
cp zig-out/bin/vgi-injector injector-upx
upx --best injector-upx
```

## Deploy

### Fly.io

The binary is injected into a `FROM scratch` container via Fly's `[[files]]` config:

```bash
fly deploy
```

See `fly.toml` for the deployment configuration.

## CI/CD

GitHub Actions builds on push to `main`, PRs, and version tags. Matrix builds for amd64 and arm64.

- **Push to main / PR** — build and upload artifacts
- **Push to main** — also publish to Cloudflare R2
- **Tag `v*`** — publish to R2 and create GitHub Release

To create a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Binaries are available at `https://vgi-injector.query-farm.services/`.

## CA Bundle

The Mozilla CA certificate bundle is not checked into source control. It is downloaded automatically:

- **Locally**: Run `./update-ca-bundle.sh` before building. The script downloads the bundle if missing or older than 7 days.
- **CI**: The workflow runs the script before each build, ensuring a fresh bundle.

The bundle is sourced from [curl.se/ca/cacert.pem](https://curl.se/ca/cacert.pem), which is an extraction of Mozilla's trusted root certificates.

## License

Copyright 2026 Query.Farm LLC — All Rights Reserved.
