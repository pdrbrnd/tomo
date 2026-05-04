// SMOKE-TEST PLUGIN.
// First pass — exercises fetch + querySelectorAll against a stable, friendly site
// to validate the architecture end-to-end before tackling Anna's Archive specifics.
// Once this works, replace the body with a real Anna's Archive scraper.

const PG_BASE = "https://www.gutenberg.org";

async function search(query) {
    const url = `${PG_BASE}/ebooks/search/?query=${encodeURIComponent(query.text || "")}`;
    console.log(`fetching ${url}`);
    const r = await fetch(url);
    console.log(`status ${r.status}, ${r.body.length} bytes`);
    if (!r.ok) return [];

    // Project Gutenberg's results live in <li class="booklink"> with nested .title and .subtitle.
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

        results.push({
            id,
            title,
            authors: author ? [author] : [],
            year: null,
            language: "",
            format: "epub",
            sizeBytes: null,
            coverURL: null,
            detailURL: `${PG_BASE}${href}`,
            metadata: { source: "project-gutenberg" },
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
