// Project Gutenberg plugin for Tomo. Bundled with the app and seeded
// into the user's plugins folder on first launch — also serves as a
// reference example for writing your own plugin.
//
// =====================================================================
// Plugin contract
// =====================================================================
//
// A plugin is a single .js file that exports two async functions:
//
//   async function search(query) -> Result[]
//   async function download(result) -> string  (URL for the host to fetch)
//
// `query` shape:
//   { text?: string, title?: string, author?: string, language?: string,
//     year?: string, isbn?: string }
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
//   image is hotlink-protected and won't load from a plain URL — see
//   the libgen plugin for a real example. Project Gutenberg covers
//   don't have hotlink protection, so this plugin uses a direct URL.
//   opts: { referer?: string, headers?: Record<string, string> }
//
// console.log(msg), console.error(msg)
//   Logs into Tomo's plugin log (Console.app, subsystem com.pdrbrnd.tomo).
//
// =====================================================================

const PG_BASE = "https://www.gutenberg.org";

async function search(query) {
    // Project Gutenberg only serves EPUB (their other formats — kindle,
    // plain text, HTML — aren't first-class library imports for Tomo).
    // If the user explicitly asked for a different format, skip the
    // network round-trip and return empty.
    if (query.format && query.format.toLowerCase() !== "epub") return [];

    const url = `${PG_BASE}/ebooks/search/?query=${encodeURIComponent(query.text || "")}`;
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
    return results.slice(0, 30);
}

async function download(result) {
    // Project Gutenberg EPUB direct URL pattern: /ebooks/<id>.epub3.images
    const url = `${PG_BASE}/ebooks/${result.id}.epub3.images`;
    console.log(`download URL: ${url}`);
    return url;
}
