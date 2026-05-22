# Tomo

A native macOS e-book library manager. Single-user, local-first. Native handling of language variants and a first-class Kindle delivery workflow.

![Tomo](https://github.com/user-attachments/assets/879c454b-9e31-4662-8811-70f412d2e318)

## What it does

- **Library on disk, not in a database.** `Library/Author/Title (Year)/book.epub` plus a sidecar `metadata.json`. Survives the app being deleted; works inside iCloud Drive.
- **Language variants are first-class.** Weighted-marker classifier per profile (`pt-PT` vs `pt-BR`, `en-GB` vs `en-US`, etc.), badges, bulk re-classify, manual override always wins.
- **Send to Kindle over USB.** EPUB→AZW3 conversion happens in-app — no Amazon round-trip, no Send-to-Kindle bundle, no `ebook-convert`. The writer is its own Swift package: [swift-azw3](https://github.com/pdrbrnd/swift-azw3).
- **Sources are JS plugins.** Search external book catalogues from inside the app. Project Gutenberg ships bundled; see [docs/plugins.md](docs/plugins.md) for authoring your own.
- **Open Library cover lookup** by ISBN, paste, or file picker.
- **Duplicate detection** (title + author fuzzy match), format preference (EPUB > AZW3 > MOBI > PDF).

## Install

```sh
brew install --cask pdrbrnd/tap/tomo
```

Requires macOS 26+.

## Build from source

```sh
git clone https://github.com/pdrbrnd/tomo
cd tomo
open Tomo.xcodeproj
```

Xcode resolves Swift package dependencies on first build. `⌘R` to run.

CLI:

```sh
xcodebuild -project Tomo.xcodeproj -scheme Tomo -configuration Debug build
xcodebuild -project Tomo.xcodeproj -scheme Tomo -destination 'platform=macOS' test
```

## Release

Pushing a tag matching `vX.Y.Z` (or `vX.Y.Z-foo` for pre-releases) to `origin` triggers `.github/workflows/release.yml`, which does the rest:

1. Archives at Release config, signs with Developer ID, notarizes, staples
2. Builds a DMG with `create-dmg`
3. Signs the DMG with the Sparkle ed25519 key
4. Creates a GitHub Release with auto-generated notes and attaches the DMG + SHA256
5. Appends an `<item>` to `docs/appcast.xml` and rewrites `docs/index.html`'s download link, commits to `main`
6. Bumps `version` and `sha256` in `pdrbrnd/homebrew-tap` `Casks/tomo.rb`

```sh
git tag v1.5.0
git push origin v1.5.0
```

## Plugins

Tomo's source-search system loads plugins from `~/Library/Application Support/com.pdrbrnd.tomo/plugins/`. Project Gutenberg ships bundled and is seeded on first launch.

See [docs/plugins.md](docs/plugins.md) for the contract and host API. The bundled `gutenberg.js` is the canonical example.

## License

[AGPL-3.0](LICENSE).
