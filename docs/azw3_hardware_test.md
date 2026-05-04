# AZW3 hardware test checklist

What to run after a code change to the AZW3 writer or EPUB source. The
writer was last validated on:

- **Device:** Paperwhite Signature
- **Firmware:** 5.19.2
- **Date:** 2026-05-03 (Phase 1) / [update on each phase]

Kindle firmware behaviour is empirical — Amazon updates the parser
silently, so this checklist is the authoritative validation, not the
unit tests.

## What to test

Convert and sideload at least one EPUB from each of these shapes:

- **Plain text novel** — Portuguese (pt-PT), single chapter file, no
  images. Verifies basic text rendering, locale, EXTH metadata.
- **Novel with TOC** — multiple chapters declared in `nav.xhtml`.
  Verifies chapter navigation (Menu → Go To → Table of Contents).
- **Illustrated book** — at least one inline `<img>` per chapter.
  Verifies image record extraction and `kindle:embed` URI rewriting.
- **CSS-styled book** — custom typography in a stylesheet. Verifies
  CSS flow encoding and `<link kindle:flow:NNNN>` injection.
- **EPUB with SVG cover** — verifies `CoverRasterizer` runs and the
  rendered JPEG is a valid record.
- **EPUB 2 with `toc.ncx`** — verifies NCX fallback when `nav.xhtml`
  is absent.

## What to verify on the device

For each book:

1. **Cover** — appears on home screen and in the library list.
2. **Title + author** — match the EPUB's `<dc:title>` / `<dc:creator>`.
3. **Language** — long-press → Book Info shows the right language.
4. **Table of Contents** — Menu → Go To → Table of Contents lists the
   real chapters (not "Whole book").
5. **First page** — opens cleanly; no broken HTML, no missing styles.
6. **Image rendering** — figures display in the right places.
7. **Page progression** — swipe through 10+ pages without crash or
   visible gap.

## Sideload procedure

```sh
# 1. Plug Kindle in via USB. Wait for `/Volumes/Kindle` to mount.
# 2. Convert and copy via Tomo's "Send to Kindle" UI.
# 3. Wait for indexing — the cover may take 30s+ to appear.
# 4. Eject from Tomo's UI (do not yank the cable).
```

If a book fails to index, leave it on the Kindle and check
`system/cc.log` for indexing errors. Write the failing book aside —
it's now a regression fixture.

## Optional: KindleUnpack structural validation

For a faster signal than sideloading, run KindleUnpack on the output:

```sh
# Install KindleUnpack once:
# https://github.com/kevinhendricks/KindleUnpack

python -m kindleunpack /path/to/converted.azw3 /tmp/unpack/
# Clean exit + populated /tmp/unpack/ = structurally valid AZW3.
```

KindleUnpack catches malformed PalmDB / MOBI header / EXTH issues
without the round-trip through hardware. It does **not** catch
rendering issues — those still need the device.

## Updating this doc

Each time the firmware version on the test device changes, update the
"Date" line at the top and re-run the full checklist. Each time a new
EPUB shape exposes a regression that wasn't caught before, add it to
"What to test."
