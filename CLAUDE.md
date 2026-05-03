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
- Not a format converter (see "Conversion is deferred" below)

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

## Conversion is deferred

We considered building format conversion in. We're not, for v1. The reasoning:

- Kindle's Send to Kindle service now accepts EPUB, PDF, DOC, DOCX, TXT,
  RTF, HTM, HTML, PNG, GIF, JPG, JPEG, BMP natively (since late 2022).
- Most books in the wild — especially from non-store sources — are EPUB.
- The realistic conversion landscape is bleak: no clean, embeddable,
  permissively-licensed library exists. Calibre's `ebook-convert` is the
  de facto standard but is GPLv3, ~500MB, and Python+Qt. Pandoc is MIT
  but doesn't write MOBI/AZW3. Amazon's KindleGen was discontinued in 2020.
- Deferring means v1 ships without a 500MB dependency or a Calibre install
  prerequisite.

For v1, the app passes files through as-is. If a user hits a format the
Kindle can't handle, they convert externally for that one book. We'll
revisit conversion in v2 with real data on how often it actually matters.

## Tech stack

- Swift 5.9+ / SwiftUI, macOS 14+ target
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
BookLib/
  App/                    # @main, app lifecycle, settings
  Views/                  # SwiftUI views, one per file
  Models/                 # plain structs: Book, Author, LanguageProfile, etc.
  Core/
    Library/              # library folder operations
    Index/                # SQLite index (GRDB)
    Metadata/             # EPUB parsing, sidecar I/O
    Classifier/           # language profile engine
    Delivery/             # Kindle USB + email
    Sources/              # external book sources (v2; empty in v1)
  Resources/
    Profiles/             # bundled language profile JSON files
```

## Data model (working draft)

```swift
struct Book {
    let id: UUID
    var title: String
    var authors: [String]      // first author drives folder layout
    var year: Int?
    var languageCode: String   // ISO 639-1: "pt", "en", "es"
    var languageProfileId: String?  // e.g. "pt-PT", "en-GB"
    var languageConfidence: Double?  // 0.0–1.0
    var tags: [String]
    var formats: [BookFormat]  // multiple files for the same logical book
    var coverPath: String?     // relative to book folder
    var dateAdded: Date
    var fileURL: URL           // primary file, used for ops
    var origin: BookOrigin     // where this book came from
}

enum BookOrigin: Codable, Equatable {
    case manualImport                      // user dropped or picked the file
    case source(id: String, ref: String?)  // external source + provider-specific id
}

struct BookFormat {
    let ext: String            // "epub", "pdf", "azw3"
    let path: String           // relative to book folder
    let sizeBytes: Int
}

struct LanguageProfile {
    let id: String             // "pt-PT", "pt-BR", "en-GB", etc.
    let label: String          // user-facing
    let baseLanguage: String   // "pt", "en"
    let markers: [Marker]
}

struct Marker {
    let pattern: String        // word, phrase, or regex
    let isRegex: Bool
    let weight: Double         // can be negative
}
```

The sidecar `metadata.json` mirrors `Book` minus `id` (id lives in the index).

`BookOrigin` is included in v1 even though sources land in v2. Every
v1-imported book is `.manualImport`. This avoids a migration when sources
ship.

## Language profiles — the generic mechanism

Not "pt-PT detection." A general system: weighted-marker classifier per
profile, profiles grouped by base language. Detection flow:

1. Detect base language from sample text (small Swift port of franc-style
   trigram matching, or NSLinguisticTagger as a starting point)
2. All profiles matching that base language score the sample
3. Highest score wins, with a confidence value
4. Manual user override is persisted and never overwritten

Ship four profiles in v1: `pt-PT`, `pt-BR`, `en-GB`, `en-US`. Profile JSON
files live in `Resources/Profiles/` and are user-editable (eventually
copyable to `~/Library/Application Support/[app]/Profiles/`).

Sample size: first ~5000 words of extracted text. Extraction:
- EPUB: read native (it's zip + XHTML, ZIPFoundation handles it)
- PDF: PDFKit (built-in)
- MOBI/AZW3: skip in v1 — most non-Amazon books are EPUB anyway. If a
  user has a MOBI/AZW3 they want classified, they classify by hand or it
  goes in unclassified. Document this clearly.

## Sources — v2 concept

v2 will add a sources system for searching external book catalogues
(public catalogues, e-book stores, OPDS feeds, etc.) from inside the app.
See `docs/sources.md` for the motivation, protocol shape, and design
notes. Not a v1 concern beyond the `BookOrigin` field on `Book`.

## v1 scope (in priority order)

1. Library: import, organise, browse (grid + list), search, edit metadata, delete
2. Language profiles: classification on import, badges, manual override, bulk re-classify
3. Cover art editing: paste, file picker, fetch from Open Library by ISBN
4. Duplicate detection: title+author fuzzy match, format preference (EPUB > AZW3 > MOBI > PDF), manual merge UI
5. Kindle delivery: USB (mount detection, copy to `documents/`, eject) + Send to Kindle email

Send to Kindle is simple now that Amazon accepts EPUB natively: SMTP +
attachment. Including it in v1 because the official Send to Kindle Mac app
is required for USB on 2024+ Kindles anyway, so email is the cleaner
uniform path across all Kindle generations.

## v2 (later, not now)

- Sources system (see "Sources — v2 concept" above)
- Conversion (revisit with real data on which formats users actually hit)
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
`BookFormat`, `LanguageProfile`.

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

Single Xcode project, no Swift Package Manager wrapping.

```
Tinta.xcodeproj/   # at repo root
Tinta/             # source folder
  TintaApp.swift
  ContentView.swift
  Assets.xcassets/
```

- **Open in Xcode:** `open Tinta.xcodeproj` then `⌘R` to build and run.
- **CLI build:** `xcodebuild -project Tinta.xcodeproj -scheme Tinta -configuration Debug build`
- **Bundle ID:** `com.pdrbrnd.tinta` (used for `~/Library/Application Support/com.pdrbrnd.tinta/`).
- **Deployment target:** macOS 26.0.
- **Swift language mode:** 6.0 (strict concurrency; types default to `MainActor` isolation).
- **Sandbox:** off. Distribution path is Homebrew cask, not Mac App Store. Signing/notarization deferred until distribution is a concern.
- **Dependencies:** added via Xcode → File → Add Package Dependencies (SwiftPM-resolved into the project).

## Known unknowns to flag, not solve silently

- Newer Kindles (Scribe, 2024+ models) require Amazon's Send to Kindle
  Mac app for USB transfer; older Kindles still mount as mass storage.
  Detect both cases. The user's specific device behaviour gets verified
  when we build the delivery feature.
- Open Library API rate limits and metadata quality vary. Treat fetched
  metadata as a suggestion, never auto-apply.
- Send to Kindle email requires the sender address to be on the user's
  Amazon Approved Personal Document E-mail List. Surface this clearly
  in setup; it's a one-time configuration on Amazon's side.
