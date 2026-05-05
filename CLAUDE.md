# CLAUDE.md

## What this is

A native macOS e-book library manager. SwiftUI app, single-user, local-first.
The library folder lives wherever the user puts it (possibly iCloud Drive);
the app's internal state never does.

The pitch: a minimal and well-designed macOS app that handles language variants 
natively and treats device delivery as a first-class workflow.

## What this is NOT

- Not an e-book reader (no in-app reading)
- Not a sync service (single-user, single-Mac)
- Not a Calibre clone (no plugin ecosystem, no news, no server mode)
- Not a DRM tool (out of scope; books arrive DRM-free or they don't arrive)

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
   `Library/Author/Title (Year)/book.epub`. Human-readable. Survives the
   app being deleted. Sidecar `metadata.json` per book for fields the EPUB
   format doesn't natively hold.

2. **The SQLite index is disposable.** Stored outside the library folder
   at `~/Library/Application Support/[app-bundle-id]/index.db`. Never in
   iCloud (SQLite + cloud sync = corruption). Rebuild from disk on demand.

3. **iCloud Drive is supported, not promoted.** The library folder may live
   in iCloud. Use `NSFileCoordinator` for reads/writes. Detect `.icloud`
   placeholder files and handle eviction gracefully. Never assume eager
   access to file contents.

4. **Manual override always wins.** Anywhere we classify, detect, or guess
   (language, duplicates, metadata), the user's explicit choice is final
   and persisted.

5. **No network calls without user action.** Metadata fetches, cover lookups,
   etc. are explicit clicks, never background.

6. **No external binary dependencies in v1.** Everything ships in the app
   bundle as Swift code or pure-Swift packages. No shelling out to
   `ebook-convert`, `pandoc`, or anything else.

## Tech stack

- Swift 6.0 / SwiftUI, macOS 26+ target (`MainActor` default isolation)
- GRDB for SQLite
- ZIPFoundation for EPUB reading (EPUB is just zip + XML)
- Native `FileManager` + `NSFileCoordinator` for file ops
- No external binaries. No Python. No bundled apps.

Avoid: heavy frameworks, async libraries beyond Swift Concurrency, anything
that isn't pulling its weight.

Fast and snappy is not negotiable:
- Background everything that touches disk
- Don't trigger iCloud downloads accidentally
- Index SQLite columns you'll search on
- Use LazyVStack/List with stable IDs

## Folder layout (in-app)

```
Tomo/
  App/                    # @main, app lifecycle, settings
  Views/                  # SwiftUI views, one per file
  Models/                 # plain structs: Book, BookOrigin, LanguageProfile
  Core/
    Library/              # library folder operations
    Index/                # SQLite index (GRDB)
    Metadata/             # EPUB parsing, sidecar I/O, EPUBSource
    Classifier/           # language profile engine
    Delivery/             # Kindle USB driver
    Conversion/           # EPUB→AZW3 writer + adapter layer
      AZW3/               # standalone-package-shaped AZW3 writer
  Resources/
    Profiles/             # bundled language profile JSON files
```

The `Conversion/AZW3/` subdirectory is destined for extraction into a
standalone Swift package. Nothing in there may import or reference any
Tomo type — see `Tomo/Core/Conversion/AZW3/README.md`.

## Data model

Models live in `Tomo/Models/`. Read those files for the current
shapes (`Book.swift`, `LanguageProfile.swift`). The sidecar
`metadata.json` mirrors `Book` minus `id` (id lives in the index).

Two intent notes the code can't express:

- `BookOrigin` is in v1 even though sources are v2. Every v1-imported
  book is `.manualImport`. This avoids a migration when sources ship.
- `Book` has a single `fileURL` (primary file) — multi-format-per-book
  (`formats: [BookFormat]`) is deferred until v2 sources need it. The
  `FileFormat` enum in `Tomo/Core/Conversion/` is unrelated; it's
  the conversion layer's format identifier, not a data-model type.

## Language profiles — intent

Not "pt-PT detection." A general system: weighted-marker classifier per
profile, profiles grouped by base language. Implementation lives in
`Tomo/Core/Classifier/` — read `Classifier.swift` and the bundled
profiles in `Resources/Profiles/` for current shape.

The principle to preserve: **manual user override is persisted and
never overwritten.** Bulk re-classify is a deliberate user action; the
system never silently changes a locale the user has already accepted.

For non-EPUB formats: classifier doesn't reach into MOBI/AZW3/PDF
contents. Books in those formats either get a manually-set locale or
sit at `und` (the BCP 47 "undetermined" tag).

## Sources — v2 concept

v2 will add a sources system for searching external book catalogues
(public catalogues, e-book stores, OPDS feeds, etc.) from inside the app.
See `docs/sources.md` for the motivation, protocol shape, and design
notes. Not a v1 concern beyond the `BookOrigin` field on `Book`.

## v1 scope (in priority order)

1. Library: import, organise, browse (grid + list), search, edit metadata (incl. language profile and cover), delete
2. Language profiles: classification on import (when EPUB doesn't declare a full locale), badges, bulk re-classify
3. Cover art editing: paste, file picker, fetch from Open Library by ISBN
4. Duplicate detection: title+author fuzzy match, format preference (EPUB > AZW3 > MOBI > PDF), manual merge UI
5. Kindle delivery: USB sideload, with EPUB→AZW3 conversion done in-app (no Amazon-server round-trip)

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

**File relocation on edit:** Editing title/authors/year does *not* move the
book's files on disk in v1 — the `Author/Title (Year)/` folder name may
drift from the metadata after edits. Harmless for the index; worth fixing
later (rename folders to match new metadata on save).

## Conversion

EPUB→AZW3 (KF8) is implemented in-app under `Tomo/Core/Conversion/`.
The writer half lives in `AZW3/` as a self-contained module ready for
extraction into a standalone Swift package. Phases 1 and 2 hardware-validated
2026-05-03 — cover, TOC NCX, CSS flows, body images all shipped. See
`docs/azw3_phase2.md` for the explicitly-deferred list (PalmDoc compression,
older-firmware thumbnail hack, etc.). We do not bundle Calibre, KindleGen, or
Amazon's Send to Kindle Mac app, and we don't route through SMTP /
Amazon servers.

## v2 (later, not now)

- Sources system (see `docs/sources.md`)
- Reading progress sync from `My Clippings.txt`
- Collections / saved searches
- Series support
- Library subset export

## Out of scope (don't add without discussion)

- DRM removal of any kind
- In-app reading
- Multi-device sync logic beyond "iCloud folder works fine"
- Plugin system (sources are Swift files in the repo, not user-installable plugins)
- News / RSS / feed fetching (Calibre-style)
- iOS companion app

## Architectural layers

The codebase has three loose layers. Files should sit clearly in one.

**Models (`Models/`).** Plain structs. `Codable` where they cross the disk
boundary. No SwiftUI imports, no business logic beyond data shape. `Book`,
`BookOrigin`, `LanguageProfile`.

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

- Error handling: typed errors at module boundaries (`enum LibraryError`),
  not `throws Error`.
- Logs via `os.Logger`, one logger per subsystem.
- Tests: Swift Testing (`@Test`, `#expect`), focus on the classifier and
  the file-organisation logic. UI tests are not worth the maintenance for v1.
  Test target not scaffolded yet — added when the first thing worth testing
  exists.

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
- **CLI build:** `xcodebuild -project tomo.xcodeproj -scheme tomo -configuration Debug build`
- **CLI test:** `xcodebuild -project tomo.xcodeproj -scheme tomo -destination 'platform=macOS' test`
- **Bundle ID:** `com.pdrbrnd.tomo` (used for `~/Library/Application Support/com.pdrbrnd.tomo/`).
- **Deployment target:** macOS 26.0.
- **Swift language mode:** 6.0 (strict concurrency; types default to `MainActor` isolation).
- **Sandbox:** off. Distribution path is Homebrew cask, not Mac App Store. Signing/notarization deferred until distribution is a concern.
- **Dependencies:** added via Xcode → File → Add Package Dependencies (SwiftPM-resolved into the project).

## Known unknowns to flag, not solve silently

- Open Library API rate limits and metadata quality vary. Treat fetched
  metadata as a suggestion, never auto-apply.
- Kindle firmware behaviour around AZW3 indexing is empirically
  verified per device, not by spec. The current writer was validated
  on FW 5.19.2 (Paperwhite Signature) on 2026-05-03; if a future
  firmware tightens validation, expect the spike's Phase 2 work to
  surface here first.
