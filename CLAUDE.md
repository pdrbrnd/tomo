# CLAUDE.md

## What this is

A native macOS e-book library manager. SwiftUI app, single-user, local-first.
The library folder lives wherever the user puts it (possibly iCloud Drive);
the app's internal state never does.

The pitch: a minimal and well-designed macOS app that handles language variants 
natively and treats device delivery as a first-class workflow. Supported
devices: Kindle and Kobo, over USB.

Source plugins (JS files in `~/Library/Application Support/com.pdrbrnd.tomo/plugins/`) are a separate concept — they search external catalogues; they don't extend the app itself.

## Owner / context

Solo project. Strong
preference for simple, readable, maintainable code over clever code. KISS,
YAGNI, flat structure, functional composition where it fits.

## Code is the source of truth

Docs (this file, `docs/`, the skill) describe intent and constraints. Once
something is implemented, the **code** is the source of truth for shape
and behaviour. Read the relevant Swift files before relying on a doc's
description of how something works.

When working on this project:

- If a doc describes a struct or protocol that exists in code, trust the
  code and update the doc if it has drifted.
- If a doc describes a design that has now been built, replace the design
  description with a one-line pointer to where the code lives.
- If you finish implementing something that was previously described in
  detail in a doc (data models, classifier internals, source protocols,
  etc.), prune the detailed description and leave a stub.
- Stale design docs are worse than no design docs. They mislead.

The architectural principles, project scope, and watchouts stay in docs —
those describe *intent*, which the code can't express. Everything else
should migrate to code over time.

## Architectural principles

These are load-bearing. Don't violate them without flagging it.

1. **Library on disk is the source of truth.** Flat folder structure:
   `Library/Author/Title (Year)/<author-title-year>.epub`. The folder
   carries human-readable identity; the file is a kebab-case ASCII slug
   built by `bookFileSlug` so every book has a unique, identity-bearing
   filename — devices like Kindle dedupe by filename, so the legacy
   `book.epub` shape collided on every send. Survives the app being
   deleted. Each book carries a `metadata.json` sidecar with everything
   the index needs (title, authors, locale, collections by name, id,
   etc.) including the on-disk filename. Collection *definitions* (id,
   sortOrder, dateCreated) live in `<library>/.tomo/collections.json`
   so empty collections and sortOrder also survive a rebuild.

2. **The SQLite index is disposable.** Stored outside the library folder
   at `~/Library/Application Support/[app-bundle-id]/index.db`. Never in
   iCloud (SQLite + cloud sync = corruption). Rebuilds entirely from the
   sidecars + `.tomo/collections.json` on demand.

3. **iCloud Drive is supported, not promoted.** The library folder may live
   in iCloud. Use `NSFileCoordinator` for reads/writes. Detect `.icloud`
   placeholder files and handle eviction gracefully. Never assume eager
   access to file contents.

4. **Manual override always wins.** Anywhere we classify, detect, or guess
   (language, duplicates, metadata), the user's explicit choice is final
   and persisted.

5. **No network calls without user action.** Metadata fetches, cover lookups,
   etc. are explicit clicks, never background.

6. **No external binary dependencies.** Everything ships in the app
   bundle as Swift code or pure-Swift packages. No shelling out to
   `ebook-convert`, `pandoc`, or anything else.

## Tech stack

- Swift 6.0 / SwiftUI, macOS 26+ target (`MainActor` default isolation)
- GRDB for SQLite
- ZIPFoundation for EPUB reading (EPUB is just zip + XML)
- SwiftSoup for HTML parsing (used by source plugins' `querySelectorAll` host binding)
- [`AZW3`](https://github.com/pdrbrnd/swift-azw3) — our own SwiftPM package, the EPUB→AZW3 writer
- JavaScriptCore for source plugins (none bundled — installed from registries)
- Native `FileManager` + `NSFileCoordinator` for file ops
- No external binaries. No Python. No bundled apps.

Avoid: heavy frameworks, async libraries beyond Swift Concurrency, anything
that isn't pulling its weight.

Fast and snappy is not negotiable:
- Background everything that touches disk
- Don't trigger iCloud downloads accidentally
- Index SQLite columns you'll search on
- Use LazyVStack/List with stable IDs

## Data model

Models live in `Tomo/Models/`. Read those files for the current shapes
(`Book.swift`, `Collection.swift`, `LanguageProfile.swift`). The sidecar
`metadata.json` carries everything in `Book` *including* `id`, plus the
`collections` array (by name) and a top-level `version` field for future
migrations. See `Tomo/Core/Metadata/MetadataSidecar.swift`.

Disk truth split:

- Per-book sidecar (`metadata.json`): all `Book` fields + collection memberships by name.
- Per-library `<root>/.tomo/collections.json`: collection definitions (id, name, sortOrder, dateCreated). Pairs with sidecar memberships to fully reconstruct the index.

Intent notes the code can't express:

- `BookOrigin` distinguishes manual-import from plugin-sourced books (`.source(id, ref)`). All books imported via a JS plugin's `download()` carry the originating plugin's id.
- `Book` has a single `fileURL` (primary file) — multi-format-per-book (`formats: [BookFormat]`) isn't shipped. The `FileFormat` enum in `Tomo/Core/Conversion/` is the conversion layer's format identifier, not a data-model type.

## Language profiles — intent

Not "pt-PT detection." A general system: weighted-marker classifier per
profile, profiles grouped by base language. Implementation lives in
`Tomo/Core/Classifier/` — read `Classifier.swift` and the bundled
profiles in `Resources/Profiles/` for current shape.

For non-EPUB formats: classifier doesn't reach into MOBI/AZW3/PDF
contents. Books in those formats either get a manually-set locale or
sit at `und` (the BCP 47 "undetermined" tag).

## Sources

External book search runs through JavaScript plugins loaded from `~/Library/Application Support/com.pdrbrnd.tomo/plugins/`. **No plugins ship with the app** — fresh installs have library search only until the user opens Settings → Plugins and installs from a registry. The default registry is hardcoded to `pdrbrnd/tomo-plugins` on GitHub; users can add third-party registry URLs. Drop-install (`.js` file directly into the folder) still works for power users; their bytes are their problem.

There's no install ledger. Whether a plugin is "from the official registry" is derived on the fly: the file's sha256 matches some cached registry entry's sha256. No match → user-supplied. Update available → registry has matching id with a different sha + compatible `minAppVersion`.

The contract and host bindings (fetch, querySelectorAll, cacheImage, console) are documented in `docs/plugins.md`; host capabilities per app version live in `docs/CONTRACT.md`. Source-of-truth shapes live in `Tomo/Core/Plugins/`. Multi-plugin search runs each enabled plugin in turn; per-plugin enable/disable in the sources popover (quick-toggle during search) or Settings → Plugins (full management), persisted in `UserDefaults`.

## Format support

Imports go through `LibraryImporter`, which dispatches by file extension and reads metadata via the matching reader. The accepted set is `LibraryImporter.acceptedExtensions` — currently `epub` and `pdf`. Adding a format means adding a `<Format>Metadata.swift` reader that produces an `ImportedFileMetadata` and a case in `readMetadata`.

Per-format notes:

- **EPUB** — full path: metadata, cover, language classification on import.
- **PDF** — `/Info` for title/author/year (with junk-title detection — Word's "Microsoft Word - foo.docx" gets thrown out for the filename), first page rendered as JPEG cover at 600px long-side. No language classification (PDFs don't carry a reliable tag); locale lands at `und` unless the user sets it.

Once a book is in the library, AZW3 / MOBI / PDF can be sideloaded to a Kindle via passthrough; only EPUB triggers the in-app conversion path. Kobo accepts EPUB and PDF directly — no conversion. Drop overlay surfaces the accepted set; non-accepted drops surface a toast and are silently dropped.

## Editing model

Every field on a `Book` is editable through one Edit UI. There is no hidden
"this was auto-set vs manual" state — what's in the sidecar (and the index)
is what the user has accepted.

**Language profile, specifically:**

- On import, if the EPUB declares a full locale (`pt-BR`, `en-GB`, etc.) that
  matches a known profile, trust it and skip classification. The classifier
  exists for cases where the EPUB declares only a base language or none.
- Re-classify is always a deliberate user action — per-book (button in the
  Edit dialog) or bulk (menu action with explicit warning). It overwrites
  whatever's currently set.
- No lock flag. If a user manually corrects a profile and later runs bulk
  re-classify, the manual fix is lost. That's the trade for not carrying
  hidden override state. Bulk re-classify is rare; an explicit warning at
  the action point is enough.

**One language field.** `Book.locale` is a BCP 47 string (per RFC 5646 and
EPUB's `<dc:language>`) — the single source of truth. It holds whatever the
user has accepted: a profile id ("pt-PT"), a bare base code ("pt") when no
profile fits or the EPUB only declared a base, or "und". Profiles exist as
classification infrastructure (marker JSON + scorer); they are not a separate
field on `Book`. Display labels are derived from the BCP 47 tag via Apple's
`Locale.localizedString(forIdentifier:)` — free localization, no hardcoded
labels in JSON.

**Confidence is not persisted.** The classifier produces a confidence score,
but it's only meaningful at the moment of classification. Once a locale is
set, the user has either accepted it (no edit) or fixed it (edit). The
number stops carrying signal. So:

- At import time, classifier output is applied **only when confidence ≥
  threshold (0.6)** — below that, the classifier is essentially guessing
  between variants and we leave the locale at the EPUB's declared base
  rather than commit a coin-flip variant.
- In the Edit dialog, "Re-classify from text" surfaces the confidence
  transiently next to the picker so the user can judge whether to keep it.
  The number isn't saved.

**File relocation on edit:** Editing title / first author / year *does*
move the book on disk. `AppState.updateBook` calls
`relocateBookFolderIfChanged` (folder: `<library>/<Author>/<Title (Year)>/`)
then `renamedToSlugIfChanged` (file: `<author>-<title>[-<year>].ext`) so
the on-disk layout stays consistent with the metadata — Principle 1
(library on disk is the source of truth). Empty author folders are pruned
up to (but never including) the library root. Disk moves roll back if the
sidecar / index write fails. Collisions (target folder already exists)
are refused, not merged.

## Conversion

EPUB→AZW3 (KF8) is delegated to the [`AZW3`](https://github.com/pdrbrnd/swift-azw3) SwiftPM package (our own — extracted from this repo). Tomo's `EPUBToAZW3Converter` (in `Core/Conversion/`) is just the adapter that builds a `BookManifest` from an EPUB on disk and feeds it to `AZW3Writer`. Hardware-validated on Kindle Paperwhite Signature, FW 5.19.2.

For Kindle home-screen covers, the writer's EXTH 201 alone isn't enough on most current firmwares — the home-screen scanner pulls covers from `system/thumbnails/thumbnail_<ASIN>_EBOK_portrait.jpg`. `Core/Delivery/KindleCoverThumbnail.swift` writes that file alongside the AZW3 copy. ASIN comes from `AZW3Writer.asin` (deterministic in the manifest); the JPEG is resized to 500px tall via ImageIO.

We do not bundle Calibre, KindleGen, or Amazon's Send to Kindle Mac app, and we don't route through SMTP / Amazon servers.

## Device drivers

Each device implements `BookDevice` (`Core/Delivery/BookDevice.swift`); the library and UI only ever talk to that protocol. `DeviceScanner.detect()` scans `/Volumes` and tries each driver's failable init in order.

- **Kindle** (`Core/Delivery/Kindle.swift`): identified by `documents/` + `system/` at the volume root. Writes books to `documents/`. EPUB needs conversion (see above); AZW3/MOBI/PDF passthrough.
- **Kobo** (`Core/Delivery/Kobo.swift`): identified by `.kobo/` at the volume root (contains `KoboReader.sqlite`, present on every Kobo from Touch onwards). Writes books to the volume root — Kobo's scanner walks the whole device on disconnect. EPUB and PDF passthrough; no conversion, no cover-thumbnail workaround (Kobo extracts covers from EPUB metadata natively).

**Metadata projection on delivery.** Devices read the file's *embedded* metadata, not Tomo's sidecar, so the user's edited title/author/language is projected onto the **delivered copy** at send time — the library file is never mutated (sidecar stays canonical; Principle 1). Kindle gets it for free: `EPUBToAZW3Converter` takes an `EPUBSource.MetadataOverride` built from the `Book` and the `AZW3Writer` serialises it. Kobo (raw EPUB passthrough) needs an actual OPF rewrite: `Core/Metadata/EPUBMetadataWriter.metadataCorrectedCopy` produces a scratch copy with the differing `<dc:*>` fields overwritten, sent in place of the original. It's **diff-only** (untouched authors keep their `opf:file-as`/role) and **best-effort** (DRM/malformed/no-diff → returns nil → original sent untouched). Scope is title/author/language only — no `file-as` synthesis. An opt-in "embed metadata into library files" action (Calibre-style) is deliberately out of scope.

## Out of scope (don't add without discussion)

- DRM removal of any kind
- Multi-device sync logic beyond "iCloud folder works fine"
- News / RSS / feed fetching (Calibre-style)
- iOS companion app

## Architectural layers

The codebase has three loose layers. Files should sit clearly in one.

**Models (`Models/`).** Plain structs. `Codable` where they cross the disk
boundary. No SwiftUI imports, no business logic beyond data shape. `Book`,
`BookOrigin`, `Collection`, `LanguageProfile`.

**Core (`Core/`).** The work the app does. File I/O, parsing, classifying,
indexing, delivering. Pure-Swift modules with no SwiftUI dependency. Each
subfolder is one concern. Functions and `@Observable` services live here.
This is where `async` lives.

**Views (`Views/`).** SwiftUI. Reads from Core, displays state, dispatches
actions back. No file I/O, no JSON decoding, no business logic. A view's
job is to render and to call.

If a file imports both `SwiftUI` and `GRDB`, that's a smell. The view
shouldn't know the index is SQLite.

## Coding conventions

For all Swift and SwiftUI work, read `.claude/skills/swiftui/SKILL.md` and
its references. The skill is the source of truth for idiomatic modern
Swift: state management, concurrency, view composition, API design.

Project-specific additions on top of the skill:

- Error handling: typed errors at module boundaries (`enum LibraryError`), not `throws Error`.
- Logs via `os.Logger`, one logger per subsystem.
- Tests: Swift Testing (`@Test`, `#expect`) under `TomoTests/`. Focus on the classifier, sidecar/index round-trips, and file-organisation logic. UI tests aren't worth the maintenance.

## Project-specific watchouts

These are the easy ways to drift from the architectural principles above.
Worth flagging in code review:

- **Index treated as source of truth.** Writing to SQLite without writing
  the sidecar. Trusting the DB over disk. Principle 1: disk is truth.
- **Accidental iCloud downloads.** Reading file *contents* (not just
  listing names) on launch triggers downloads of evicted files. Read
  `metadata.json` sidecars eagerly; never the EPUB itself unless asked.
- **Folder layout drift.** `Library/Author/Title (Year)/` is the contract.
  Any code that reads or writes a different shape breaks the "library
  survives the app" principle.
- **Classifier creep.** A weighted-marker scorer is the design. CoreML,
  transformers, Apple's `NLLanguageRecognizer` for variant detection —
  wrong tool. NSLinguisticTagger or similar is fine for *base* language
  detection only.
- **Network calls without user action.** Cover fetches, metadata lookups,
  anything to Open Library — must be triggered by an explicit click.
  Principle 5.
- **External binaries.** No shelling out to `ebook-convert`, `pandoc`, or
  anything else. Principle 6.

## Build / run

Single Xcode project, no Swift Package Manager wrapping. Source lives
under `Tomo/`, the project file is `Tomo.xcodeproj/` at repo root.
Tests live under `TomoTests/`.

- **Open in Xcode:** `open Tomo.xcodeproj` then `⌘R` to build and run.
- **CLI build:** `xcodebuild -project Tomo.xcodeproj -scheme Tomo -configuration Debug build`
- **CLI test:** `xcodebuild -project Tomo.xcodeproj -scheme Tomo -destination 'platform=macOS' test`
- **Bundle ID:** `com.pdrbrnd.tomo` (used for `~/Library/Application Support/com.pdrbrnd.tomo/`).
- **Deployment target:** macOS 26.0.
- **Swift language mode:** 6.0 (strict concurrency; types default to `MainActor` isolation).
- **Sandbox:** off. **Signing:** Developer ID Application, manual signing, Hardened Runtime on (Release config). Team is Significa. Distribution path is Homebrew cask via `pdrbrnd/homebrew-tap`.
- **Releases:** push tag `vX.Y.Z` → `.github/workflows/release.yml` archives, signs, notarizes, staples, builds DMG, attaches to GitHub Release. Tap cask is updated manually per release (auto-bump is a v1.1 backlog item — see plan file).
- **Dependencies:** added via Xcode → File → Add Package Dependencies (SwiftPM-resolved into the project).

## Known unknowns to flag, not solve silently

- Open Library API rate limits and metadata quality vary. Treat fetched metadata as a suggestion, never auto-apply.
- Kindle firmware behaviour around AZW3 indexing and home-screen covers is empirically verified per device, not by spec. The writer + thumbnail-folder write are validated on FW 5.19.2 (Paperwhite Signature). If a future firmware tightens validation or stops honoring the thumbnail folder (Amazon has reportedly leaned toward overwriting sideloaded thumbnails over Wi-Fi on some firmwares), expect the issue to surface in `swift-azw3` or `Core/Delivery/KindleCoverThumbnail.swift` first.
