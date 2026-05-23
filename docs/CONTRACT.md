# Plugin host contract

This document tracks the host-side surface that plugins can rely on, and which Tomo version each capability landed in. Plugin authors use this to set `minAppVersion` in their manifest.

> **Why this exists**
> Tomo plugins run inside a JavaScriptCore context with a small host-provided runtime (`fetch`, `querySelectorAll`, `cacheImage`, `console`) and a contract for the values they pass back (`search`/`download` shapes). When that surface evolves, plugins built against an older Tomo may stop working on a newer Tomo — or vice versa. `minAppVersion` is the gate; this file is the reference for choosing it.

## Versioning policy

Tomo follows semver for **app releases**, and uses the app version itself as the contract identifier (VSCode / Obsidian style). The rules:

- **Major** (e.g. 1.x → 2.x): may include breaking changes to the plugin runtime or result shapes. Plugins must be re-blessed for each major.
- **Minor** (1.7 → 1.8): purely additive — new host bindings, new optional fields, new query knobs. Existing plugins keep working without changes.
- **Patch** (1.7.0 → 1.7.1): no plugin-visible changes.

Declare `minAppVersion` as the lowest Tomo version that contains every host capability your plugin actually uses. Tomo 1.7.0 is the floor — it's the first version with the formal plugin contract (manifest, registry, compat gating). Pre-1.7 versions ran plugins but without manifests or version awareness, so a plugin authored against this contract won't work on them.

## Capabilities (all available in 1.7.0)

| Capability | Notes |
|---|---|
| `search(query)` / `download(result)` exports | Core contract. |
| `query` fields: `text`, `title`, `author`, `language`, `isbn`, `format`, `year`, `publisher` | |
| `Result` fields: `id`, `title`, `authors`, `year`, `language`, `format`, `sizeBytes`, `coverURL`, `detailURL`, `metadata[]` | |
| `download()` returning `{ kind: "browser", url? }` | For sources that require user interaction (Cloudflare, slow-download partners). |
| `fetch(url, opts?)` | URLSession-backed. |
| `querySelectorAll(html, selector)` | SwiftSoup-backed. |
| `cacheImage(url, opts?)` | For hotlink-protected covers. |
| `console.log` / `console.error` | |
| Manifest field: `minAppVersion` | Without this field the plugin is treated as "no constraint" — installs everywhere. |

When new capabilities are added (in a future 1.8+), this table grows with an "Available since" column and the policy above kicks in.

## Changing the contract (host-side)

If we ever need to break compatibility (rename a field, change a binding's return shape, remove a host function), the bump goes to a **major** release:

1. The breaking change ships in a major (e.g. 2.0.0).
2. Every plugin in `pdrbrnd/tomo-plugins` is reviewed; compatible ones are re-blessed with `minAppVersion: "2.0.0"`; incompatible ones are fixed or delisted.
3. Users running Tomo 2.x stop seeing 1.x-only plugins in Browse (the compat gate refuses install/update). Already-installed 1.x plugins keep running until they actually break at runtime — at which point the user removes them.

The hope is that this happens approximately never. Additive evolution is the path of least pain for everyone.

## Source of truth

This doc describes intent. The authoritative surface lives in:

- `Tomo/Core/Plugins/PluginHost.swift` — every host binding and its option shape.
- `Tomo/Core/Plugins/PluginResult.swift` — `PluginQuery` / `PluginResult` / `PluginField`.
- `Tomo/Core/Plugins/PluginSource.swift` — `search` / `download` invocation, return-shape lifting.
- `Tomo/Core/AppVersion.swift` — where the running app's version comes from.
- `Tomo/Core/Plugins/PluginManifest.swift` — what plugins can declare.
- `Tomo/Core/Plugins/PluginRegistry.swift` — registry entry shape and compatibility check.

If this doc and the code disagree, the code wins. Open an issue (or a PR fixing the doc).
