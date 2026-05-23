# Plugin host contract

This document tracks the host-side surface that plugins can rely on, and which Tomo version each capability landed in. Plugin authors use this to set `minAppVersion` in their manifest.

> **Why this exists**
> Tomo plugins run inside a JavaScriptCore context with a small host-provided runtime (`fetch`, `querySelectorAll`, `cacheImage`, `console`) and a contract for the values they pass back (`search`/`download` shapes). When that surface evolves, plugins built against an older Tomo may stop working on a newer Tomo — or vice versa. `minAppVersion` is the gate; this file is the reference for choosing it.

## Versioning policy

Tomo follows semver for **app releases**, and uses the app version itself as the contract identifier (VSCode / Obsidian style). The rules:

- **Major** (e.g. 1.x → 2.x): may include breaking changes to the plugin runtime or result shapes. Plugins must be re-blessed for each major.
- **Minor** (1.5 → 1.6): purely additive — new host bindings, new optional fields, new query knobs. Existing plugins keep working without changes.
- **Patch** (1.5.0 → 1.5.1): no plugin-visible changes.

If a plugin doesn't use a feature introduced in 1.6, it does not need to declare `minAppVersion: "1.6.0"`. Declare the lowest version that contains every host capability the plugin actually relies on.

## Capability history

| Capability | Available since | Notes |
|---|---|---|
| `search(query)` / `download(result)` exports | 1.0.0 | Core contract. |
| `query` fields: `text`, `title`, `author`, `language`, `isbn`, `format`, `year`, `publisher` | 1.0.0 | |
| `Result` fields: `id`, `title`, `authors`, `year`, `language`, `format`, `sizeBytes`, `coverURL`, `detailURL`, `metadata[]` | 1.0.0 | |
| `download()` returning `{ kind: "browser", url? }` | 1.0.0 | For sources that require user interaction (Cloudflare, slow-download partners). |
| `fetch(url, opts?)` | 1.0.0 | URLSession-backed. |
| `querySelectorAll(html, selector)` | 1.0.0 | SwiftSoup-backed. |
| `cacheImage(url, opts?)` | 1.0.0 | For hotlink-protected covers. |
| `console.log` / `console.error` | 1.0.0 | |
| Manifest field: `minAppVersion` | 1.6.0 | Without this field the plugin is treated as "no constraint" — installs everywhere. Set it explicitly when the plugin relies on a 1.6+ host capability. |

Earlier-than-this entries don't exist; 1.0.0 is the first version that shipped the plugin system. The table grows as we add capabilities — every addition lands in a minor release.

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
