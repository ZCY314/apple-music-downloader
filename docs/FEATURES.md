# Feature guide

This document describes behavior implemented in this fork. The command-line help and configuration example remain the source of truth for exact flags and defaults.

## Supported Apple Music resources

- Albums and individual songs
- Playlists and stations (stations require a valid `media-user-token`)
- Artist catalogs, including albums and music videos
- Music videos

The downloader supports ALAC, Dolby Atmos / EC-3, AAC variants, metadata, artwork and lyrics. Availability depends on the Apple Music storefront, subscription, source item and the configured wrapper-lite service.

## Interactive search

Search supports albums, songs and artists:

```bash
./amdl --search album "artist or album keywords"
./amdl --search song "track keywords"
./amdl --search artist "artist name"
```

Use `--select` to select multiple results:

```bash
./amdl --select --search album "artist name"
./amdl --select --search artist "artist name"
```

Behavior:

1. Results are presented in pages of up to 15 items.
2. In multi-select mode, use Space to toggle results and Enter to confirm the page.
3. Choose the next/previous page option to continue browsing. Selections are accumulated across pages.
4. Choose **Finish selection** when ready to process the accumulated results.
5. Duplicate URLs are ignored while preserving selection order.
6. A single quality choice is applied to the selected batch.
7. For album search with `--select`, selected albums download all tracks; the downloader does not ask for a second track-by-track selection.
8. For artist search with `--select`, each selected artist is expanded into albums and music videos. The configured artist-folder template is resolved per artist so results remain grouped correctly.

Without `--select`, search remains a single-result interactive flow and asks for the quality of the chosen item.

## Download quality

The command-line flags include `--atmos`, `--aac`, and quality constraints such as `--alac-max`, `--atmos-max`, `--aac-type`, `--mv-max`, and `--mv-audio-type`. Check `./amdl --help` for the complete current list.

## Dependencies and boundaries

- `wrapper-lite` provides the required backend decryption API. It is a separate service and is not bundled into the downloader.
- `ffmpeg` is optional and is only needed for features that invoke it, such as conversion or animated-artwork processing.
- This project does not provide Apple Music subscriptions, credentials, or media access.
- Service-side changes can affect availability independently of this repository.

## Known limitations

- Search and catalog results are limited by Apple Music storefront and API responses.
- Interactive selection requires a terminal (and a TTY when running in Docker).
- Integration tests requiring live Apple Music credentials or a running wrapper-lite service are not part of the default CI suite.
