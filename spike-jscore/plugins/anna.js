// Anna's Archive scraper — Phase 1b validation target.
// First pass: probe-mode. Logs heavily so we can see Cloudflare challenges,
// HTML structure, and download-link availability.

// Note: annas-archive.org returns NXDOMAIN globally (via Cloudflare DoH 2026-05-04).
// annas-archive.li is squatted. annas-archive.io is the working mirror.
// A productionised plugin should auto-failover across known mirrors.
const BASE = "https://annas-archive.io";

async function search(query) {
    const text = (query.text || "").trim();
    if (!text) return [];

    const lang = query.language ? `&lang=${encodeURIComponent(query.language)}` : "";
    const url = `${BASE}/search?q=${encodeURIComponent(text)}&ext=epub${lang}`;
    console.log(`fetching ${url}`);
    const r = await fetch(url);
    console.log(`status ${r.status}, ${r.body.length} bytes, final url: ${r.url}`);

    // Cloudflare challenge detection
    if (r.body.includes("Just a moment") || r.body.includes("__cf_chl_") || r.body.includes("cf-mitigated")) {
        console.error("⚠ Cloudflare challenge detected");
        return [];
    }
    if (!r.ok) {
        console.error(`search failed: status ${r.status}`);
        return [];
    }

    // Anna's results are anchors `<a href="/md5/<hash>">` wrapping the result card.
    // The card itself contains the title, author, and a meta line with year/lang/format/size.
    const anchors = querySelectorAll(r.body, "a[href^='/md5/']");
    console.log(`found ${anchors.length} md5 anchors`);

    const results = [];
    const seen = new Set();
    for (const a of anchors) {
        const href = a.attrs.href || "";
        const id = href.replace("/md5/", "").trim();
        if (!id || seen.has(id)) continue;
        seen.add(id);

        // Extract title and author from the card's nested HTML.
        // Anna's titles are in elements with classes like "text-xl" or "italic" — but those
        // change. Lenient approach: grab the longest text run and treat it as the title.
        const html = a.html || "";
        const lines = (a.text || "")
            .split(/\s{2,}|\n/)
            .map(s => s.trim())
            .filter(Boolean);

        // Heuristic: first non-empty line is metadata (size/year/lang/format), then title, then authors.
        // We'll be lenient and let the user inspect logs.
        const title = lines.find(l => l.length > 5 && !/^\d+(\.\d+)?\s?(MB|KB|GB)/i.test(l)) || lines[0] || "(unknown)";
        const meta = lines.find(l => /\d+(\.\d+)?\s?(MB|KB|GB)/i.test(l)) || "";
        const sizeMatch = meta.match(/(\d+(?:\.\d+)?)\s?(MB|KB|GB)/i);
        let sizeBytes = null;
        if (sizeMatch) {
            const n = parseFloat(sizeMatch[1]);
            const unit = sizeMatch[2].toUpperCase();
            sizeBytes = Math.round(n * (unit === "GB" ? 1e9 : unit === "MB" ? 1e6 : 1e3));
        }
        const yearMatch = meta.match(/\b(1[89]\d{2}|20\d{2})\b/);
        const year = yearMatch ? parseInt(yearMatch[1], 10) : null;
        const langMatch = meta.match(/\b([a-z]{2}(?:-[A-Z]{2})?)\b/);
        const language = langMatch ? langMatch[1] : "";
        const formatMatch = meta.match(/\b(epub|pdf|azw3|mobi|djvu)\b/i);
        const format = (formatMatch ? formatMatch[1] : "epub").toLowerCase();

        // Try to find author line — usually after title in the card.
        const authorIdx = lines.indexOf(title) + 1;
        const authorLine = authorIdx < lines.length ? lines[authorIdx] : "";
        const authors = authorLine && authorLine !== meta
            ? authorLine.split(/[;,]| and /i).map(s => s.trim()).filter(Boolean)
            : [];

        results.push({
            id,
            title,
            authors,
            year,
            language,
            format,
            sizeBytes,
            coverURL: null,
            detailURL: `${BASE}${href}`,
            metadata: { meta, _rawText: a.text.slice(0, 200) },
        });
    }
    console.log(`returning ${results.length} parsed results`);
    return results.slice(0, 30);
}

async function download(result) {
    console.log(`fetching detail page: ${result.detailURL}`);
    const r = await fetch(result.detailURL);
    console.log(`detail status ${r.status}, ${r.body.length} bytes`);
    if (r.body.includes("Just a moment") || r.body.includes("__cf_chl_")) {
        throw new Error("cloudflare challenge on detail page");
    }
    if (!r.ok) throw new Error(`detail page status ${r.status}`);

    // Anna's detail pages list "fast partner" + "slow partner" download links.
    // Slow links typically go to /slow_download/<hash>/<n>/<m> on annas-archive.org itself.
    // Fast links require a donor account and go to download.books.ms or similar.
    // For the spike, we surface ALL plausible links and pick the first slow one.
    const links = querySelectorAll(r.body, "a[href]");
    console.log(`found ${links.length} anchors on detail page`);

    const candidates = [];
    for (const link of links) {
        const href = link.attrs.href || "";
        const text = (link.text || "").toLowerCase();
        if (href.startsWith("/slow_download/") || href.includes("slow_download")) {
            candidates.push({ kind: "slow", href, text });
        } else if (href.startsWith("/fast_download/")) {
            candidates.push({ kind: "fast", href, text });
        } else if (text.includes("download") && (href.startsWith("http") || href.startsWith("/"))) {
            candidates.push({ kind: "other", href, text });
        }
    }
    console.log(`download candidates: ${candidates.length}`);
    for (const c of candidates.slice(0, 8)) {
        console.log(`  [${c.kind}] ${c.href}  (${c.text.slice(0, 60)})`);
    }

    const slow = candidates.find(c => c.kind === "slow");
    if (!slow) throw new Error("no slow_download link found on detail page");

    const slowURL = slow.href.startsWith("http") ? slow.href : `${BASE}${slow.href}`;
    console.log(`fetching slow_download intermediate: ${slowURL}`);
    const r2 = await fetch(slowURL);
    console.log(`slow status ${r2.status}, ${r2.body.length} bytes, final url: ${r2.url}`);

    // The slow_download page typically has a countdown then a "Download now" link.
    // Anna's puts a direct link in an anchor on this page (sometimes after JS countdown,
    // but the URL itself is in the HTML).
    const r2Links = querySelectorAll(r2.body, "a[href]");
    let directURL = null;
    for (const link of r2Links) {
        const href = link.attrs.href || "";
        const text = (link.text || "").toLowerCase();
        // Direct file links typically have the file extension in the URL
        if (/\.(epub|pdf|azw3|mobi|djvu)(\?|$)/i.test(href)) {
            directURL = href.startsWith("http") ? href : `${BASE}${href}`;
            console.log(`direct file URL: ${directURL}`);
            break;
        }
        if (text.includes("download now") || text.includes("click here")) {
            directURL = href.startsWith("http") ? href : `${BASE}${href}`;
            console.log(`download-now link: ${directURL}`);
            break;
        }
    }
    if (!directURL) {
        // Sometimes the URL is in the body text, not in an anchor (countdown then redirect).
        // Last resort: log a snippet so we can see what the page looks like.
        console.error("no direct file URL on slow_download page");
        console.error("first 500 chars: " + r2.body.slice(0, 500));
        throw new Error("could not find file URL on slow_download page");
    }
    return directURL;
}
