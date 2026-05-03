# AZW3 Phase 2 — known deferrals

The Phase 1 spike produces a Kindle-indexable AZW3 from clean ASCII
EPUBs. To get there in a single sprint we made trade-offs that must
be revisited before the converter is considered production-ready.
This doc is the complete, current list. If you find something here
that's no longer true (because we shipped a fix), update or delete
the entry.

Sections are ordered by user-visible impact: things that produce
*wrong output* first, then things we *don't yet output*, then
internal cleanups.

---

## A. Format-correctness gaps (will produce broken output for some inputs)

### A.1 Multibyte UTF-8 trailing hint
**File:** `Acervo/Core/Conversion/AZW3/TrailingBytes.swift`
**Symptom:** Portuguese/Spanish/French/etc. books may render with a
broken character at every 4096-byte record boundary that happens to
slice through a multibyte UTF-8 sequence.
**Fix:** Look at the last bytes of each text record. If they form an
incomplete UTF-8 sequence, set `multibyte` to the count of bytes that
spilled over from a sequence that started in this record. Currently
hardcoded to `0` (correct for ASCII only). ~10 LOC.

### A.2 `XMLDocument`-based body extraction may transform bytes
**File:** `Acervo/Core/Metadata/EPUBSource.swift` (`bodyInnerHTML`)
**Symptom:** Whitespace, namespace declarations, and entity escaping
in the produced HTML chunk may differ from the original EPUB
spine-item body. Kindle may render slightly different output.
**Fix options:** (a) slice the raw bytes between literal `<body>` and
`</body>` tags via byte search; (b) post-process the
`xmlString` output to undo known transformations. (a) is simpler and
preserves byte-equivalence with the source; (b) is safer for
malformed inputs.

### A.3 Skeleton template has no CSS-flow link tags
**File:** `Acervo/Core/Conversion/AZW3/Markup.swift`
**Symptom:** EPUBs that rely on stylesheet rules render with default
Kindle styling. No actual breakage; degraded fidelity.
**Fix:** Wire the CSS extraction into the template (B.4 below) and
inject `<link rel="stylesheet" href="kindle:flow:N?mime=text/css"/>`
for each flow.

---

## B. Format completeness (features we don't output)

### B.1 Cover image
**Where it lands:** image record(s) at the end of the database; EXTH
entries `EXTHCoverOffset` (201) and `EXTHHasFakeCover` (203);
`null.mobi.firstImageIndex` set to the first image record number.
**Pre-work:** EPUBSource needs to extract the cover (it does already,
in `EPUBMetadata.CoverImage` — reuse). New AZW3 file:
`Acervo/Core/Conversion/AZW3/ImageRecord.swift`. SVG covers must be
either skipped or rasterized via CoreGraphics — see A.4 below.

### B.2 TOC / NCX from EPUB nav
**Currently:** `Markup.chaptersToText` returns a single chapter
spanning the whole book. NCX has one entry. No chapter navigation on
Kindle.
**Pre-work:** Parse `nav.xhtml` (EPUB 3) or `toc.ncx` (EPUB 2) in
EPUBSource. Extend `BookManifest` with chapter information. Map each
chapter to a contiguous run of spine items (or, for finer-grained
TOCs, to anchor offsets within spine items).
**Risk:** EPUB nav structure varies wildly. May need fallback logic.

### B.3 Cover thumbnail and ASIN-based cover lookup
**Used by newer Kindles** which fetch covers from Amazon by ASIN.
Side-loaded books with embedded covers can still display them via the
thumbnail folder hack (see leotaku's `GetThumbFilename`).
**Pre-work:** Encode a fake ASIN (`%015x` of the unique ID) and emit
`EXTHASIN` (113), `EXTHKF8CoverURI` (129), `EXTHThumbOffset` (202).
For USB delivery, additionally write a JPEG to
`/Volumes/Kindle/system/thumbnails/thumbnail_{asin}_EBOK_portrait.jpg`.

### B.4 CSS flows
**Currently:** `BookManifest.chunks` is HTML only. Single-flow FDST
record. No CSS support.
**Pre-work:** Extend `BookManifest` with `cssFlows: [String]`.
EPUBSource extracts CSS files declared in the OPF manifest. Markup
template injects `<link>` tags. AZW3Writer adds CSS bytes to the
combined text after HTML and adds an FDST entry per CSS file.

### B.5 Image records (embedded JPEG/GIF in HTML)
**Currently:** Images in EPUBs are silently dropped — the chunk
HTML still references `<img src="...">` but Kindle has no image
record to point to.
**Pre-work:** Extract image bytes from the EPUB. Rewrite `<img src>`
to `kindle:embed:NNNN` URIs. Add image records to the database with
`null.mobi.firstImageIndex` set to the first one.

### B.6 PalmDoc compression
**File:** `Acervo/Core/Conversion/AZW3/PalmDocHeader.swift`
**Currently:** `compression = 1` (none). Files are 2–3× larger than
necessary. Kindle accepts this fine; it's purely a size concern.
**Fix:** Implement PalmDoc LZ77-ish compression in a new
`PalmDoc.swift`. Set `compression = 2`. ~250 LOC of compression
logic, plus a corresponding `extraRecordDataFlags` adjustment if
needed.

### B.7 SVG cover rasterization (when B.1 lands)
EPUBs sometimes ship SVG cover images. Kindle wants raster (JPEG).
**Options:** skip SVG covers (no cover for those books); rasterize
via `CoreGraphics`; require the user to convert externally.

### B.8 Embedded fonts
EPUBs can ship fonts in the manifest. KF8 has a font record format.
Kindle's renderer will substitute system fonts otherwise.
**Decision:** Probably defer indefinitely — most users prefer
Kindle's default fonts anyway.

### B.9 MOBI 6 dual-format
The user explicitly opted out of MOBI 6 ("never support .mobi").
Older Kindles (pre-firmware-4) won't open KF8-only files. We don't
care.

---

## C. Metadata fields we don't set (EXTH + MOBI header)

### C.1 EXTH entries beyond the Phase-1 set

**Currently emitted:** title (99), updatedTitle (503), author (100),
publisher (101), language (524), asin (113), docType (501). **Not
emitted but worth adding when relevant content lands:**

| Code | Name | Notes |
|------|------|-------|
| 106  | PublishingDate | ISO-8601 format; needs EPUB `<dc:date>` parse |
| 105  | Subject | EPUB `<dc:subject>` (tags) |
| 522  | (and other Furigana fields) | Japanese books only |
| 525  | PrimaryWritingMode | RTL/vertical scripts |
| 527  | PageProgressionDirection | RTL books |
| 121  | KF8Boundary | Marks the KF8 section start in dual-format files |
| 125  | KF8CountResources | Image count, lands with B.5 |
| 201  | CoverOffset | Lands with B.1 |
| 203  | HasFakeCover | Lands with B.1 |
| 129  | KF8CoverURI | Lands with B.1 |

**Pre-work:** Extend `BookManifest` with these fields, or pass a
"metadata bundle" struct. Add EXTH cases to `EXTHEntryType`.

### C.2 MOBI header fields stubbed at defaults

| Field | Current | Should be |
|-------|---------|-----------|
| `uniqueID` | FNV-1a hash of title+authors+language | Hash is stable; consider using EPUB `<dc:identifier>` if present |
| `locale` | 0 (NEUTRAL) | Microsoft locale code mapped from BCP 47 (see leotaku/locales.go for the table) |
| `firstImageIndex` | UInt32.max | First image record number when B.5 lands |

### C.3 No date in PalmDB header
`PalmDB.Database` defaults to `.now` for the date. Should match the
EPUB's `<dc:date>` value if present, falling back to file mtime,
falling back to now. Cosmetic — Kindle doesn't check.

---

## D. Internal architecture / refactor opportunities

### D.1 Three duplicate EPUB readers
`EPUBMetadata`, `EPUBText`, and `EPUBSource` each independently:
- Open the ZIP archive
- Extract `META-INF/container.xml`
- Parse the OPF path
- Re-open and parse the OPF

Extract a shared `EPUBArchive` helper that does open + container +
OPF parse once. Each consumer uses the parsed data. Reduces
duplication and avoids re-opening the archive multiple times for one
EPUB.

### D.2 Hardcoded skeleton template
`Markup.swift` hardcodes one specific XHTML template. Leotaku exposes
the template via `OverrideTemplate`. We don't need that for v1, but
when CSS flows or fixed-layout books arrive we'll want a way to
parameterise.

### D.3 String → Data conversions
Many places: `Data(string.utf8)`. Cumulative cost is small but for
large books this adds up. Profile before optimising.

### D.4 `xmlString(options:)` for body inner HTML
See A.2 — same root cause, two angles. Architecturally we want to
avoid round-tripping through `XMLDocument` for content extraction.

### D.5 INDX record `ncxIndexRecord` uses `TAGXTable.ncxSingle`
Leotaku uses `TAGXTable.chunk` for the same control byte; both
produce 15. Output bytes are identical. Comment in
`IndexBuilders.swift` documents the intentional divergence. If we
ever need a different control-byte-to-TAGX-table mapping, consolidate.

---

## E. Validation / testing

### E.1 KindleUnpack as a structural validator
`https://github.com/kevinhendricks/KindleUnpack` is the canonical
parser for our format. CI should run `python -m kindleunpack
out.azw3` against a small corpus and assert clean exit. Catches
malformed PalmDB / MOBI header / EXTH bugs without a Kindle.

### E.2 Round-trip text equivalence
After producing an AZW3, run KindleUnpack to extract HTML, then
compare the extracted text to `EPUBText.extract(from:)` of the
original EPUB. Catches encoding / spine-order / compression bugs.

### E.3 Project Gutenberg corpus
~20 books spanning eras and structures. Manually verify on the
user's actual Kindle once per phase.

### E.4 Real Kindle hardware test checklist
Document the exact device + firmware + filenames + steps. Update each
time hardware behaviour changes (Amazon firmware updates regularly).

### E.5 Fuzzing on malformed inputs
Once the writer is solid, fuzz EPUBSource with broken EPUBs (missing
container.xml, malformed OPF, encrypted DRM, etc.). The writer should
fail cleanly with typed errors, never crash.

---

## F. Edge cases we don't handle yet

- **EPUB 2 with NCX** (we only parse OPF + spine; NCX requires
  separate parsing). Most modern EPUBs are 3 with `nav.xhtml`.
- **Malformed XHTML** (we already fall back to `documentTidyHTML`,
  but real EPUBs in the wild break in creative ways).
- **Very large books** (text > UInt32.max bytes ≈ 4 GB). Undefined
  behaviour; precondition would be cleaner.
- **DRM-protected EPUBs.** Should refuse cleanly with a clear error,
  not silently produce garbage AZW3.
- **Empty manifests / 0-chapter books.** Currently the markup layer
  produces one chapter with `length = 0`. NCX header builder uses
  `entryCount - 1` which underflows to a huge negative number. The
  writer would crash. Add a precondition or empty-book special case.
- **Books with `<body>`-less spine items** (unusual but legal).
  EPUBSource silently drops them.
- **Spine items larger than the 4096-byte text-record max within a
  single chunk's body.** Currently a `TextRecord.init` precondition
  would trigger if Markup ever produced a single chunk over the
  threshold. Phase 1 doesn't because each spine item is its own
  chunk and they typically fit. Phase 2 with merged chunks needs to
  split.

---

## G. Performance

### G.1 Multiple archive opens per EPUB
See D.1.

### G.2 Memory allocation on Data appends
`textToRecords` and `Markup.chaptersToText` each build up a `Data`
buffer with many small `append` calls. For large books this could
be slow. Profile first; fix only if it shows up.

### G.3 Synchronous I/O in `EPUBToAZW3Converter`
`EPUBSource.read` is synchronous and blocking. Wrapped in
`Task.detached` so it doesn't hang the main actor, but a large EPUB
could still take seconds. Acceptable for v1; revisit if
deliveries-per-minute matter.

---

## H. Documentation

This doc itself. Keep it current. When something here is shipped,
remove the entry — outdated TODO lists are worse than no TODO list.
