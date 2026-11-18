# AMDL Desktop (macOS)

AMDL Desktop is a lightweight native SwiftUI interface around the existing Go download engine. It has no Electron, Chromium, Node.js runtime, database daemon, or always-on background service. The target for this build is Intel macOS (x86_64).

## Product principles

- A playlist is a list of individual songs. Each song resolves its canonical Apple Music album and is downloaded through the original album path, preserving its own album title, artwork, artist, release date, and track number. The playlist title and playlist artwork are not used as album metadata.
- CN is the primary storefront. Album search checks CN first, then HK, TW, SG, and US; the result URL retains its original storefront.
- Search results can be selected and added to a download queue. The queue also accepts pasted Apple Music URLs.
- ALAC, Dolby Atmos, and AAC are supported. Live output is shown in the Activity view.

## Build (Intel Mac)

```sh
go build -trimpath -o /tmp/amdl .
mkdir -p 'AMDL Desktop.app/Contents/MacOS' 'AMDL Desktop.app/Contents/Resources'
swiftc -parse-as-library -O -target x86_64-apple-macosx13.0 \
  -framework SwiftUI -framework AppKit \
  desktop/AMDLDesktop.swift -o 'AMDL Desktop.app/Contents/MacOS/AMDLDesktop'
cp /tmp/amdl 'AMDL Desktop.app/Contents/Resources/amdl'
```

The app expects `~/Music/AppleMusic/config.yaml` and uses `~/Music/AppleMusic` as its working directory. The CLI remains independently usable.

## GUI search protocol

`amdl --config <path> --search album|song|artist --json-search <query...>` prints catalog results as JSON to stdout; diagnostics go to stderr. This keeps the SwiftUI interface independent of terminal prompts.
