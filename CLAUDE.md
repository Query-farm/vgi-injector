# VGI Injector

Minimal download-and-execute binary for Linux amd64. Downloads a binary via HTTPS and exec's it. Runs in `FROM scratch` containers with zero runtime dependencies.

## Architecture

Single Zig binary with everything built-in:
- **Built-in DNS resolver** — raw UDP queries, supports IPv4 and IPv6 DNS servers (e.g. Fly's `fdaa::3`)
- **Embedded CA certificates** — full Mozilla CA bundle at `src/ca-certificates.crt`
- **TLS via Zig stdlib** — no OpenSSL/libc dependency
- **memfd exec** — writes downloaded binary to memfd, exec's from `/proc/self/fd/N`, no filesystem needed
- **DNS and download retries** — exponential backoff, 3 attempts each

## Environment Variables

- `VGI_INJECTOR_URL` (required) — HTTPS URL of the binary to download
- `VGI_INJECTOR_DNS` (optional, default `1.1.1.1`) — DNS server address (IPv4 or IPv6)

## Build

Requires Zig 0.15.x. Cross-compiles to Linux amd64 from any platform.

```bash
zig build
# Output: zig-out/bin/vgi-injector (736 KB)

# UPX compress for deployment:
cp zig-out/bin/vgi-injector injector-zig-upx
upx --best injector-zig-upx
# Output: injector-zig-upx (354 KB)
```

Target: `x86_64-linux-none` (freestanding, no libc ABI).

## Deploy to Fly.io

The binary is injected into a `FROM scratch` container via Fly's `[[files]]` config (base64-encoded in the API request — must stay under ~500 KB).

```bash
fly deploy
```

## CI

GitHub Actions builds on push to `main` and on PRs. The `build` job compiles and uploads the binary as an artifact. The `release` job (main only) also produces a UPX-compressed artifact.

## Project Structure

```
src/main.zig              — all logic in one file
src/ca-certificates.crt   — embedded CA bundle (copied from /etc/ssl/cert.pem)
build.zig                 — build config (x86_64-linux-none, ReleaseSmall, stripped)
test-binary/              — test binary deployed to R2 (prints heartbeat to stderr)
fly.toml                  — Fly.io deployment config
Dockerfile                — FROM scratch (empty)
injector-zig-upx          — UPX-compressed binary for deployment
.github/workflows/build.yml — CI build and UPX compression
```

## R2 / CDN

Binaries are hosted on Cloudflare R2 bucket `vgi-injector-binaries` with custom domain `vgi-injector.query-farm.services` (CDN cache enabled via cache rule in Cloudflare dashboard).

Upload binaries with:
```bash
npx wrangler r2 object put vgi-injector-binaries/<name> --file <path> --remote \
  --content-type application/octet-stream \
  --cache-control "public, max-age=86400"
```

## Zig Notes

- Uses Zig 0.15 APIs — significant breaking changes from earlier versions (Writer/Reader interfaces, ArrayList, sleep, etc.)
- `std.Thread.sleep` not `std.time.sleep`
- `std.ArrayListUnmanaged(u8) = .empty` with explicit allocator
- `@embedFile` paths must be within the package source directory
- Response reading: `req.sendBodiless()` → `req.receiveHead()` → `response.reader()` → manual read loop
