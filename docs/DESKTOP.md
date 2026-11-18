# AMDL Desktop (macOS)

AMDL Desktop is a small native SwiftUI front end for the existing AMDL command-line engine. It has no Electron or Node.js runtime.

## Features

- Paste one or many Apple Music album, song, artist or playlist URLs.
- Open Apple Music search in the browser, then paste the selected catalog links.
- Select ALAC, Dolby Atmos or AAC.
- Start a batch and watch the downloader's live output.
- Open the configured music folder or YAML settings file.

## Build

```sh
go build -trimpath -o /tmp/amdl .
mkdir -p "AMDL Desktop.app/Contents/MacOS" "AMDL Desktop.app/Contents/Resources"
swiftc -O -target x86_64-apple-macosx13.0 -framework SwiftUI -framework AppKit \
  desktop/AMDLDesktop.swift -o "AMDL Desktop.app/Contents/MacOS/AMDLDesktop"
cp /tmp/amdl "AMDL Desktop.app/Contents/Resources/amdl"
```

Create `AMDL Desktop.app/Contents/Info.plist` with `CFBundleExecutable=AMDLDesktop`, `CFBundleIdentifier=org.zcy314.amdl.desktop`, `CFBundleName=AMDL Desktop`, `CFBundlePackageType=APPL`, and `LSMinimumSystemVersion=13.0`.

The app expects the existing configuration at `~/Music/AppleMusic/config.yaml` and uses `~/Music/AppleMusic` as its working directory. The CLI remains available independently.

## Playlist organization

A playlist is treated as a list of individual catalog songs. For each selected entry, AMDL resolves the song's canonical album and delegates to the normal single-song album path. The downloaded file therefore receives the original album metadata and artwork and is saved in the corresponding artist/album folder. The playlist title and playlist cover are not written as the song's album metadata.
