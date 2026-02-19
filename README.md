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

## Run

```bash
swift run
```

## Notes

- Requires macOS with Swift toolchain and Xcode SDKs available.
- If your machine only has Command Line Tools configured, point `xcode-select` at a full Xcode installation.
