# Code review — 2026-05-04

Methodology: per file, run the SwiftUI skill quality checklist
(`.claude/skills/swiftui/SKILL.md`). Findings recorded as a single
markdown table with `Before | After | Why` columns — the skill's
prescribed output format. One row per issue. End each file's section
with a one-line theme summary.

The conversion module (`Tomo/Core/Conversion/`) is out of scope —
destined for extraction into its own package, treated as a black box.

---

## Models  (3 files)

- [x] Book.swift
- [x] Collection.swift
- [x] LanguageProfile.swift

## Core/Library  (3 files)

- [x] BookDrag.swift
- [x] LibraryFolder.swift
- [x] LibraryImporter.swift

## Core/Index  (1 file)

- [x] BookIndex.swift              — 383 lines, the SQLite/GRDB actor

## Core/Classifier  (4 files)

- [x] BaseLanguage.swift
- [x] Classifier.swift
- [x] LanguageProfileStore.swift
- [x] ProfileClassifier.swift

## Core/Metadata  (10 files)

- [x] CoverCandidate.swift
- [x] CoverRasterizer.swift
- [x] EPUBArchive.swift
- [x] EPUBMetadata.swift
- [x] EPUBNavigation.swift
- [x] EPUBSource.swift
- [x] EPUBText.swift
- [x] GoogleBooksService.swift
- [x] MetadataSidecar.swift
- [x] OpenLibraryService.swift
- [x] iTunesSearchService.swift

## Core/Delivery  (3 files)

- [x] BookDevice.swift
- [x] Kindle.swift
- [x] MockDevice.swift

## Core/  (1 file)

- [x] Loggers.swift

## Views/Foundation  (9 files)

- [x] FlowLayout.swift
- [x] Icon.swift
- [x] InlineEditField.swift
- [x] LocalCoverImage.swift
- [x] MenuRowStyle.swift
- [x] PillButton.swift
- [x] RightClickCatcher.swift
- [x] Theme.swift
- [x] WindowCustomizer.swift

## Views (feature)  (13 files)

- [x] BookCard.swift
- [x] BookDragPreview.swift
- [x] BookInspector.swift           — 614 lines, watch for view-body bloat
- [x] BottomChrome.swift
- [x] CoverGallerySheet.swift       — 310 lines
- [x] DeviceTile.swift
- [x] DropOverlay.swift
- [x] InspectorCover.swift
- [x] LibraryFolderPicker.swift
- [x] LibrarySidebar.swift          — the file flagged by SourceKit
- [x] LibraryView.swift             — 1005 lines, biggest file in the app
- [x] SearchPill.swift
- [x] SelectionRectangle.swift

## App  (3 files)

- [x] AppState.swift                — 552 lines, the only @Observable
- [x] TomoApp.swift
- [x] WindowChromeOverride.swift    — AppKit swizzling, treat carefully

## Cross-cutting passes

- [x] §A — Concurrency & MainActor isolation
- [x] §B — State ownership and derivation
- [x] §C — Error handling at module boundaries
- [x] §D — View-body hot path (no I/O, no decoding, no sorting)
- [x] §E — Naming: rename the three `*Service` enums in Core/Metadata
- [x] §F — DispatchQueue.main.async sites (3 known)
- [x] §G — Magic numbers in views — confirm Theme covers them
- [x] §H — Logger usage — every subsystem covered everywhere it should be?

---

## Findings

(Per-file findings appended below as the review proceeds. Format:

### `path/to/File.swift`
| Before | After | Why |
| --- | --- | --- |
| ... | ... | ... |

Theme: <one-line summary>

If clean: "No findings — clean.")

---

### `Tomo/Models/Book.swift`

No findings — clean. Plain `Sendable Identifiable Equatable` struct, derived properties (`coverURL`, `localeDisplayName`) are computed not stored, sidecar mirror documented inline. `BookOrigin` enum already has the v2 `.source` shape so no migration when sources land.

### `Tomo/Models/Collection.swift`

No findings — clean. Pure data, doc comment explains why it's mirrored by *name* in the sidecar (rebuild resilience).

### `Tomo/Models/LanguageProfile.swift`

No findings — clean. `Marker.weight` documented as "can be negative" — non-obvious and worth keeping.

### `Tomo/Core/Library/BookDrag.swift`

| Before | After | Why |
| --- | --- | --- |
| 2-space indentation in this file (extension body and struct body) | 4-space indentation to match every other file in the project | Inconsistent indentation breaks consistency across the codebase; not a behavior issue but a style drift worth one keystroke to fix |

Theme: pure style drift; logic is correct.

### `Tomo/Core/Library/LibraryFolder.swift`

| Before | After | Why |
| --- | --- | --- |
| `walkBookFolders` enumerates every author/book directory without `try Task.checkCancellation()` between iterations | Add a `try Task.checkCancellation()` at the top of each loop iteration | A user switching library folders mid-walk leaves the previous walk running uselessly; cooperative cancellation is cheap and the `bookFolders(in:)` caller already uses `Task.detached` so cancellation is plumbed |
| `isExistingDirectory` and `isDirectory` are two near-identical helpers | Collapse to one (or call the same `URLResourceKey` API) | Two ways to ask the same question invite drift; pick one |

Theme: cooperative cancellation missing in the walk; one duplicated helper.

### `Tomo/Core/Library/LibraryImporter.swift`

| Before | After | Why |
| --- | --- | --- |
| `EPUBMetadata.read(from:)` is synchronous and called inside the actor's async `importBook` — fine, but `Classifier.classifyEPUB` is also synchronous (read after § Classifier review) and the actor will block on both for the duration of the import | Audit synchronous EPUB/classifier calls during their own review passes; if they do heavy I/O, make them `async` and let the actor await | Actor serialises imports (good — one at a time), but each import still blocks the actor's executor on disk reads; if those become slow on iCloud-evicted files the import queue stalls invisibly |
| `try? cover.data.write(...)` swallows the cover write error and only logs it — the import succeeds with no cover | Either throw and roll back, or surface a non-fatal warning to the caller (return type indicating cover-missing) | Silent partial success: the user thinks the import worked but the book has no cover and they don't know why |
| `EPUBMetadata.read` is called from inside the rollback's *outer* try — if metadata parsing throws, the folder doesn't exist yet so no rollback is needed (correct), but the structure is hard to follow | Move the metadata read out of the `do { … } catch { rollback }` block visually (it already is — but the comment "Past this point, any failure must roll back" relies on the reader noticing) | Clarify the rollback boundary so future edits don't accidentally widen it |

Theme: the actor + typed-error + rollback pattern is right; cover-write silent failure is the only real correctness issue.

### `Tomo/Core/Index/BookIndex.swift`

| Before | After | Why |
| --- | --- | --- |
| 2-space indentation | 4-space (project default) | Consistency — matches every other file outside `BookDrag.swift` |
| `func add(_ book:) throws` and the surrounding API throw raw `GRDB.DatabaseError` / JSON errors | Wrap into a typed `enum BookIndexError` at the actor boundary (e.g. `.write(underlying:)`, `.malformedRow(id:)`) | CLAUDE.md mandates typed errors at module boundaries; callers currently can't switch on failure modes — they only see `Error` |
| `add` and `update` repeat the full column list and JSON-encode steps | Extract a single `upsert(_ book:)` or share a `bind(_ book:, into args:)` helper | Two near-identical SQL templates drift independently the day someone adds a column |
| `createCollection` and `getOrCreateCollection` duplicate the "compute next sort_order then insert" block | Extract the insert-with-next-sort path into one `private static func` taking a name | DRY against the day collection insertion grows (e.g. unique-index on name) |
| `decodeJSON` uses `try?` and `book(from:)` only logs `dropping malformed row id=…` | Either keep but include the underlying decode error in the log, or surface the malformed-row count back through the caller so the index-rebuild path can act on it | Silent partial failures hide corruption — fine for now if logged, but at minimum the *reason* should be in the log line |
| `encodeJSON` returns `String(data:...) ?? "null"` | `try String(...) ?? throw` or just force-unwrap inside a precondition with a comment | UTF-8 decoding of `JSONEncoder` output cannot fail; the fallback is dead code that suggests a real failure mode that doesn't exist |
| `static func open() -> BookIndex?` swallows the open error and returns `nil` after logging | Propagate the typed error to the caller (probably `AppState` / `TomoApp.task`) so the UI can show "couldn't open library" | The caller decides whether index failure is fatal — the index shouldn't decide for it |
| `appendingPathComponent("com.pdrbrnd.tomo", isDirectory: true)` and `appendingPathComponent("index.db")` | `.appending(component: "com.pdrbrnd.tomo", directoryHint: .isDirectory)` etc. | Modern URL API; project uses the new `.appending(component:)` everywhere else |
| Bundle ID `"com.pdrbrnd.tomo"` hardcoded in `databaseURL()` | `Bundle.main.bundleIdentifier ?? "com.pdrbrnd.tomo"` (or assert non-nil) | If the bundle ID ever changes (test target, debug build), this silently writes to the wrong directory |
| `all()` fetches all books and all memberships, then joins in Swift | Fine for v1 (small libraries) but call out: a `LEFT JOIN` SQL would scale better | Note for v2; not a bug today |

Theme: behaviour is solid (actor, migrations, FK cascade, index on `collection_id`); surface area is leaky — typed errors and shared helpers would tighten it.

### `Tomo/Core/Classifier/BaseLanguage.swift`

No findings — clean. Single small function, narrow scope (base language only, per CLAUDE.md classifier-creep watchout).

### `Tomo/Core/Classifier/Classifier.swift`

| Before | After | Why |
| --- | --- | --- |
| `static func classifyEPUB(at:profiles:) -> Classification?` is synchronous and reads the whole EPUB text on the calling thread | Make it `async` and let the caller (`LibraryImporter` actor, future bulk-reclassify) hop off where appropriate | EPUB extract + NLLanguageRecognizer can be slow on large books; the actor that calls this gets blocked for the duration today |
| Five log sites (`text extract failed`, `empty extracted text`, `could not detect base language`, `no profiles for base`, `no marker matches`) | Acceptable as-is — leave the verbosity, it's helpful when triage classifier behaviour | Not a finding, just confirming intent |

Theme: pipeline shape is right (text → base → markers); only structural change worth making is async.

### `Tomo/Core/Classifier/LanguageProfileStore.swift`

| Before | After | Why |
| --- | --- | --- |
| `loadBundled()` is called every time the caller wants profiles; no caching | Cache the result in a `private static let` (lazy) since profiles can't change at runtime | Bundle resource scan + JSON decode of every profile on every call is wasted work; profiles are immutable for the app's lifetime |
| Three-strategy bundle URL fallback with a `// PBXFileSystemSynchronizedRootGroup` comment | Keep — comment explains a real Xcode quirk that future-you will appreciate | Confirming intent |
| `(try? FileManager.default.contentsOfDirectory(...)) ?? []` swallows the directory-read error silently in the third branch | Log a `classifierLogger.warning("could not list bundle resources: \(error)")` before the `?? []` | If we hit the third branch and *that* also fails, we get an empty profile list with no log line and silently no classification |

Theme: caching is the only material change; logging fix is housekeeping.

### `Tomo/Core/Classifier/ProfileClassifier.swift`

| Before | After | Why |
| --- | --- | --- |
| `matchCount(text:pattern:isRegex:)` compiles the `NSRegularExpression` on every call | Pre-compile per-profile at load time (cache `[NSRegularExpression]` alongside `LanguageProfile.markers`) | Bulk re-classify scales with `books × profiles × markers` regex compilations — easy to make fast now |
| `let needle = pattern.lowercased()` inside `matchCount` lowercases the marker on every call; text is already lowercased outside | Lowercase markers once when the profile loads | Same idea — push work to load time |
| Manual `text.range(of: needle, range:)` loop | `text.ranges(of: needle).count` (Swift 5.7+) | Cleaner; identical behaviour |
| `LanguageProfile` has no place to put compiled regex / lowercased markers | Add a small `nonisolated struct CompiledProfile` (or `LanguageProfile.compiled() -> Compiled`) at module level | Don't pollute the JSON-Codable `LanguageProfile`; compile to a derived shape |

Theme: correctness is fine; optimise marker matching by moving compilation/normalisation to load time.

### `Tomo/Core/Metadata/CoverCandidate.swift`

| Before | After | Why |
| --- | --- | --- |
| `URLSession.shared` for cover bytes; no User-Agent, no timeout, no cache policy | Construct a small `URLSession` with `.timeoutIntervalForRequest = 15`, custom UA `"Tomo/1.0"` | Cover sources rate-limit anonymous traffic; a UA is polite and identifiable, and a tight timeout prevents the spinner UI from hanging indefinitely |
| `fetchCoverBytes` is a module-level free function | Move to `static func` on `CoverCandidate` (or a dedicated `CoverFetcher` namespace) | Module-level free functions are unusual in this project; everything else uses the `nonisolated enum X { static func … }` namespace pattern |
| `CoverSource.iTunes` case uses TitleCase while `openLibrary` and `googleBooks` are camelCase | Either rename to `itunes` or leave with explicit `String` raw value | Inconsistent casing reads odd in code; if the trademark spelling matters, give it an explicit raw value to keep the Swift name camelCase |

Theme: small ergonomics; the typed `CoverFetchError` is exactly the right shape.

### `Tomo/Core/Metadata/CoverRasterizer.swift`

| Before | After | Why |
| --- | --- | --- |
| `#if canImport(AppKit)` guard wraps the body | Drop the conditional — Tomo is macOS-only (CLAUDE.md target macOS 26+) | Cross-platform guards add noise without protecting anything; remove or document why they exist |
| `compressionFactor: 0.85` and pixel size `1200×1600` are magic numbers in the function signature | Pull into named constants at the top of the enum: `private static let kindleCoverSize`, `private static let jpegQuality` | Trivial readability — the values are *Kindle-tuned*, that intent should live next to them |
| Returns `Data?` and silently fails (returns nil) on every error path | At least log via `metadataLogger.error("rasterise failed: \(stage)")` at each early-return | Five different failure points, all silent — first time it breaks in production you'll have nothing |

Theme: macOS-only project doesn't need cross-platform guards; surface failures through the logger.

### `Tomo/Core/Metadata/MetadataSidecar.swift`

No findings — clean. Custom `Codable` for legacy keys is well-commented (the "old sidecars (pre-2026-05) didn't persist the book id" rationale matters); pretty-printed sorted-keys output makes sidecars diff-friendly. Sentinel "und" handling is clear.

### `Tomo/Core/Metadata/EPUBText.swift`

| Before | After | Why |
| --- | --- | --- |
| `XMLDocument(data:)` is invoked twice (strict, then `.documentTidyHTML`) inline | Extract a `private func parseXHTML(_ data: Data) -> XMLDocument?` helper — the same fallback also appears in `EPUBNavigation.parseNav` | DRY; the fallback strategy is repeated verbatim |
| Recursive `collectText(from:)` on potentially deep DOM | Iterative walk with an explicit stack | Stack overflow risk on deeply nested HTML is theoretical; flag only because EPUBs in the wild are arbitrarily ugly |
| `wordLimit: Int = 5000` parameter | Pull `defaultWordLimit` into a named constant adjacent to the classifier's confidence threshold | The 5000 number is paired conceptually with the classifier's appetite for input; constants together |

Theme: extracted parser helper would cut duplication shared with `EPUBNavigation`.

### `Tomo/Core/Metadata/EPUBMetadata.swift`

| Before | After | Why |
| --- | --- | --- |
| `epub.opf.date.flatMap { Int($0.prefix(4)) }` | Use `DateFormatter`/`ISO8601DateFormatter` or at least handle the "2020" / "January 2020" / "2020-01-01" shapes explicitly | Real-world EPUBs publish dates in many formats; `prefix(4)` only works for `YYYY-` prefix; degrade gracefully |
| `EPUBMetadata.read(from:)` is `nonisolated static` extension | Move into the type body or use a clear pattern across every metadata type | Mixing `static func read` patterns (some on type, some via extension) is incidental drift |

Theme: year extraction is fragile; the rest is clean.

### `Tomo/Core/Metadata/EPUBNavigation.swift`

| Before | After | Why |
| --- | --- | --- |
| Same XHTML parser fallback (strict → tidy HTML) duplicated from `EPUBText.swift` | Share via a `private func parseXMLOrTidyHTML(_ data: Data) -> XMLDocument?` in this folder | DRY — bug fixes in one place currently won't propagate |
| `parseNav` and `parseNCX` follow the same skeleton (open data → parse → walk nodes → produce entries) | Either accept; or extract a generic `walk<XPath>` helper. Probably leave — they're divergent enough that a shared helper would obscure | Confirming no action needed |
| `EPUBArchive.resolvePath` is invoked for path normalisation but is on `EPUBArchive` (a struct) — unclear it's a pure utility | If pure, mark via doc comment "pure path math, no archive state" so readers don't think it touches the archive | Minor docs |

Theme: shared XHTML parser helper across `EPUBText` + `EPUBNavigation` is the only material cleanup.

### `Tomo/Core/Metadata/EPUBArchive.swift`

| Before | After | Why |
| --- | --- | --- |
| `func data(at:)` and `func data(forResourceHref:)` silently return `nil` for both "missing" and "extraction failed" | Distinguish the two: a typed result (`enum`), or at minimum a logger line for "found but extraction failed" so corrupted archives are visible in console.app | Right now a malformed EPUB looks the same as an EPUB without a cover — debugging takes a manual XCode breakpoint |
| `out.append($0)` in extraction reads the whole resource into memory | Acceptable for v1 (covers, OPF, single XHTML files); flag if AZW3 conversion ever streams large images | Note for the conversion module's future review |
| `parseOPF` uses local helper closures `first(_:)` / `all(_:)` capturing `doc` | Either keep (they're scoped, terse, readable) or extract to free funcs taking the doc | Confirming intent — current shape is fine |

Theme: silent failures on resource lookup are the only behavioural smell; structure is otherwise tight.

### `Tomo/Core/Metadata/EPUBSource.swift`

| Before | After | Why |
| --- | --- | --- |
| `parseEPUBDate` is a thoughtful multi-format parser that lives only here; `EPUBMetadata` does the fragile `Int($0.prefix(4))` | Move `parseEPUBDate` to a shared util in this folder and have `EPUBMetadata.read` use it for the year | Two date parsers in one folder, one robust and one not |
| `imgSrcPattern` regex only matches quoted `src="…"` / `src='…'` — unquoted `src=foo` is missed | Extend the alternation to `|([^\s>]+)` for the unquoted case | Real-world EPUBs are messy; the byte-slice path already handles malformed input, parity here costs one alternation |
| Duplicate XHTML parser fallback (`bodyInnerHTMLByXMLDocument`) — same pattern as `EPUBText`/`EPUBNavigation` | Fold into the shared parser helper proposed in the EPUBText/EPUBNavigation rows | One bug fix, three sites |
| `findBody` recursive walk | Iterative; same note as `EPUBText.collectText` | Theoretical stack risk |

Theme: the two-pass image-rewrite design is the right one; tighten by sharing the date parser and the XHTML fallback.

### `Tomo/Core/Metadata/GoogleBooksService.swift`

| Before | After | Why |
| --- | --- | --- |
| Type name `GoogleBooksService` | Rename to `GoogleBooks` | `*Service` suffix is flagged in CLAUDE.md / swiftui skill; this is a stateless namespace, not a service object |
| Search-then-decode boilerplate (URLSession.shared.data → status check → JSONDecoder().decode → typed error mapping) is repeated in all three cover sources | Extract a shared `private func fetchJSON<T: Decodable>(_ url: URL) async throws -> T` (in this folder, not module-level) | Same six lines copy-pasted across `GoogleBooks`, `OpenLibrary`, `iTunes` — fix in one for all |
| `URLSession.shared` with no UA / timeout | Use a small purpose-built session (per the CoverCandidate finding) | Same point as CoverCandidate |
| `replacingOccurrences(of: "http://", with: "https://")` | `URLComponents`-based scheme upgrade | Avoids accidentally matching paths that start with `http://` (none in practice from Google, but principled) |
| `filterRealCovers` re-downloads thumbnails to inspect dimensions, then `URLCache.shared` makes the gallery's later fetch free | Document the reliance on `URLCache.shared` having a useful default size; if not, configure one | Cache disable would cause us to download every thumbnail twice — fragile reliance on default config |

Theme: solid logic and the placeholder-filtering is clever; rename + extract shared HTTP helper.

### `Tomo/Core/Metadata/OpenLibraryService.swift`

| Before | After | Why |
| --- | --- | --- |
| Type name `OpenLibraryService` | Rename to `OpenLibrary` | Same as Google |
| Repeats the search-then-decode boilerplate | Use the shared `fetchJSON` helper proposed above | Same as Google |
| `cover_i`, `author_name`, `first_publish_year` snake_case keys spelled out | `JSONDecoder` with `keyDecodingStrategy = .convertFromSnakeCase`, then rename properties to camelCase | Either is fine; current is explicit at the cost of Swift-idiomatic property names |

Theme: shortest of the three sources, but carries the same `*Service` and HTTP-boilerplate findings.

### `Tomo/Core/Metadata/iTunesSearchService.swift`

| Before | After | Why |
| --- | --- | --- |
| Type name `iTunesSearchService` | Rename to `ITunes` (or `AppleBooks`) | Same `*Service` suffix; *Search* is also incidental — the type does one thing, name it for the source |
| `mergeUnique` strips `"itunes-us-"` / `"itunes-pt-"` prefixes from the candidate id | Carry the trackId on the candidate (e.g. an opaque source-key field) and dedupe on that | The current approach is a string-massaging round-trip that breaks the moment id format changes |
| `upscaleArtwork` regex compiled per call | Compile once via `private static let upscaleRegex` | Tiny, but consistent with the same theme everywhere else |
| Repeats the search-then-decode boilerplate | Same shared `fetchJSON` helper | Same as Google/OpenLibrary |
| `try? NSRegularExpression(pattern: pattern)` — falls back to returning the unupscaled URL on regex failure | Force-unwrap with comment, or fail loudly — the pattern is a constant and a regex compile failure is a programming error | `try?` here hides the only thing that could realistically go wrong |

Theme: same naming/duplication theme as the other two; the parallel US+PT search is a nice pattern.

### `Tomo/Core/Delivery/BookDevice.swift`

| Before | After | Why |
| --- | --- | --- |
| 2-space indentation | 4-space (project default) | Consistency — same drift as `BookIndex.swift` and `BookDrag.swift` |
| `nonisolated let deliveryLogger = Logger(...)` declared at the top of this file | Move to `Tomo/Core/Loggers.swift` next to the other four loggers | The whole point of `Loggers.swift` is "one place for subsystem loggers"; `delivery` is a subsystem and should sit with its peers |
| `func deviceFilename(for book: Book) -> String` declared as a protocol requirement *and* defaulted in the protocol extension; no conformer overrides it | Remove from the protocol; keep only the extension default | Protocol requirements that are always satisfied by the default extension are dead surface — future code reads the requirement and looks for an override that doesn't exist anywhere |
| `compatibilityWarning` and `supportedFormats` could have safe defaults in the extension (nil / empty) | Add defaults so single-implementation devices like `MockDevice` don't need to spell every requirement | Optional unless it actively benefits readability — judgement call |
| Single real implementation (Kindle) plus a `#if DEBUG` MockDevice | Acceptable — the swiftui skill's "delete protocols with one impl" rule includes debug/preview siblings as a valid second user; protocol stays | Confirming intent |

Theme: doc-conformance drift (logger placement, redundant protocol requirement); no behavioural issues.

### `Tomo/Core/Delivery/Kindle.swift`

| Before | After | Why |
| --- | --- | --- |
| 2-space indentation | 4-space (project default) | Same drift |
| `firmwareVersion` is read on init via synchronous disk I/O and then never referenced | Either drop the field or actually use it (log on attach, surface in UI as "FW 5.19.2" tooltip) | YAGNI: dead state is dead state |
| `init?(volumeURL:)` does synchronous `fileExists` checks for `documents/` + `system/` plus a synchronous `String(contentsOf: version.txt)` | Keep — volume root probes are nanoseconds, splitting them across an async init costs more than it saves | Confirming intent |
| `copy(_:)` does conversion + copy + fsync — the converter is fetched twice (once in `deliveryRoute`, once in `copy`'s `.convert` arm) | Either thread the converter through `DeliveryRoute.convert(to:converter:)` or let `copy` only consult the route once | Two registry lookups per copy is fine perf-wise but invites the two paths to disagree |
| `compatibilityWarning: String? { nil }` is a stored-style "always nil" warning | Either default to nil in the protocol extension and drop here, or surface a real warning once one exists | One less line; ties into the BookDevice extension finding |

Theme: clean driver; the route-then-fetch-converter-again split is the only structural seam.

### `Tomo/Core/Delivery/MockDevice.swift`

No findings — clean. Debug-only, sleeps for transition feedback, takes a `mockFilenames` injection for testing the on-device-badge state. (Indentation is 4-space here while `BookDevice.swift`/`Kindle.swift` are 2-space — same folder, different style. Fix project-wide in one pass.)

### `Tomo/Core/Loggers.swift`

| Before | After | Why |
| --- | --- | --- |
| Four loggers here; `deliveryLogger` lives in `BookDevice.swift` | Move `deliveryLogger` here so all five live together | Single index of subsystems; matches the file's stated purpose |

### `Tomo/Views/Foundation/FlowLayout.swift`

| Before | After | Why |
| --- | --- | --- |
| `arrange` runs twice per layout pass (`sizeThatFits` then `placeSubviews`) | Use the `Cache` associated type — store the arranged result once and reuse | SwiftUI re-runs both methods on container reflow; doubling the work for tag clouds is fine, but the Layout API exists exactly for this |
| `containerWidth = proposal.width ?? .infinity` | Same shape OK; just confirm the `.infinity` branch never reaches `placeSubviews` (it shouldn't — placement always has a real bounds) | Sanity note |

Theme: solid layout, only optimisation worth making is the cache.

### `Tomo/Views/Foundation/Icon.swift`

No findings — clean. Tiny, single-purpose wrapper.

### `Tomo/Views/Foundation/InlineEditField.swift`

| Before | After | Why |
| --- | --- | --- |
| `body` wraps content in a `Group { if isEditing … else … }` | `body` is `@ViewBuilder` already; drop the Group: `if isEditing { editingView } else { displayView }` directly | Group is redundant indirection |
| `editingView` ends with `.padding(.vertical, -2).padding(.horizontal, -4)` to neutralise the earlier inner padding while keeping the background visible | Add a one-line comment ("counter the inner padding so the field's outer footprint matches display mode and doesn't shift on enter") | Future-you will look at the negative paddings and wonder; the *why* is the value |
| `onCommit` is called only when `trimmed != value` | Confirming intent: this means an enter on an unchanged value is a no-op. Document or rename to `onChange` to make that contract explicit | Subtle — a caller relying on "onCommit fires whenever the user pressed Enter" will be surprised |

Theme: small comment + Group cleanup; behaviour is solid.

### `Tomo/Views/Foundation/LocalCoverImage.swift`

| Before | After | Why |
| --- | --- | --- |
| `NSImage(contentsOf: url)` reads the image at native resolution, regardless of cell size in the grid | Downsample via `CGImageSourceCreateThumbnailAtIndex` with a target pixel size (≈ 2× cell width) | A 2400px cover loaded for a 200px cell wastes ~140× the pixels; matters once the library hits hundreds of books |
| Comment about `Color.clear`/`overlay`/`clipped` is excellent | Keep verbatim — exact case for memory's worth-it watermark | Confirming intent |

Theme: only material change is downsampling; the layout idiom is correct and well-explained.

### `Tomo/Views/Foundation/MenuRowStyle.swift`

No findings — clean. Concentric-radius math handled by `Theme.Radius.menuItem`; the related `MenuDivider` and `menuPopoverContainer` cohabit the file because they're a single pattern.

### `Tomo/Views/Foundation/PillButton.swift`

No findings — clean. Two-variant button style; explicit `prominent: Bool` is fine for two states; could flip to `enum Variant { default, prominent }` only when a third variant arrives.

### `Tomo/Views/Foundation/RightClickCatcher.swift`

No findings — clean. The `hitTest` pass-through is the exact pattern for "intercept a single button without breaking SwiftUI"; the comment explains the trick.

### `Tomo/Views/Foundation/Theme.swift`

| Before | After | Why |
| --- | --- | --- |
| `func isDarkAppearance(_:)` is a top-level free function | Move into `Theme` (or mark `private`/`fileprivate` and have `WindowCustomizer` use a re-export through Theme) | Pollutes module scope with a name that reads like a free utility; sole non-Foundation user is `WindowCustomizer.swift` |
| Hardcoded SRGB tuples appear three times (canvas, panel both reuse `0.062/0.062/0.066` and `0.965/0.961/0.953`) | Pull into `private static let darkCanvasNS` / `lightCanvasNS` constants and reference from each `NSColor(name:)` block | Two places to update when the canvas tone changes; change-resistance |
| `Theme.Chrome` has two near-identical comments documenting that `toggleEdgeInset + toggleDiameter/2 = 30` matches `Radius.window = 30` | Keep — the math is *exactly* the kind of thing that drifts | Confirming intent |

Theme: structure is tight; small cleanups only.

### `Tomo/Views/Foundation/WindowCustomizer.swift`

| Before | After | Why |
| --- | --- | --- |
| `DispatchQueue.main.async { … }` inside `makeNSView` and `updateNSView` to defer until window attached | `Task { @MainActor in … }` matches the project's "Swift Concurrency, not GCD" rule (per swiftui skill anti-patterns) | The CLAUDE.md / skill is explicit: no `DispatchQueue.main.async` in new code; project already uses `Task { @MainActor in … }` for the observer callbacks below — be consistent |
| `nonisolated final class Coordinator: @unchecked Sendable` with mutable state | Mark `@MainActor final class Coordinator` and make `deinit` `nonisolated` | `@unchecked Sendable` is an escape hatch; the actual contract ("MainActor mutates everything; deinit only calls thread-safe APIs") is exactly what `@MainActor` + `nonisolated deinit` expresses correctly without the unchecked-promise |
| `NotificationCenter.default.addObserver(forName:object:queue: .main)` returning a token; explicit `Task { @MainActor in … }` inside the closure | `NotificationCenter.default.notifications(named:)` async sequence consumed in a `Task` you store on the Coordinator | The async-sequence variant cancels with the task and removes the explicit observer-removal in `deinit` — closer to the modern API per the concurrency reference |

Theme: AppKit bridge is correct, but the GCD/`@unchecked` mix is exactly the legacy style the project moved away from.

### `Tomo/Views/DropOverlay.swift`

No findings — clean. Pure presentation; concentric-corner math derived from `Theme.Radius.window`.

### `Tomo/Views/SelectionRectangle.swift`

No findings — clean. 15 lines, no state.

### `Tomo/Views/BottomChrome.swift`

No findings — clean. Concentric math documented; the empty-region tap-to-blur is the right pattern (sized to natural content, not full-window).

### `Tomo/Views/BookCard.swift`

No findings — clean. The `BookCardDeviceStatus` enum makes the tri-state mutually-exclusive; comment explains why dim is on the cover only (Material backdrop).

### `Tomo/Views/SearchPill.swift`

| Before | After | Why |
| --- | --- | --- |
| `naturalCollapsedWidth` invokes `NSFont.systemFont` and `NSAttributedString.size(...)` on every body evaluation | Cache against `placeholder` (the only input that changes) — `@State private var cachedNaturalWidth: (placeholder: String, value: CGFloat)?` | Body is hot; measuring strings via AppKit on every keystroke during a typing session is wasted work |
| `chromeWidth = 13 + 13 + 13 + 8 + 4 + 18 + 6` is a magic number with the ingredients listed in a comment | Compute from named constants matching the actual padding/icon sizes | The comment will drift the day a designer changes one of the numbers in `body` and not the chrome math |

Theme: width animation idiom is sound; small wins on hot-path string measurement.

### `Tomo/Views/BookDragPreview.swift`

No findings — clean. The synchronous `NSImage(contentsOf:)` is exactly correct for the drag-bitmap timing — the comment captures the *why* perfectly.

### `Tomo/Views/DeviceTile.swift`

| Before | After | Why |
| --- | --- | --- |
| `progressBar` uses `GeometryReader` to width-relative the fill | `Capsule().scaleEffect(x: progress, y: 1, anchor: .leading)` clipped to bounds, or a `Rectangle().frame(maxWidth: .infinity).clipShape(...)` with `.containerRelativeFrame` | swiftui-views.md flags GeometryReader as last-resort; for a single horizontal progress bar a layout primitive is cheaper |
| `private enum Visual` is `Equatable` (auto-synthesised) and used as `.animation(_, value: visual)` driver | Confirming intent — exactly the right pattern; documenting it as such would help future readers | Note for posterity |

Theme: state-machine design is solid; only the GeometryReader is worth replacing.

### `Tomo/Views/InspectorCover.swift`

| Before | After | Why |
| --- | --- | --- |
| `panel.begin { … DispatchQueue.main.async { onSetCoverFromFile(url) } }` | Drop the `DispatchQueue.main.async` wrapper — `NSOpenPanel.begin`'s callback already runs on main, and the project policy is "no GCD" | Either the dispatch hides a real timing bug (worth surfacing) or it's superstition (delete it). Either way, fix the comment-or-code mismatch |
| `loadImageData(from provider:)` uses `withCheckedThrowingContinuation` | Keep — that's the proper bridge for `NSItemProvider`'s callback API | Confirming intent |

Theme: one stray `DispatchQueue` to clean up.

### `Tomo/Views/LibraryFolderPicker.swift`

| Before | After | Why |
| --- | --- | --- |
| `DispatchQueue.main.async { fileImporterOpen = true }` to defer until popover dismisses | `Task { @MainActor in fileImporterOpen = true }` — same effect, project's preferred idiom | Same theme as `WindowCustomizer` and `InspectorCover` — the project explicitly avoids GCD; doing this consistently means future readers don't have to wonder which calls are "deliberate GCD" vs "leftover GCD" |
| `LibraryFolder.recents()` called inline in body — re-reads UserDefaults on every body evaluation | Snapshot via `@State` updated on `popoverOpen` change | UserDefaults reads are cheap but the body is hot; only re-fetch when the popover actually opens |

Theme: clean view; standard "use Task instead of GCD" cleanup.

### `Tomo/Views/CoverGallerySheet.swift`

| Before | After | Why |
| --- | --- | --- |
| `onAppear { startSearch() } / .onDisappear { searchTask?.cancel() }` to manage the search task | Either keep (explicit cancel/restart on user action is a feature here) or split: use `.task` for the initial run and a separate stored `searchTask` for the manual rerun | Confirming intent — current shape is the right trade. Document briefly that "we keep the task explicit because the search button must cancel-and-replace" |
| Three sources searched in parallel via `async let`; per-source failures don't poison others | Keep — exactly the right shape for "best-effort multi-source" | Confirming intent |
| Sheet has its own private `GalleryQueryField` view at the bottom | Either move to `Views/Foundation/` (it's reusable structurally) or rename to `private struct GalleryQueryField` clarifying the file scope | Right now it's neither private to the sheet nor shared with the rest of the app; pick one |
| `private extension String { var nilIfEmpty: String? }` | Same — either upstream into a util or scope to `private` here | Same point |

Theme: solid sheet; only structural cleanups.

### `Tomo/Views/LibrarySidebar.swift`

| Before | After | Why |
| --- | --- | --- |
| `flashClearTask` cancellation is the right shape; the comment explains the race | Confirming intent | Note for posterity |
| `Self.rowSpacing` (a `static let`) lives mid-file between `languagesSection` and `sectionHeader` | Move to the `// MARK: - Building blocks` block at the top with the other layout constants, or to `Theme.Spacing` | Constants buried mid-file slip past code review the day someone adds a new section |
| `newCollectionField` and `renameField` duplicate the entire textfield-with-rounded-bg styling | Extract a private `inlineTextField(text:placeholder:onCommit:onCancel:)` helper or an `InlineEditField`-style view | Two near-identical 18-line styled fields with the same focus-blur logic; one bug fix in two places |
| Two `@FocusState` properties (`newCollectionFocused`, `renameFocused`) for the two inline fields | Single `@FocusState` enum tracking which inline field is focused (or none) | Two booleans for two mutually-exclusive states = the classic case for an enum |

Theme: drop-flash race handling and cancel-on-blur logic are well-considered; only the duplicated inline-textfield boilerplate is worth refactoring.

### `Tomo/Views/LibraryView.swift`

| Before | After | Why |
| --- | --- | --- |
| `filteredBooks`, `collectionCounts`, `languageCounts`, `inspectorBooks`, `selectedBooksInOrder` — five computed properties that filter/group `state.books` on every body evaluation | For v1, fine; for v2 with hundreds of books, lift the heavy ones (counts) to `AppState` (cached, invalidated on book CRUD) | Body is hot; while linear filters on a few hundred items aren't a problem, this is the kind of code that gets slow before anyone notices |
| `var body` is ~130 lines: pane HStack + folder pill overlay + bottom chrome overlay + library-folder task + 3 alerts/dialogs + cover sheet | Extract the alerts/confirmationDialogs/sheet into named computed properties (`deleteBooksDialog`, `deleteCollectionDialog`, etc.) — same pattern as `mainPane`, `sidebarPane`, `inspectorPane` | The view body should read as a structural overview; right now half of it is dialog wiring |
| `inspectorPane` passes 14 closures into `BookInspector`, most of which are `if let book = inspectorBook { Task { await state.X(book) } }` | Either group into `BookInspector.Actions` value type, or move the `if let book` guard into `BookInspector` (pass the `state` and `inspectorBook` directly — would couple them but cut the boilerplate dramatically) | The current shape pushes coordination into the view, but the pattern of "guard book, dispatch task" is identical 12 of 14 times |
| `@AppStorage("sidebar.open")` persists; `@State private var inspectorOpen = false` doesn't | Decide deliberately: should the inspector remember its state across launches? If yes, `@AppStorage`. If no, document why | Inconsistent persistence is the kind of thing users notice and report as a bug |
| `buildBookDrag(for:)` mutates `selectedBookIDs`, `selectionAnchor`, `state.inAppDragCount`, and starts a polling task — all from inside an autoclosure passed to `.draggable` | Surface the side effects via a separate `.onDragStart`-equivalent or dedicated drag controller; the autoclosure should ideally be pure | Side effects in payload-builder closures are a documented hazard of `.draggable`; the comment carries the intent today, but a future SwiftUI change to closure invocation timing could regress this silently |
| `startDragEndPolling` polls `NSEvent.pressedMouseButtons` every 50ms during a drag | Acceptable workaround; comment explains why event monitors don't fire during drags | Confirming intent |
| `grid` uses a `GeometryReader` to compute card width | Could swap for `LazyVGrid` with `GridItem(.adaptive(minimum: minCardWidth, maximum: maxCardWidth))` and let SwiftUI compute the columns | The adaptive sizing handles "as many as fit between min and max" out of the box; current code reproduces that math by hand. Test that the resulting card sizes still feel right |
| `bookCell` attaches `.draggable + .simultaneousGesture(TapGesture(1)) + .simultaneousGesture(TapGesture(2)) + .overlay(RightClickCatcher) + .popover` to every card | Pull into a `BookCellInteractions` view modifier | Five interaction layers per card; bug-fixes touch all 1000s of cells if behaviour drifts |
| Single 1005-line file | Split: a separate `LibraryView+Selection.swift` extension for click handlers, `LibraryView+Drag.swift` for drag plumbing, `LibraryView+Keyboard.swift` for shortcuts | The view's responsibility is "render the library window"; selection/drag/keyboard are independent concerns clean to extract |

Theme: the view is the central conductor and earns its size, but ~30% is mechanical dispatch wiring that would compress nicely with a few extracted helpers.

### `Tomo/App/TomoApp.swift`

No findings — clean. `@main`; single `WindowGroup`; debug commands gated by `#if DEBUG`; calls `WindowChromeOverride.install` in `init` (correct timing — before any window).

### `Tomo/App/WindowChromeOverride.swift`

| Before | After | Why |
| --- | --- | --- |
| 2-space indentation | 4-space (project default) | Same drift |
| `let radius = cornerRadius` aliases the parameter for no reason | Inline `cornerRadius` directly into the closure bodies | Two names for one value invite "wait, what's `radius` again" reads |
| Doc comment notes "Verified on macOS 26.4 (2026-05-04). Re-verify after deployment-target bumps." | Add a `#if compiler(>=…)` or version-check assertion that fails at build time when SDK changes — or a runtime warning when the OS version moves past tested | Currently nothing forces re-verification; a future macOS that breaks `NSThemeFrame` selectors silently degrades to system corners, and only the warning log will show |
| All four selectors missing logs `"None of the … selectors were found — system radius will apply"` but app continues | Acceptable graceful-degradation per the comment | Confirming intent |

Theme: surgical and well-documented; just nudge to project conventions and consider build-time guard.

### `Tomo/App/AppState.swift`

| Before | After | Why |
| --- | --- | --- |
| 2-space indentation | 4-space (project default) | Same drift |
| Single class owns: index lifecycle, importer, library folder + persistence, books, collections, device, deviceFilenames, drag count, send state, last import error, mount/unmount observers, debug fakes | Acceptable for v1; flag as the most likely splitting candidate when v2 sources or v2 collections grow. Candidate split: `LibraryStore` (books/collections/folder/sync) + `DeviceStore` (device/filenames/send-state/mount obs) | "One thing per type" per the swiftui skill; right now this is the canonical "Manager wrapping a Service wrapping a Repository" smell, just spelled `AppState` |
| `mountObserver` and `unmountObserver` registered in init; never removed | Add `deinit { center.removeObserver(mountObserver) … }` (or convert to `NotificationCenter.notifications(named:).values` consumed in a stored `Task`) | For a singleton-lifetime AppState this leaks tokens that never fire on a dead instance — fine in practice, but the pattern misleads anyone copying it for shorter-lived observables |
| `let detected = DeviceScanner.detect() / detected?.filenames()` in init does synchronous `/Volumes` I/O on main | Move to `.task { await refreshDeviceState() }` at the root view, or to an `init?` factory pattern | Init-time synchronous I/O on main; volume reads are ms-fast in practice but the pattern blocks the first frame |
| `pngData(from: NSImage)` is synchronous and called from MainActor in `setCover(for:image:)` | `await Task.detached { pngData(from: image) }.value` | Image encoding is CPU work; large clipboard images can spike noticeably |
| Repeated `await openIndexIfNeeded(); guard let index else { return }` (12 sites) | Either lift to a single `withIndex(_ work: (BookIndex) async throws -> T) async -> T?` helper, or change `index` from optional to non-optional after a one-time init | The repetition is mechanical and identical every time |
| `syncWithDisk` reads sidecars sequentially in a `for` loop | `await withTaskGroup` for parallel sidecar reads (cap concurrency to ~8) | Linear in library size; for hundreds of books on iCloud, parallel reads cut sync time substantially |
| `rewriteSidecar(for:newCollectionIDs:)` runs once per affected book on rename/delete | If many books are affected by a rename/delete, this is N sequential disk writes | Same parallelisation note; lower priority than the read path |
| `func sendBooksToDevice` updates `deviceSendState` mid-loop and uses `sendStateResetTask` for auto-clear; sequential copies | Acceptable — sequential is correct (USB device, single channel); auto-reset handles "user already moved on" | Confirming intent |
| `lastImportError` lives on AppState and is cleared by the alert dismiss binding in `LibraryView` | Acceptable; or convert to a stream of `ToastMessage` if more user-facing errors arrive | Note for v2 |
| `@discardableResult func createCollection(named:) async -> Collection?` is called both for-result and discarded | Keep `@discardableResult`; it's load-bearing | Confirming intent |
| `pngData(_:)` is a free function at the top of the file | Move into AppState as `private nonisolated static`, or into `Tomo/Core/Metadata/` if reusable | Floating top-level helpers in app-state files clutter the module namespace |
| `loadBooks` uses `async let booksTask = index.all()` and `async let collectionsTask = index.collections()` then awaits both | Right pattern for two independent queries | Confirming intent |

Theme: the file is the most-felt fairness audit — single observable doing a lot of jobs, well-organised but ripe for splitting once any axis grows; mostly small consistency wins (indent, observer cleanup, lift the index-guard).

---

## §A — Concurrency & MainActor isolation

| Before | After | Why |
| --- | --- | --- |
| `Classifier.classifyEPUB` is synchronous; `EPUBMetadata.read` is synchronous; `EPUBSource.read` is synchronous | Make all three `async`; let the actor / `Task.detached` callers await | These are heavy operations dispatched from inside `LibraryImporter` (an actor) and `LibraryView` (via `Task.detached`); making them `async` lets cancellation propagate and removes the workaround pattern of "wrap synchronous heavy work in `Task.detached` at every call site" |
| `LibraryFolder.walkBookFolders` and `AppState.syncWithDisk`'s sidecar loop don't `try Task.checkCancellation()` between iterations | Add `try Task.checkCancellation()` at the top of each iteration | Library scans should bail when the user picks a different folder mid-scan |
| Three `DispatchQueue.main.async` sites (WindowCustomizer × 2, LibraryFolderPicker, InspectorCover) | `Task { @MainActor in … }` everywhere | Project policy is "no GCD"; consistency keeps "deliberate GCD" from accidentally appearing |
| `WindowCustomizer.Coordinator` is `nonisolated final class … @unchecked Sendable` with mutable state mutated only on MainActor | `@MainActor final class Coordinator` with `nonisolated deinit` | The actual contract is exactly what `@MainActor` expresses; `@unchecked` is an escape hatch with no real benefit here |
| `NotificationCenter.addObserver(forName:object:queue:)` callback API used in `WindowCustomizer` and `AppState` | `NotificationCenter.notifications(named:).values` consumed in a stored `Task` | Async-sequence form removes the explicit `removeObserver` plumbing and ties cancellation to the observer's owner |
| `AppState`'s mount/unmount observers are registered but never removed | Either `deinit { removeObserver(…) }` or migrate to async sequences (above) | Singleton lifetime makes this de-facto fine; the *pattern* still misleads when copied |
| Synchronous I/O at AppState init (`DeviceScanner.detect`, `Kindle.init`, `firmwareVersion` read) | Move to `.task { … }` after first frame | Volume reads are fast in practice; flag as the only init-time main-thread I/O remaining |

Theme: the project is on Swift Concurrency with a few legacy holdouts (GCD x3, observer-callback API x2, sync-classifier-from-actor). Kill those and the concurrency story is uniform.

---

## §B — State ownership and derivation

| Before | After | Why |
| --- | --- | --- |
| `AppState` carries 12 stored properties — many derivable subsets are computed in `LibraryView` instead | Acceptable; `@Observable` already makes derivation cheap. Confirm that no consumer stores any of these computed views in their own `@State` | Drift watchpoint, not an action item today |
| `LibraryView.filteredBooks`, `collectionCounts`, `languageCounts` are computed properties on every body re-render | Lift `collectionCounts` and `languageCounts` to `AppState` (cached, invalidated on book CRUD) for v2; leave for v1 | Body is hot; counts touch every book on every keystroke |
| `LibraryView` has `@AppStorage("sidebar.open")` but `@State private var inspectorOpen = false` | Decide deliberately and document the asymmetry — or `@AppStorage` both | Inconsistent persistence is a UX bug surface |
| `BookInspector.transientClassification` is local to the inspector and cleared on book change or after 3s | Correct — confidence is intentionally not persisted (per CLAUDE.md) | Confirming intent |
| `Book.collectionIDs` is populated by `BookIndex.all()` joining the `book_collections` table; not stored on the row | Correct shape; the join-time hydration is documented inline | Confirming intent |
| Sidecars carry collection *names* not IDs; the index is rebuilt by name → get-or-create on sync | Correct shape; principle 1 (disk = truth) holds | Confirming intent |
| `WindowCustomizer.Coordinator.originalOrigins` caches button origins so re-applies are idempotent | Correct — without it, re-applies compound the offset | Confirming intent |

Theme: state ownership is mostly right; the only material drift candidate is `LibraryView`'s recomputation of counts on every body re-evaluation, which would matter at scale.

---

## §C — Error handling at module boundaries

| Before | After | Why |
| --- | --- | --- |
| `BookIndex` throws raw `GRDB.DatabaseError` and JSON errors | Wrap into `enum BookIndexError` (write/read/malformed-row variants) | CLAUDE.md mandates typed errors at module boundaries |
| `EPUBArchiveError`, `LibraryImporterError`, `BookDeviceError`, `CoverFetchError` all conform to `LocalizedError` | Good — keep | Confirming intent |
| `LibraryImporter` catches the cover-write error and silently continues (cover stays nil) | Surface to caller (return type, or warning) — silent partial success hides bugs | Real correctness issue |
| `BookIndex.book(from:)` and `decodeJSON(_:)` swallow malformed rows with a single log line | Include the underlying error in the log; consider surfacing malformed-row counts to the sync caller so it can re-emit `metadata.json` | Drops corruption silently |
| `EPUBArchive.data(forResourceHref:)` returns nil for both "missing" and "extraction failed" | Distinguish via typed result | Same blindness for the cover/manifest path |
| `iTunesSearchService.upscaleArtwork` uses `try? NSRegularExpression(pattern: pattern)` with constant pattern | Force-unwrap with comment, or fail loudly | `try?` on a constant-pattern compile failure hides programming error |
| Cover services log decode failures and throw `CoverFetchError.decoding` — caller sees user-friendly message | Good | Confirming intent |
| `BookIndex.open()` static factory swallows the error and returns nil after logging | Propagate to caller (TomoApp / AppState) | Caller decides whether index-open failure is fatal |
| `try?` use in `LocalCoverImage.load`, `MockDevice` sleeps, `CoverGallerySheet.runSearch.trySearch` | Acceptable each — they're "best-effort" cases the call site genuinely doesn't care about | Confirming intent for each |

Theme: typed errors are present at most boundaries; the gaps are `BookIndex` (raw GRDB), the cover-write silent failure in `LibraryImporter`, and `EPUBArchive`'s ambiguous nils. None catastrophic; all mechanical to fix.

---

## §D — View-body hot path

| Before | After | Why |
| --- | --- | --- |
| `LibraryView.filteredBooks` filters `state.books` on every body eval | Acceptable today; cache once `state.books` grows | Hot path |
| `LibraryView.collectionCounts` and `languageCounts` reduce-over-books on every body eval | Lift to `AppState` (cached, invalidated on book CRUD) for v2 | Hot path |
| `SearchPill.naturalCollapsedWidth` measures the placeholder via `NSAttributedString.size` on every body eval | Cache against placeholder | Hot path |
| `LibraryFolderPicker` calls `LibraryFolder.recents()` (UserDefaults read) inline in body | Snapshot on `popoverOpen` toggle | Hot path |
| `BookCard.cardHeight` is `cardWidth * 1.5` — trivial computed property | Fine | Confirming intent |
| `BookInspector.metaRow(_:value:)` formats `book.dateAdded` via `.formatted(...)` on every body eval | Acceptable for a single inspector; if profiling shows a hit, cache | Lower priority |
| `LibraryView.grid` uses `GeometryReader` to compute card width | Replaceable with `.adaptive` GridItem; possibly lower body-eval cost | Lower priority |
| `LocalCoverImage` loads `NSImage(contentsOf:)` at native resolution | Downsample via `CGImageSourceCreateThumbnailAtIndex` | Lower priority — memory not body-time |
| `ProfileClassifier` recompiles regex per call | Pre-compile per profile at load | Hot path of a different kind (bulk classify) |

Theme: nothing in body actually does I/O or JSON-decoding (good); the only true hot-path costs are repeated reductions over `state.books` and a few small recomputations that cache cleanly.

---

## §E — Naming: the three `*Service` enums

| Before | After | Why |
| --- | --- | --- |
| `GoogleBooksService` | `GoogleBooks` | Stateless namespace; `*Service` suffix is flagged by the swiftui skill |
| `OpenLibraryService` | `OpenLibrary` | Same |
| `iTunesSearchService` | `ITunes` (or `AppleBooks`) | Same; *Search* is incidental to the source identity |
| `CoverSource.iTunes` case (TitleCase) vs `openLibrary`/`googleBooks` (camelCase) | Either rename to `itunes` or give explicit raw value to keep camelCase Swift name | Mixed casing reads odd |
| `DeviceScanner` | Acceptable — *Scanner* suffix is descriptive of one job | Confirming intent |
| `LibraryImporter` (actor) | Acceptable — *Importer* names a single specific job | Confirming intent |
| `WindowChromeOverride` | Acceptable — `*Override` describes exactly what it is | Confirming intent |

Theme: only the three `*Service` enums and the `iTunes` casing actually drift from the project's naming pattern.

---

## §F — `DispatchQueue.main.async` sites

| Before | After | Why |
| --- | --- | --- |
| `WindowCustomizer.makeNSView` deferred apply | `Task { @MainActor in apply(...) }` | Project policy |
| `WindowCustomizer.updateNSView` deferred apply | `Task { @MainActor in apply(...) }` | Project policy |
| `LibraryFolderPicker.openFolderRow` deferred fileImporter open | `Task { @MainActor in fileImporterOpen = true }` | Project policy |
| `InspectorCover.presentReplaceDialog` panel.begin callback wrapping `onSetCoverFromFile` | Drop the `DispatchQueue.main.async` wrapper — `NSOpenPanel.begin` callback already runs on main | Either superstition or undocumented timing bug; either way, fix the mismatch |

Theme: four sites total (one more than the inventory's three — InspectorCover's `panel.begin` callback wrapping was missed in the initial count). All four convert mechanically to Task or unwrap entirely.

---

## §G — Magic numbers in views

`Theme.Spacing` (xs/sm/md/lg/xl/xxl/menuInset) and `Theme.Radius` (cover/card/panel/sidebarRow/menu/menuItem/window) cover most spacing/radius use sites. Drift sites observed:

| Before | After | Why |
| --- | --- | --- |
| `BookInspector.rowLabel(_:)` width `76` | `Theme.Spacing.inspectorLabelWidth` (or similar) | Used by every meta row; one place to tune |
| `BookInspector` corner radius `Theme.Radius.cover + 2` (used 4× in `InspectorCover`) | `Theme.Radius.coverInspector` constant | The "+2" repeats; a named constant carries the intent |
| `LibraryView.grid`: `margin = 62`, `minCardWidth = 168`, `maxCardWidth = 224` | Move into `Theme.Library` namespace alongside Chrome | These are layout-tuning numbers, not view-internal |
| `BookCard.cardHeight = cardWidth * 1.5` (book aspect ratio) | `Theme.Library.bookAspectRatio: CGFloat = 2.0/3.0` | The 1.5 / 0.667 / 2:3 ratio appears in `BookCard`, `CoverGallerySheet`, and `BookDragPreview` — single source of truth |
| `BookDragPreview.cardWidth = 96`, `cardHeight = 144` | Same — `Theme.Library.dragPreviewSize` | Consolidates with the above |
| `InspectorCover.coverWidth = 132`, `coverHeight = 198` | Same | Same |
| Hover/press colour opacities (`0.18`, `0.10`, `0.08`, `0.06`, `0.05`) appear in `MenuRowStyle`, `SidebarRowBody`, `PillButtonBody` | A `Theme.Hover` namespace with named opacities | Three button styles independently maintain the same hover scale |
| `BookCard`'s `1.014` selected-scale, `1.10` `dragActive`, `1.20` `dragOver`, `1.06` `sending` (`DeviceTile`) — animation-tuning values scattered | A `Theme.Animation` namespace | Lower priority — animation feel is hand-tuned |

Theme: `Theme.Spacing` / `Theme.Radius` cover the basics; the next level — book aspect ratio, hover-opacity scale, layout grid tuning — is currently dispersed and would benefit from one consolidation pass.

---

## §H — Logger usage

`Loggers.swift` declares `library`, `index`, `metadata`, `classifier`, `conversion`. `BookDevice.swift` declares `delivery` (should move per the file's review). `WindowChromeOverride.swift` declares its own private `window-chrome` logger — that one is appropriately scoped.

| Before | After | Why |
| --- | --- | --- |
| `deliveryLogger` lives in `BookDevice.swift` | Move to `Loggers.swift` | Already noted |
| `WindowChromeOverride` has a private `window-chrome` logger; `WindowCustomizer.swift` has no logger and silently fails on observer issues | Either `windowLogger` in Loggers.swift used by both, or accept one-logger-per-file for window-specific code | Two adjacent files, two different policies |
| `LanguageProfileStore.bundleURLs` falls through to a third strategy with `(try? FileManager.default.contentsOfDirectory(...)) ?? []` and no log line | Add `classifierLogger.warning` | Already noted |
| Logging conventions are consistent: `.public` privacy on filename/title strings, `.privacy: .public` on enums | Confirming — the project is uniformly explicit about privacy | Confirming intent |
| Most error paths log via the appropriate subsystem's logger | Confirming | Confirming intent |
| `setCover(for:image:)` logs `cover encode to PNG failed` but the user sees no surfacing | Acceptable — image encode failure is rare; could surface to UI later | Lower priority |

Theme: logger plumbing is clean; just reseat `deliveryLogger` and add the missing `bundleURLs` warning.

---

## Triage summary

**Bugs / correctness (do now):**
- `LibraryImporter` cover-write swallows error — book imports with no cover, no surfacing
- `BookIndex` throws raw GRDB errors — callers can't switch on failure modes
- `iTunesSearchService.upscaleArtwork` `try?` on constant-pattern regex hides programming errors
- `EPUBArchive.data(forResourceHref:)` ambiguous nil
- `BookIndex.encodeJSON` `?? "null"` is dead code

**Architectural drift (schedule):**
- 2-space vs 4-space indentation across the codebase (`BookDrag`, `BookIndex`, `BookDevice`, `Kindle`, `WindowChromeOverride`, `AppState`)
- `*Service` rename for the three cover sources + `CoverSource.iTunes` casing
- Lift `*Counts` to `AppState` for v2 scale
- Split `AppState` into `LibraryStore` + `DeviceStore` once any axis grows
- Move `parseEPUBDate` and the XHTML-tidy-fallback into shared helpers across `EPUBSource` / `EPUBText` / `EPUBNavigation`
- Pre-compile classifier regex / pre-lowercase markers at profile load
- Cache `LanguageProfileStore.loadBundled()`
- Replace `DispatchQueue.main.async` × 3 (4 with InspectorCover) with `Task { @MainActor in … }`
- `WindowCustomizer.Coordinator`: `@MainActor` + `nonisolated deinit`, drop `@unchecked Sendable`

**Style / naming / minor (one cleanup PR):**
- `deliveryLogger` move to `Loggers.swift`
- Theme constants for book aspect ratio, hover opacities, inspector label width
- `LibraryView.body` extract dialogs into named properties
- `LibrarySidebar` extract inline-textfield helper
- `BookInspector` actions group into `Actions` value type
- Fix the lowercase `tomo` scheme reference in `CLAUDE.md` (actual scheme is `Tomo`)
- Remove `let radius = cornerRadius` alias in `WindowChromeOverride`
- Drop `#if canImport(AppKit)` guards in macOS-only files (`CoverRasterizer`)

**Confirmed-intent items (no action):**
- Models clean
- Sidecar custom Codable for legacy keys
- Actor-serialised import path
- Cover-source quality ordering (iTunes → OpenLibrary → GoogleBooks)
- `BookCardDeviceStatus` mutually exclusive enum
- `DeviceTile.Visual` state-machine driving `.animation(_, value:)`
- `RightClickCatcher` hitTest pass-through pattern
- `MarqueeState` enum + `CardFramePreference` for selection rect
- `WindowChromeOverride` graceful degradation on missing selectors

