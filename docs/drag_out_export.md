# Drag-out export to Finder

Status: deferred. Removed from v1 because the simple paths produce a
half-broken UX, and the proper solution is more code than it's worth right
now. We have explicit "Show in Finder" and "Share…" actions on the
inspector that cover the same intent without the rough edges.

## What we want

Drag one or more book cards out of the Acervo window into Finder (or any
file-accepting destination — Mail, Messages, etc.) and get the actual book
files copied. Single drag → one file. Multi-selection drag → N files,
each with its real filename and extension.

## What we tried

1. `ProxyRepresentation { (drag: BookDrag) -> URL in ... }`
   Result: Finder picked our custom `DataRepresentation` (the JSON
   `BookDrag` payload) instead and wrote a 200-byte file named
   "Acervo Book Drag" — because `ProxyRepresentation` to URL doesn't
   reliably register `public.file-url` on the underlying `NSItemProvider`
   in a way Finder selects.

2. `FileRepresentation(exportedContentType: .data) { ... }`
   Result: Finder copied the right file contents but named it `data` (no
   extension) — because `.data` is the generic UTI and Finder uses the
   content type's preferred filename extension.

3. `FileRepresentation(exportedContentType: .epub) { ... }`
   Works for EPUB. Wrong extension for AZW3/MOBI/PDF books, which the
   library does support.

## Why we're not just declaring N FileRepresentations

A representation per format (one for `.epub`, one for `.pdf`, etc.) plus
custom UTType declarations for AZW3/MOBI gets us to the right filename for
the single-file case. But the bigger constraint is **multi-selection**:
SwiftUI's `.draggable(_:)` exports one `Transferable`, and there's no
first-class way to ship N item providers from one draggable. So even with
N FileRepresentations, dragging 5 books to Finder copies one file.

## The proper path

When we come back to this, the right shape is an `NSViewRepresentable`
wrapping `NSDraggingSource` (or the newer `NSDraggingItem` array on a
view). At that layer:

- one `NSDraggingItem` per book
- each item carries an `NSFilePromiseProvider` (or a direct file-URL
  representation) typed by the book's actual UTI
- the system handles multi-file copies natively, with correct filenames

This also opens the door to an `NSDraggingSession` `.copy`/`.move`
operation hint, file promises for iCloud-evicted files, and richer drag
images (we'd reuse `BookDragPreview` via `NSHostingView`).

## In-app drag is unaffected

In-app drags onto the device tile use the custom UTI through SwiftUI's
Transferable system and work fine. Reverting drag-out doesn't touch that.

## Pointers when we pick this up

- `Acervo/Core/Library/BookDrag.swift` — the in-app Transferable lives here
- `Acervo/Views/LibraryView.swift` — `buildBookDrag(for:)` is where the
  drag-start side effects fire; that's where the AppKit drag source would
  also start
- `Acervo/Info.plist` already declares `com.pdrbrnd.acervo.book-drag` —
  if we add public-facing UTIs for AZW3/MOBI, declare them here too
