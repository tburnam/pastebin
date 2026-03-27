# PasteBin (macOS menu-bar clipboard bin)

A macOS app to store, search, and access your clipboard history. All the data lives in a sqlite db on your machine.

<img width="1708" height="360" alt="Screenshot 2026-03-23 at 5 58 42 PM" src="https://github.com/user-attachments/assets/890c431c-5d5c-407a-893d-febbe3219a8f" />

## Features

- Stores all of your copied items to a sqlite database for easy reference and access.
- Configurable hotkey access paste stack (default: `⌥ and \`)
- Per-card app icon, character count, and content preview.
- Keyboard-first interaction:
  - `Left/Right` arrows to move selection
  - `Enter` to copy selected item and close
  - `Cmd+1...Cmd+9` to instantly pick first 9 results
  - Type to fuzzy-search instantly
  - `Backspace` edits the query while search is focused, and deletes the selected item after arrow-key navigation
  - `Esc` clears query (or closes when query is empty)
 
I built this becuase I paid for a clipboard manager for years, and there's no reason to pay for software like this anymore. 

## Development

### Requirements

- macOS 14 or later
- Xcode command line tools or a full Xcode install
- `create-dmg` for DMG packaging

### Run

```bash
swift run
```

### Build A Release

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

### Install

Open the generated DMG and drag `PasteBin.app` into `Applications`.

If you share an ad hoc signed build with a teammate, the cleanest internal handoff is the DMG in `dist/`. If Gatekeeper blocks the first launch, have them Control-click `PasteBin.app`, choose `Open`, and confirm once.

### Notes

- If your machine only has Command Line Tools configured, point `xcode-select` at a full Xcode installation.
- Sharing the app outside your own machine is much smoother with Developer ID signing and notarization. The script supports signing; notarization still needs to be done separately.
