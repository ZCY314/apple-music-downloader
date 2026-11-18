# Contributing

Thanks for helping improve this Apple Music downloader fork.

## Before opening an issue

- Search existing issues and discussions for duplicates.
- Include the program version (`./amdl --version`), OS and architecture.
- Include a minimal reproduction and relevant logs.
- Redact authorization headers, cookies, `media-user-token`, personal paths and other private data.

## Pull requests

1. Keep changes focused and explain the user-visible behavior.
2. Add or update tests for bug fixes and new behavior.
3. Update `README.md`, `README-CN.md` or the feature/development docs when behavior changes.
4. Run the quality gates listed in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
5. Describe compatibility impact, limitations and manual verification in the PR.

Do not include credentials, private configuration, downloaded media, generated binaries or unrelated formatting changes.

## Code and tests

- Follow idiomatic Go and format code with `gofmt`.
- Prefer small functions with explicit error handling.
- Keep tests deterministic and independent of live Apple Music services.
- Use temporary directories and test HTTP servers for filesystem/network behavior.
- Avoid logging secrets or complete authorization values.

## Upstream and attribution

This repository is a fork of [zhaarey/apple-music-downloader](https://github.com/zhaarey/apple-music-downloader). Preserve upstream copyright notices, license files and third-party attributions. Do not imply that this fork owns the original work. Contributions are made under the repository's applicable license; check the upstream license before submitting.

## Responsible use

Use the software only for media you are authorized to access. Contributors should not add features intended to bypass payment, access controls, or applicable law.
