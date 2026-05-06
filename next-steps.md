v1 shipped. Polish phase: make what we already have rock-solid before adding more.

# Bugs / priorities (in order)

1. **`format:epub` (and other structured filters) broken in library search.** Parser produces them; library filter ignores them. In-flight.
2. **Search persists across collection switches.** Click another collection → search clears. If users push back, revisit.
3. **Arrow keys don't move selection in the book grid.** Single-selection movement only for v1; Shift-extend later if anyone asks.
4. **Missing covers — two distinct bugs.**
    - Plugin-downloaded books: `PluginResult.coverURL` is supplied but never used by `LibraryImporter` — fixable.
    - Sideloaded covers on Kindle: intermittent. Some of this is firmware (Amazon overwrites sideloaded thumbnails over Wi-Fi on some FW). Investigate first, fix what's ours, document what isn't.

# Bigger work, after the bugs

- **Kobo support.** My wife uses one. Calibre is reference. Scope to Kobo only — we're not building a generic device matrix. Other devices wait until someone asks.
- **View / manage device library.** Click DeviceTile → expand into a device-scoped management view (list + delete). Scoped tightly: we are not turning Tomo into a Kindle file manager. No "import from device" unless asked.

# Deferred / parked

- **Plugins → Settings.** Real problem (people don't find them), but tied to a UI decision: the search bar should keep **one** trailing action. We will not add an "X to clear" while the ellipsis is still there. Revisit as a single coherent change later.
- **Per-plugin sidebar entries.** Tempting, but conflates "your library" (sidebar) with "external sources" (search). Drifts the app toward Calibre-as-aggregator. Keep parked unless feedback says otherwise.
- **Drag online book → device.** Removed. Three implicit steps hide failure modes; current explicit flow is fine.
