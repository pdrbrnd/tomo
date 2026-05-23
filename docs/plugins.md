# Writing a Tomo plugin

Tomo's source plugins are JavaScript files that search external book catalogues and resolve download URLs. Tomo runs them in JavaScriptCore and lifts results into the library UI.

The bundled `gutenberg.js` is the canonical example — read it alongside this doc.

## File format

A plugin is a single `.js` file. Drop it in:

```
~/Library/Application Support/com.pdrbrnd.tomo/plugins/
```

Tomo loads every `.js` file in that directory on launch (and on the "Reload" action in the sources popover). Each plugin can be enabled/disabled independently in the sources popover; enabled plugins run in parallel on every search and their results land in their own section.

> Plugins are bare `.js` files with no manifest. A `plugin.json` format may be introduced later.

## Contract

A plugin must export two `async` functions:

```js
async function search(query) { /* return Result[] */ }
async function download(result) { /* return string | { kind: "browser", url?: string } */ }
```

### `search(query) -> Result[]`

Called when the user types in the search bar (debounced). Return an array of result objects.

`query`:

| field       | type             | notes                                    |
|-------------|------------------|------------------------------------------|
| `text`      | `string`         | free-text portion of the search.         |
| `title`     | `string?`        | from `title:foo` syntax.                 |
| `author`    | `string?`        | from `author:foo`.                       |
| `language`  | `string?`        | BCP 47 tag, e.g. `pt-PT`.                |
| `isbn`      | `string?`        |                                          |
| `format`    | `string?`        | `epub`, `azw3`, `mobi`, `pdf`.           |
| `year`      | `number?`        |                                          |
| `publisher` | `string?`        |                                          |

Plugins consume what they understand and ignore the rest.

### `download(result) -> string | { kind: "browser", url?: string }`

Called when the user clicks Download on a result tile. Two return shapes:

- **String** — a URL Tomo's `URLSession` will fetch directly. Existing behavior; this is what `gutenberg.js` and `libgen.js` return. The plugin's job is to resolve any intermediate "click here to download" pages first.
- **`{ kind: "browser", url?: string }`** — Tomo opens an in-app WKWebView at `url` (or `result.detailURL` if `url` is omitted). The user clicks through whatever the source requires (Cloudflare challenge, countdown timer, partner-server pick), and Tomo's `WKDownload` delegate captures the resulting file and imports it. Use this when the source gates downloads behind interactions that can't be scripted from `fetch()` — e.g. Anna's Archive slow-download partners.

A plugin can return different shapes per call. Anna's Archive's plugin returns a string when a direct mirror (IPFS / libgen) resolves and `{ kind: "browser", url: detailURL }` only when no direct mirror is reachable. A plugin for a source that *always* requires browser verification (e.g. Z-Library) can return the object shape unconditionally.

Backwards compatibility: existing plugins returning strings keep working unchanged.

### Result schema

```js
{
  id: string,                        // opaque to Tomo; plugin-unique
  title: string,
  authors: string[],                 // empty array OK
  year: number | null,
  language: string,                  // BCP 47, or "" if unknown
  format: "epub" | "azw3" | "mobi" | "pdf",
  sizeBytes: number | null,
  coverURL: string | null,           // http(s) or file://
  detailURL: string | null,          // for the "Open in Browser" action
  metadata: Array<{ key: string, value: string }>,  // ordered inspector rows
}
```

Results missing `id` or `title` are dropped.

## Host bindings

Available globally inside the plugin:

### `fetch(url, opts?) -> Promise<Response>`

```js
const r = await fetch("https://example.com/api", {
  method: "GET",                                    // optional, default GET
  headers: { "Accept": "application/json" },        // optional
  body: '{"q":"frankenstein"}',                     // optional, string only
});
// r.status, r.ok, r.headers (lowercased keys), r.body (string), r.url (final URL after redirects)
```

`URLSession`-backed. Sets a desktop Safari user-agent by default. 30s timeout. Body is always returned as a UTF-8 string.

### `querySelectorAll(html, selector) -> Array<Match>`

```js
const items = querySelectorAll(html, "li.booklink span.title");
// each match: { text: string, attrs: Record<string, string>, html: string }
```

SwiftSoup-backed. The `html` field is the matched element's *inner* HTML, so you can re-query inside it. Bare `<tr>`/`<td>`/`<th>` fragments are auto-wrapped in a `<table>` so the parser doesn't drop them.

### `cacheImage(url, opts?) -> Promise<string>`

```js
const path = await cacheImage("https://example.com/cover.jpg", {
  referer: "https://example.com/",                  // optional
  headers: { "X-Custom": "value" },                 // optional, merged with referer
});
result.coverURL = `file://${path}`;
```

Use this when the cover URL is hotlink-protected (requires Referer / custom headers) or when a plain `fetch` won't do because the host browser would redirect or block. The bytes are written to an on-disk cache. Returns a local path; reject on non-2xx, empty body, or network error.

The bundled `gutenberg.js` doesn't need this — Project Gutenberg covers load directly. The `libgen` plugin uses `cacheImage` because libgen.li's cover CDN requires a `Referer` header.

### `console.log(msg)` / `console.error(msg)`

Logs into Tomo's plugin log. Watch in Console.app (subsystem `com.pdrbrnd.tomo`, category `plugin`).

## Worked example

Project Gutenberg search + download in ~50 lines (see `Tomo/Resources/Plugins/gutenberg.js` for the full file with comments):

```js
const PG_BASE = "https://www.gutenberg.org";

async function search(query) {
  const url = `${PG_BASE}/ebooks/search/?query=${encodeURIComponent(query.text || "")}`;
  const r = await fetch(url);
  if (!r.ok) return [];

  const items = querySelectorAll(r.body, "li.booklink");
  const results = [];
  for (const item of items) {
    const title = querySelectorAll(item.html, "span.title")[0]?.text || "";
    const author = querySelectorAll(item.html, "span.subtitle")[0]?.text || "";
    const href = querySelectorAll(item.html, "a.link")[0]?.attrs?.href || "";
    const id = href.match(/\/ebooks\/(\d+)/)?.[1];
    if (!id || !title) continue;

    results.push({
      id,
      title,
      authors: author ? [author] : [],
      year: null,
      language: "",
      format: "epub",
      sizeBytes: null,
      coverURL: `${PG_BASE}/cache/epub/${id}/pg${id}.cover.medium.jpg`,
      detailURL: `${PG_BASE}${href}`,
      metadata: [
        { key: "Catalogue ID", value: `PG #${id}` },
        { key: "License", value: "Public domain" },
      ],
    });
  }
  return results.slice(0, 30);
}

async function download(result) {
  return `${PG_BASE}/ebooks/${result.id}.epub3.images`;
}
```

## Debugging

- "Reveal Plugins Folder" in the sources popover opens the install location in Finder.
- "Reload" re-evaluates the plugin file.
- A plugin that throws on load surfaces a toast with the JS error.
- `console.log` output goes to Console.app — filter on subsystem `com.pdrbrnd.tomo`, category `plugin`.

## Source of truth

This doc is a guide. The authoritative shapes live in:

- `Tomo/Core/Plugins/PluginResult.swift` — `PluginResult`, `PluginQuery`, `PluginField` structs and the JS↔Swift lift.
- `Tomo/Core/Plugins/PluginHost.swift` — every host binding and its option shape.
- `Tomo/Core/Plugins/PluginSource.swift` — load semantics.

If this doc and the code disagree, the code wins.
