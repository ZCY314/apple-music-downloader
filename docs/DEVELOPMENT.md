# Development and maintenance

## Toolchain

- Go 1.23.1 (the version declared by `go.mod`)
- Git
- Optional: ffmpeg for runtime features that invoke it
- Optional at runtime: wrapper-lite service

## Local setup

```bash
git clone https://github.com/ZCY314/apple-music-downloader.git
cd apple-music-downloader
go mod download
go test ./...
go vet ./...
go build -trimpath -o amdl .
./amdl --help
```

For contributors working from a fork, add the original repository as an upstream remote:

```bash
git remote add upstream https://github.com/zhaarey/apple-music-downloader.git
git remote -v
```

Do not commit local configuration, credentials, tokens, downloaded media, or generated binaries.

## Project layout

| Path | Responsibility |
|---|---|
| `main.go` | Program entry point |
| `internal/app/` | CLI orchestration, search, download flows and media handling |
| `internal/amp-api/` | Apple Music API interactions |
| `internal/config/` | Configuration loading and defaults |
| `internal/download/` | HTTP and segmented download support |
| `internal/media/` | Media, lyrics and container processing |
| `internal/updater/` | Self-update and configuration migration |
| `.github/workflows/ci.yml` | Pull-request and main-branch validation |
| `.github/workflows/release.yml` | Versioned binary releases |
| `.github/workflows/docker.yml` | Container publishing |

## Quality gates

Run these before opening a pull request:

```bash
gofmt -w .
go vet ./...
go test ./...
go test -race ./...
go build -trimpath ./...
git diff --check
```

The GitHub Actions CI workflow runs formatting checks, vet, tests and builds on Linux, Windows and macOS. The race detector runs on Linux. A separate job builds and smoke-tests the Docker image.

Tests should be deterministic and offline by default. Use `httptest`, temporary directories and injected clients instead of live Apple Music requests. Tests that require credentials or external services must be explicitly opt-in and must never run in ordinary CI.

## Release process

Releases are controlled by the root `VERSION` file. The release workflow runs on pushes to `main` and manual dispatch:

1. Validate the semantic version in `VERSION`.
2. If tag `v<VERSION>` does not exist, cross-compile supported targets.
3. Publish the binaries and SHA-256 checksums as a GitHub Release.
4. Build and publish the multi-architecture container image.

To publish a release, update `VERSION` in a reviewed commit and merge it into `main`. Use a suffix such as `0.2.0-beta.1` for a prerelease. Do not manually create the tag before the workflow checks it.

Release builds inject this fork's owner and repository into the self-updater. This ensures binaries published here check for updates from this fork rather than the upstream project.

## Upstream synchronization

Keep the fork's commits focused and preserve the upstream history. Before syncing upstream:

```bash
git fetch upstream
git log --oneline --left-right main...upstream/main
```

Review upstream changes before merging or rebasing. Resolve conflicts carefully, especially in CLI orchestration, media decryption and release workflows. Run the complete quality gates after synchronization.

## Maintenance priorities

1. Keep the default branch buildable and the CI suite green.
2. Add regression tests for every bug fix and user-visible behavior change.
3. Keep README examples aligned with actual CLI flags and config keys.
4. Review upstream changes and dependency updates regularly.
5. Publish releases only after CI succeeds; retain checksums and release notes.
