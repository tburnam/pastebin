# PasteBin (macOS menu-bar clipboard bin)

A SwiftUI + AppKit menu-bar app that captures clipboard history into SQLite and presents a glass-style picker panel.

## Features

- Menu-bar icon with `Open` and `Quit`
- Clipboard monitoring with persistence in `~/Library/Application Support/PasteBin/clipboard.sqlite`
- Bottom-up animated panel presentation
- Glass-style translucent UI with card-based clipboard items
- Per-card app icon and character count
- Keyboard-first interaction:
  - `Left/Right` arrows to move selection
  - `Enter` to copy selected item and close
  - `Cmd+1...Cmd+9` to instantly pick first 9 results
  - Type to fuzzy-search instantly
  - `Backspace` to remove query chars
  - `Esc` clears query (or closes when query is empty)

## Requirements

- macOS 14 or later
- Xcode command line tools or a full Xcode install
- `create-dmg` for DMG packaging

## Run

```bash
swift run
```

## Build A Release

```bash
./release.sh
```

That script will:

- build the release binary
- generate a Retina-ready `AppIcon.icns` from `pastebinicon.png`
- assemble `dist/PasteBin.app`
- ad hoc sign the bundle by default so the packaged app is internally consistent
- create a drag-to-Applications DMG in `dist/`
- refresh `dist/PasteBin.app.zip`

If you have a Developer ID signing identity, you can override the default ad hoc signature:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./release.sh
```

## Install

Open the generated DMG and drag `PasteBin.app` into `Applications`.

## Notes

- If your machine only has Command Line Tools configured, point `xcode-select` at a full Xcode installation.
- Sharing the app outside your own machine is much smoother with Developer ID signing and notarization. The script supports signing; notarization still needs to be done separately.
