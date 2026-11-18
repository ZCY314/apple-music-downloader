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

1. Search keeps the original phrase, then adds bounded query variants: reversed word order, individual words, adjacent word pairs, and overlapping Chinese title fragments.
2. Album searches query CN first by default, then HK, TW, SG and US storefronts in addition to the configured storefront. Regional fallbacks use the original phrase and preserve each result's storefront URL.
3. Each query follows Apple Music API pagination (up to four pages of 25 results); results are merged by catalog ID and duplicates are removed.
4. The combined results are presented in local pages of up to 15 items.
5. In multi-select mode, use Space to toggle results and Enter to confirm the page. Choose next/previous page to continue; selections are accumulated across pages.
6. Choose **Finish selection** when ready to process the accumulated results.
7. Duplicate URLs are ignored while preserving selection order, and a single quality choice is applied to the selected batch.
8. In batch album workflows (album/artist search with `--select`, artist catalog expansion, or multiple supplied URLs), selected albums download all tracks. There is no second per-album track-selection prompt.
9. A single album URL with `--select` still allows choosing individual tracks.
10. For artist search with `--select`, each selected artist is expanded into albums and music videos. The configured artist-folder template is resolved per artist so results remain grouped correctly.

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


## Playlist organization

Playlist entries are handled as individual songs, not as tracks belonging to one synthetic playlist album. Each song is resolved through its canonical Apple Music album and saved with that album's metadata and artwork in its normal artist/album directory. The playlist's title and cover are not applied to individual tracks.

## Desktop and catalog retrieval

- Native Intel macOS SwiftUI app with a focused search, download queue, activity log and preferences UI.
- CN-first Apple Music catalog search with HK/TW/SG/US fallbacks and deduplicated results.
- Optional Tencent Hunyuan search enhancement proposes alternate catalog query phrases; Apple Music remains the source of truth.
- Playlist tracks are resolved individually and saved with their original album metadata and artwork.

## Desktop 0.1.6

- Search supports Apple Music playlists, record labels and curators in addition to albums, songs and artists.
- Playlist discovery merges TW, HK and US catalogues; playlist tracks are resolved against CN by shared catalog ID first, then exact title/artist search, with source-storefront fallback when CN has no exact match.
- The native macOS queue persists individual jobs and history, supports pause/resume, retry per failed item, retry all failed items and removal of queued jobs.
- The supplied Qing Hongwu autumn landscape artwork is bundled as a low-contrast ambient interface background.
