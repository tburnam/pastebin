# PasteBin

A macOS app to store, search, and access your clipboard history. All the data lives in a sqlite db on your machine.

<img width="1708" height="360" alt="Screenshot 2026-03-23 at 5 58 42 PM" src="https://github.com/user-attachments/assets/890c431c-5d5c-407a-893d-febbe3219a8f" />

[**Download the latest release**](https://github.com/tburnam/pastebin/releases/latest)

1. Open the DMG and drag `PasteBin.app` into `Applications`.
2. Launch `PasteBin.app`.

All releases are signed and notarized by Apple — no Gatekeeper warnings.

I built this because I paid for a clipboard manager for years, and there's no reason to pay for software like this anymore.

## Highlights

- Stores all copied items to a local sqlite database for easy reference and access
- Configurable hotkey to access paste stack (default: `⌥ and \`)
- Per-card app icon, character count, and content preview
- Fast fuzzy search with keyboard-first navigation
- macOS 14+

## Keyboard Shortcuts

- `Left` / `Right`: move selection
- `Enter`: copy the selected item and close
- `Cmd+1` through `Cmd+9`: pick one of the first nine results
- Type anywhere: search immediately
- `Backspace`: edit the query while search is focused, or delete the selected item after arrow-key navigation
- `Esc`: clear the query, or close the panel when the query is already empty

## Privacy

All data stays on your Mac. Clipboard history is stored in `~/Library/Application Support/PasteBin/clipboard.sqlite`. No network, accounts, or API keys required.

## Development

### Requirements

- macOS 14 or later
- Xcode Command Line Tools or a full Xcode install
- Swift 6.2+

### Run From Source

```bash
swift run
```

### Test

```bash
swift test
```

### Release

```bash
./release.sh            # build, sign, notarize locally
./release.sh --publish  # same + create GitHub release with version bump
```

The `--publish` flag prompts for a semver bump (patch/minor/major), tags, and uploads artifacts to GitHub Releases. Requires `create-dmg` (`brew install create-dmg`) and `gh`.
