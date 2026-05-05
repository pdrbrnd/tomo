// Library Genesis (libgen.li) plugin for Tomo's source-plugin spike.
//
// Plain HTTP throughout — no Cloudflare bypass, no DDoS-Guard challenge,
// no login wall. Search and download flows verified end-to-end:
//   1. search() → libgen.li/index.php?req=...&ext=epub  (HTML table)
//   2. download() → libgen.li/ads.php?md5=...           (intermediate page
//      with a single <a href="get.php?md5=...&key=...">GET</a>)
//   3. The returned get.php URL 307-redirects to a CDN
//      (cdn3.booksdl.lc) which serves application/octet-stream with a
//      content-disposition filename. The app's URLSession.shared.download
//      follows the redirect transparently.
//
// libgen.li doesn't filter by language at the URL level — when the query has
// `language:xx`, we filter the results client-side after parsing.

const BASE = "https://libgen.li";

async function search(query) {
    // Build the `req` text from all query fields. libgen does full-text
    // matching across selected columns; we just stack the words and let it
    // handle them.
    const reqParts = [];
    if (query.text) reqParts.push(query.text);
    if (query.title) reqParts.push(query.title);
    if (query.author) reqParts.push(query.author);
    if (query.publisher) reqParts.push(query.publisher);
    if (query.isbn) reqParts.push(query.isbn);
    if (query.year) reqParts.push(String(query.year));
    const req = reqParts.join(" ").trim();
    if (!req) return [];

    // JSCore doesn't ship URLSearchParams — build the query string manually.
    // columns[]: which fields libgen searches in. t/a/p/i = title/author/
    // publisher/isbn. objects[]: files + editions. topics[]: libgen general
    // + fiction (skip articles, magazines, scimag).
    const qsParts = [];
    function add(k, v) {
        qsParts.push(`${encodeURIComponent(k)}=${encodeURIComponent(v)}`);
    }
    add("req", req);
    for (const c of ["t", "a", "p", "i"]) add("columns[]", c);
    for (const o of ["f", "e"]) add("objects[]", o);
    for (const t of ["l", "f"]) add("topics[]", t);
    if (query.format) add("ext", query.format);
    add("res", "25");

    const url = `${BASE}/index.php?${qsParts.join("&")}`;
    const r = await fetch(url);
    if (!r.ok) {
        console.error(`search failed: status ${r.status}`);
        return [];
    }

    // Each result is a <tr> in the .table-striped result table. The first
    // <tr> is the header — we just check for ≥9 <td> cells per row to skip
    // it, since the header has fewer (or different) cells.
    const rows = querySelectorAll(r.body, "table.table-striped tr");
    const parsedRows = [];
    for (const row of rows) {
        const cells = querySelectorAll(row.html, "td");
        if (cells.length < 9) continue;

        // Title cell: first <a href="edition.php?id=..."> is the canonical
        // title link; its text is the title. The secondary badge ("f 1234567")
        // carries the file id we need to compute the cover URL bucket.
        const titleAnchors = querySelectorAll(cells[0].html, "a[href*='edition.php']");
        if (titleAnchors.length === 0) continue;
        const title = titleAnchors[0].text.trim();
        if (!title) continue;
        const editionHref = titleAnchors[0].attrs.href || "";
        const editionMatch = editionHref.match(/edition\.php\?id=(\d+)/);
        const editionId = editionMatch ? editionMatch[1] : null;

        const fileBadges = querySelectorAll(cells[0].html, "span.badge-secondary");
        const fileMatch = fileBadges[0]?.text?.match(/(\d+)/);
        const fileId = fileMatch ? parseInt(fileMatch[1], 10) : null;

        const authorsText = (cells[1].text || "").trim();
        const authors = authorsText
            ? authorsText.split(/[,;]/).map(s => s.trim()).filter(Boolean)
            : [];
        const publisher = (cells[2].text || "").trim();
        const yearText = (cells[3].text || "").trim();
        const year = parseInt(yearText, 10);
        const languageRaw = (cells[4].text || "").trim();
        const sizeBytes = parseSize((cells[6].text || "").trim());
        const format = (cells[7].text || "").trim().toLowerCase();

        // 9th cell is the mirror list. The first /ads.php?md5= link gives us
        // the canonical libgen md5, which we use as the result id and to
        // build the download flow.
        const mirrorAnchors = querySelectorAll(cells[8].html, "a[href*='/ads.php?md5=']");
        const firstMirrorHref = mirrorAnchors[0]?.attrs?.href || "";
        const md5Match = firstMirrorHref.match(/md5=([a-f0-9]{32})/i);
        if (!md5Match) continue;
        const md5 = md5Match[1];

        // Client-side language filter — libgen.li doesn't expose one at the
        // URL level, so we filter after parsing.
        if (query.language && languageRaw && !matchesLanguage(languageRaw, query.language)) {
            continue;
        }

        parsedRows.push({
            fileId,
            result: {
                id: md5,
                title,
                authors,
                year: Number.isFinite(year) ? year : null,
                language: normalizeLanguage(languageRaw),
                format: format || "epub",
                sizeBytes,
                coverURL: null,  // populated below via libgen's cover server when present
                detailURL: editionId
                    ? `${BASE}/edition.php?id=${editionId}`
                    : `${BASE}/ads.php?md5=${md5}`,
                metadata: [
                    publisher && { key: "Publisher", value: publisher },
                    languageRaw && { key: "Original language", value: languageRaw },
                    editionId && { key: "Edition ID", value: editionId },
                    { key: "MD5", value: md5 },
                ].filter(Boolean),
            },
        });

        if (parsedRows.length >= 30) break;
    }

    // libgen's own covers live at /fictioncovers/<bucket>/<md5>.jpg where
    // bucket = floor(file_id / 1000) * 1000. Both pieces are already in the
    // row, so the URL is built without any extra HTTP. The cover server
    // requires a Referer header pointing at libgen.li (hotlink check) — the
    // app's `cacheImage` binding handles that and returns a local file path.
    // Failures (no cover for this entry, content-length 0, etc.) leave
    // coverURL null and the app's iTunes/OL enricher fills the gap.
    await Promise.all(parsedRows.map(async ({ fileId, result }) => {
        if (!fileId) return;
        const bucket = Math.floor(fileId / 1000) * 1000;
        const url = `${BASE}/fictioncovers/${bucket}/${result.id}.jpg`;
        try {
            const path = await cacheImage(url, { referer: `${BASE}/` });
            if (path) result.coverURL = `file://${path}`;
        } catch (_) {
            // no libgen cover for this entry — app-side enricher will try
            // iTunes / Open Library next.
        }
    }));
    return parsedRows.map(p => p.result);
}

async function download(result) {
    // result.id is the md5. The ads.php page has a single
    // <a href="get.php?md5=...&key=...">GET</a> which 307-redirects to the
    // actual file on the CDN.
    const adsURL = `${BASE}/ads.php?md5=${result.id}`;
    console.log(`fetching ads: ${adsURL}`);
    const r = await fetch(adsURL);
    if (!r.ok) throw new Error(`ads.php returned ${r.status}`);

    const getLinks = querySelectorAll(r.body, "a[href*='get.php?md5=']");
    if (getLinks.length === 0) {
        throw new Error("no get.php link found on ads page");
    }
    const href = getLinks[0].attrs.href || "";
    if (href.startsWith("http")) return href;
    if (href.startsWith("/")) return `${BASE}${href}`;
    return `${BASE}/${href}`;
}

// ---- helpers ----

function parseSize(text) {
    if (!text) return null;
    const m = text.match(/([\d.]+)\s*(KB|MB|GB|kB|B)/i);
    if (!m) return null;
    const n = parseFloat(m[1]);
    const unit = m[2].toUpperCase();
    if (unit === "GB") return Math.round(n * 1e9);
    if (unit === "MB") return Math.round(n * 1e6);
    if (unit === "KB" || unit === "kB".toUpperCase()) return Math.round(n * 1e3);
    return Math.round(n);
}

// libgen returns full language names ("English", "Spanish", "Portuguese").
// Map the common ones to BCP 47 base codes so the app's locale handling
// works uniformly. Anything we don't know falls back to the first two
// letters lowercased — wrong for some scripts but harmless.
function normalizeLanguage(libgenLang) {
    if (!libgenLang) return "";
    const lower = libgenLang.toLowerCase().trim();
    const map = {
        english: "en", spanish: "es", portuguese: "pt", french: "fr",
        german: "de", italian: "it", japanese: "ja", chinese: "zh",
        russian: "ru", polish: "pl", dutch: "nl", swedish: "sv",
        norwegian: "no", danish: "da", finnish: "fi", korean: "ko",
        arabic: "ar", hebrew: "he", greek: "el", turkish: "tr",
        czech: "cs", hungarian: "hu", romanian: "ro", ukrainian: "uk",
        catalan: "ca", galician: "gl", basque: "eu",
    };
    return map[lower] || lower.slice(0, 2);
}

function matchesLanguage(libgenLang, queryLang) {
    const norm = normalizeLanguage(libgenLang);
    const q = queryLang.toLowerCase().split(/[-_]/)[0];
    return norm === q;
}
