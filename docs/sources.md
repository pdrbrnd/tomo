# Sources — v2 concept

Context for when v2 starts. Not a v1 concern; do not build any of this
in v1 beyond the `BookOrigin` field on `Book`.

## Motivation

E-book stores are walled-off gardens. A book purchased in-device cannot
be moved to a library, a different reader, or a different device family.
The app's job is to give the user a unified place to find books regardless
of where they live, while respecting their language preferences, existing
library, and reading device.

## What a source is

A "source" is anything the app can search for books in. The protocol is
deliberately generic — sources may be public catalogues, user accounts on
e-book stores, RSS feeds, library OPDS catalogues, or anything else with
a "search → result → file" shape. The app does not encode opinions about
which sources are appropriate; users enable the ones they want.

## Shape (subject to revision when v2 actually starts)

```swift
protocol BookSource {
    var id: String { get }
    var displayName: String { get }
    func search(_ query: SourceQuery) async throws -> [SourceResult]
    func fetchDownloadURL(for result: SourceResult) async throws -> URL?
}

struct SourceQuery {
    let title: String?
    let author: String?
    let isbn: String?
    let language: String?
    let formats: Set<String>
}

struct SourceResult {
    let sourceId: String
    let title: String
    let authors: [String]
    let year: Int?
    let language: String?
    let format: String
    let sizeBytes: Int?
    let detailURL: URL
    let metadata: [String: String]
}
```

Each source is one file in `Core/Sources/`. Sources are pure: they take a
query and return results, hold no shared state, have no UI knowledge.
The UI layer aggregates results from enabled sources, applies language
profile preferences (dim or de-rank results from "avoid" profiles), and
shows "already in library" badges via the existing duplicate detection.

## What sources unlock

- One unified search across whatever sources the user has configured
- Language profile filtering applied at search time, not after download
- Duplicate detection across sources and library: "you already have this",
  "you have the PDF, this is the EPUB"
- "Find better copy" on existing books with no cover or low-quality format
- Downloaded books land directly in the library, classified and organised,
  with no manual intermediate steps

## Not a plugin system

Sources are Swift files in the codebase. A user-installable plugin system
is explicitly out of scope.
