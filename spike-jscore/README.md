# JSCore Spike — Sources Plugin Feasibility

Phase 1 of the sources spike (`/Users/pedro/.claude/plans/sources-i-don-t-want-validated-reef.md`).

Standalone CLI that proves an `anna.js` plugin can search Anna's Archive and produce a downloadable EPUB via JavaScriptCore + Swift-side `fetch` / `querySelectorAll` bindings. **No app code is touched until this works.**

## Run

```sh
swift run JSCoreSpike search "saramago"
swift run JSCoreSpike download <result-id>
```

`anna.js` lives in `plugins/` and is loaded at startup. Replace it freely while iterating.
