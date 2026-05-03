# AZW3 writer

This directory will be extracted as a standalone Swift package once the
Phase 1 spike produces a Kindle-indexable AZW3 on real hardware. To make
that extraction painless, **nothing in this folder may import or reference
any Acervo type**.

Public API contract (as it lands):

- **Input:** a plain metadata struct (title, authors, language tag, etc.)
  + an array of HTML chunks (strings).
- **Output:** `Data` — the AZW3 file bytes.

That's it. The bridge from Acervo's `Book` type to the writer's input
struct lives in `Acervo/Core/Conversion/EPUBToAZW3Converter.swift`
(outside this folder), not here.

If a future change tempts you to import `Book`, `BookFormat`, or any
other app type into this folder, **stop and bridge it from outside
instead**. The whole point is that this code stays self-contained so
when we move it to its own repo with its own CI, EPUB test corpus, and
release cadence, the move is a pure file-shuffle with no API rework.
