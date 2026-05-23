// Project Gutenberg plugin for Tomo. Shipped inside the app as the
// offline-safe first-launch seed; otherwise updated through the
// `pdrbrnd/tomo-plugins` registry once the user clicks Check for updates.
// Also serves as the reference example for writing your own plugin.
//
// !! HEADS UP !!
// This file is *only* seeded into your plugins folder on first launch
// (when the folder is empty). Once your copy exists, Tomo never overwrites
// it. To pull a newer version: open Settings → Plugins → Check for updates.
// To customise: copy this file to a new filename (e.g. `my-gutenberg.js`)
// in the same folder and edit the copy.
//
// =====================================================================
// Plugin manifest
// =====================================================================
//
// Every plugin declares a top-level `const manifest = { ... }`. Tomo reads
// it after evaluation to render the plugin's identity in Settings and
// (optionally) to gate install on host compatibility via `minAppVersion`.
//
// Required: `id`. Everything else is optional.
//
// `minAppVersion` is a semver string ("1.6.0"). The registry compares it
// against the running Tomo's CFBundleShortVersionString at install/update
// time; mismatches refuse with a clear message.
//
// Notably absent: `version`. The plugin's "what version of itself is this"
// is registry-side metadata (the registry's build script derives it from
// the file's git mtime). Plugin authors don't bump anything.
//
// =====================================================================
// Plugin contract
// =====================================================================
//
// A plugin exports two async functions:
//
//   async function search(query) -> Result[]
//   async function download(result) -> string  (URL for the host to fetch)
//
// `query` shape:
//   { text?: string, title?: string, author?: string, language?: string,
//     year?: string, isbn?: string, format?: string, publisher?: string }
//
// Plugins should bail out early (return []) for query shapes they can't
// handle — e.g. an ISBN-only query when the source has no ISBN index.
// Returning the catalogue's front page is worse than returning nothing.
//
// `Result` shape:
//   {
//     id: string,
//     title: string,
//     authors: string[],
//     year: number | null,
//     language: string,
//     format: "epub" | "azw3" | "mobi" | "pdf",
//     sizeBytes: number | null,
//     coverURL: string | null,
//     detailURL: string | null,
//     metadata: Array<{ key: string, value: string }>
//   }
//
// =====================================================================
// Host bindings
// =====================================================================
//
// fetch(url, opts?) -> Promise<{ status, ok, headers, body, url }>
//   Plain HTTP. `body` is text. Use for HTML scraping, JSON APIs, etc.
//
// querySelectorAll(html, selector) -> Array<{ text, attrs, html }>
//   Lightweight CSS selector parser. Returns each match with its inner
//   text, attribute map, and outer HTML (so you can re-query inside).
//
// cacheImage(url, opts?) -> Promise<string>
//   Fetches `url` through the host (which can set Referer / custom
//   headers) and caches the bytes. Returns a local file path you wrap
//   as `file://<path>` for the result's `coverURL`. Use this when the
//   image is hotlink-protected and won't load from a plain URL.
//   Project Gutenberg covers don't have hotlink protection, so this
//   plugin uses a direct URL.
//   opts: { referer?: string, headers?: Record<string, string> }
//
// console.log(msg), console.error(msg)
//   Logs into Tomo's plugin log (Console.app, subsystem com.pdrbrnd.tomo).
//
// =====================================================================

const manifest = {
  id: "gutenberg",
  name: "Project Gutenberg",
  description:
    "Search and download public-domain books from Project Gutenberg.",
  homepage: "https://www.gutenberg.org",
  author: "Tomo",
  license: "MIT",
  // Minimum Tomo version required to run this plugin. Compared against
  // the host app's CFBundleShortVersionString at install/update time.
  // Bump when the plugin starts relying on a host capability that landed
  // in a newer Tomo release.
  minAppVersion: "1.6.0",
};

const PG_BASE = "https://www.gutenberg.org";

async function search(query) {
  // Project Gutenberg only serves EPUB (their other formats — kindle,
  // plain text, HTML — aren't first-class library imports for Tomo).
  // If the user explicitly asked for a different format, skip the
  // network round-trip and return empty.
  if (query.format && query.format.toLowerCase() !== "epub") return [];

  // PG's search box is free-text only — title / author / subject all
  // funnel through the one `query=` param. ISBN-only or publisher-only
  // queries can't be expressed; without text we'd just GET the front
  // page and return random "results", so bail out.
  const text = [query.text, query.title, query.author]
    .filter((s) => s && s.trim().length > 0)
    .join(" ")
    .trim();
  if (!text) return [];

  const url = `${PG_BASE}/ebooks/search/?query=${encodeURIComponent(text)}`;
  console.log(`fetching ${url}`);
  const r = await fetch(url);
  console.log(`status ${r.status}, ${r.body.length} bytes`);
  if (!r.ok) return [];

  // Project Gutenberg's results live in <li class="booklink"> with nested
  // .title and .subtitle. The link's href is /ebooks/<id>.
  const items = querySelectorAll(r.body, "li.booklink");
  console.log(`found ${items.length} raw items`);

  const results = [];
  for (const item of items) {
    const titles = querySelectorAll(item.html, "span.title");
    const authors = querySelectorAll(item.html, "span.subtitle");
    const links = querySelectorAll(item.html, "a.link");

    const title = titles[0]?.text || "";
    const author = authors[0]?.text || "";
    const href = links[0]?.attrs?.href || "";
    if (!title || !href) continue;

    const idMatch = href.match(/\/ebooks\/(\d+)/);
    if (!idMatch) continue;
    const id = idMatch[1];

    // PG covers live at a predictable cache path. Most books have one;
    // the URL 404s for those that don't and the app's typography
    // fallback takes over — no special handling needed here.
    const coverURL = `${PG_BASE}/cache/epub/${id}/pg${id}.cover.medium.jpg`;

    results.push({
      id,
      title,
      authors: author ? [author] : [],
      year: null,
      language: "",
      format: "epub",
      sizeBytes: null,
      coverURL,
      detailURL: `${PG_BASE}${href}`,
      metadata: [
        { key: "Catalogue ID", value: `PG #${id}` },
        { key: "License", value: "Public domain" },
      ],
    });
  }
  console.log(`returning ${results.length} parsed results`);
  return results;
}

async function download(result) {
  // Project Gutenberg EPUB direct URL pattern: /ebooks/<id>.epub3.images
  const url = `${PG_BASE}/ebooks/${result.id}.epub3.images`;
  console.log(`download URL: ${url}`);
  return url;
}
