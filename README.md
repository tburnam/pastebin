<p align="center">
  <img src="pastebinicon.png" width="128" height="128" alt="PasteBin icon">
</p>

<h1 align="center">PasteBin</h1>

<p align="center">
  A free, open-source clipboard manager for macOS.<br>
  I built this because I paid for one for years, and there's no reason to.
</p>

<p align="center">
  <a href="https://github.com/tburnam/pastebin/releases/latest/download/PasteBin-latest.dmg">
    <img src="https://img.shields.io/badge/Download-PasteBin.dmg-blue?style=for-the-badge&logo=apple" alt="Download PasteBin">
  </a>
</p>

<p align="center">
  <img width="854" alt="PasteBin screenshot" src="https://github.com/user-attachments/assets/890c431c-5d5c-407a-893d-febbe3219a8f" />
</p>

<p align="center">
  <a href="https://github.com/tburnam/pastebin/releases/latest"><img src="https://img.shields.io/github/v/release/tburnam/pastebin?label=latest&style=flat-square" alt="Latest Release"></a>&nbsp;
  <a href="https://github.com/tburnam/pastebin/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/tburnam/pastebin/build.yml?style=flat-square&label=build" alt="Build"></a>&nbsp;
  <a href="https://github.com/tburnam/pastebin/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/tburnam/pastebin/test.yml?style=flat-square&label=tests" alt="Tests"></a>&nbsp;
  <a href="https://github.com/tburnam/pastebin/blob/main/LICENSE"><img src="https://img.shields.io/github/license/tburnam/pastebin?style=flat-square" alt="License"></a>
</p>

---
## Features

[Download](https://github.com/tburnam/pastebin/releases/latest/download/PasteBin-latest.dmg)

- Stores every copied item in a local sqlite database
- Configurable hotkey to summon the paste stack (default `⌥` +  `\`)
- Per-card app icon, character count, and content preview
- Fast fuzzy search, keyboard-first navigation
- macOS 14+

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Left` / `Right` | Move selection |
| `Enter` | Copy selected item and close |
| `Cmd+1` ... `Cmd+9` | Pick first 9 results |
| Type anything | Fuzzy search |
| `Backspace` | Edit query, or delete selected item |
| `Esc` | Clear query, or close |

## Privacy

All data stays on your Mac. No network, no accounts, no telemetry.

---

## Development

**Requirements:** macOS 14+, Xcode CLI Tools, Swift 6.2+

```bash
swift run          # run from source
swift test         # run tests
./release.sh       # build, sign, notarize locally
./release.sh --publish --minor   # ^ + GitHub release with version bump
```
