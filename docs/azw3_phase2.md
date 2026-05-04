# AZW3 Phase 2 — wrap-up

Phase 1 + Phase 2 of the AZW3 writer are code-complete as of 2026-05-03.
The writer ships in `Tomo/Core/Conversion/AZW3/` and is exercised by
the EPUB→AZW3 path used at delivery time. Hardware validation runs from
`docs/azw3_hardware_test.md`.

## What landed

- Reader consolidation under `Tomo/Core/Metadata/EPUBArchive.swift`
- Byte-faithful `<body>` extraction (no XMLDocument round-trip)
- Cover image record + EXTH 201/203/125/129/202
- TOC parsing (EPUB 3 nav.xhtml + EPUB 2 toc.ncx) → real NCX entries
- BCP 47 → Microsoft locale code mapping
- SVG cover rasterisation via AppKit
- CSS flows + `kindle:flow:NNNN` `<link>` injection
- Body images + `kindle:embed:NNNN` rewrite
- DRM detection, empty-content + 4 GB-text preconditions
- `<dc:identifier>`-derived MOBI uniqueID, ISO-8601 publishing date EXTH

## What's deferred — reach for these only with a real reason

- **PalmDoc compression** — output is 2–3× larger than necessary.
  Kindle accepts uncompressed; size only matters at scale.
- **Thumbnail-folder hack** (`/Volumes/Kindle/system/thumbnails/…`) —
  the FW 5.19.2 Paperwhite Signature surfaces covers via EXTH alone;
  add this only if older firmwares show up.
- **EPUB-Subject (EXTH 105)** — needs the Tomo data model to grow
  tags first.
- **Chunk-splitting for large spine items** — current writer emits
  one chunk per spine item with no size cap. Calibre splits at
  ~4 KB; if a real-world novel renders with broken chapter geometry
  on hardware, this is the first place to look.
- **Embedded fonts** — Kindle's defaults are fine for the user.
- **MOBI 6 dual-format** — explicitly opted out.
- **Furigana / RTL EXTH fields (522, 525, 527)** — out of scope for
  PT/EN library.
- **String→Data perf** and other micro-optimisations — profile first.

## Where things live

- Writer entry point: `Tomo/Core/Conversion/AZW3/AZW3Writer.swift`
- Public input contract: `Tomo/Core/Conversion/AZW3/BookManifest.swift`
- Per-record builders: same folder, one file per record type
- EPUB → manifest bridge: `Tomo/Core/Conversion/EPUBToAZW3Converter.swift`
- Hardware test procedure: `docs/azw3_hardware_test.md`
- Future package extraction: `Tomo/Core/Conversion/AZW3/README.md`

When `AZW3/` is finally extracted into its own Swift package, this
doc dies with it.
