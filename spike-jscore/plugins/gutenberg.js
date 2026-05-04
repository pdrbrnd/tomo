// Project Gutenberg plugin for Tomo's source-plugin spike.
//
// Demonstrates the full contract:
//   - fetch + querySelectorAll for parsing search HTML
//   - coverURL: built from PG's predictable cache path; falls back to the
//     app's typography placeholder if a given book has no cover image
//   - metadata: ordered [{key, value}] pairs surfaced as inspector rows
//     below the canonical Format/Language/Size/Source rows
//
// Plugin contract reference (Swift side: PluginResult.swift):
//   search(query) -> [{ id, title, authors, year, language, format,
//                       sizeBytes, coverURL, detailURL, metadata }]
//   download(result) -> URL string

const PG_BASE = "https://www.gutenberg.org";

async function search(query) {
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
