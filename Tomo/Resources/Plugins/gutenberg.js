// Project Gutenberg plugin for Tomo. Bundled as the offline-safe first-
// launch seed; otherwise served from the `pdrbrnd/tomo-plugins` registry.
// Reference example — see docs/plugins.md for the full contract and
// docs/CONTRACT.md for host capabilities per app version.

const manifest = {
  id: "gutenberg",
  name: "Project Gutenberg",
  description:
    "Search and download public-domain books from Project Gutenberg.",
  homepage: "https://www.gutenberg.org",
  author: "Tomo",
  license: "MIT",
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
