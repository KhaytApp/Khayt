// What a model page says about itself — read out of a Document, and nothing else.
//
// ── PURE, ON PURPOSE ──────────────────────────────────────────────────────
//
// Every function here takes a Document and the page's address and returns
// plain data. No `chrome.*`, no network, no globals: the popup runs them over
// the page it was handed (`snapshot.js`), and `test/webext-adapters.test.js`
// runs the very same functions over small HTML fixtures under jsdom. A site
// that changes its markup breaks a fixture here, not a shop's save.
//
// ── WHAT IS READ ──────────────────────────────────────────────────────────
//
// The generic reader comes first and every site reader starts from it: the
// canonical link, JSON-LD (`Product`, `3DModel`, `CreativeWork`), Open Graph
// and the ordinary meta tags. A site reader then fills what its own markup
// says better — MakerWorld's page data, Printables' tag links, a creator's
// profile link. A field nobody could read is left empty; the app treats empty
// as "not said", never as a value.
//
// Khayt checks everything again on its side (`WebSave` in the Mac app), so the
// caps here are about keeping the message small, not about trust.

export const MAX_TITLE = 200;
export const MAX_CREATOR = 120;
export const MAX_DESCRIPTION = 600;
export const MAX_TAGS = 20;
export const MAX_FILES = 20;

/** The model file kinds a download link is recognised by. */
export const MODEL_EXTS = ['3mf', 'stl', 'obj', 'step', 'stp', 'zip', '7z', 'rar', 'gcode', 'bgcode', 'ply', 'amf', 'f3d', 'blend'];

/** Which site an address is on — by host, the same rule as `WebSave.Site.of`. */
export function siteOf(address) {
  let host = '';
  try { host = new URL(address).hostname.toLowerCase(); } catch { return 'web'; }
  if (host.startsWith('www.')) host = host.slice(4);
  const under = (d) => host === d || host.endsWith('.' + d);
  if (under('printables.com')) return 'printables';
  if (under('makerworld.com') || under('makerworld.com.cn')) return 'makerworld';
  if (under('thingiverse.com')) return 'thingiverse';
  if (under('thangs.com')) return 'thangs';
  if (under('cults3d.com')) return 'cults3d';
  if (under('myminifactory.com')) return 'myminifactory';
  return 'web';
}

/**
 * The part of a host a site owns: `www.printables.com` → `printables.com`,
 * `shop.example.co.uk` → `example.co.uk`. Without the full public-suffix list,
 * a two-letter country ending under a generic second level (`co`, `com`,
 * `org`…) counts as one suffix. An address is itself.
 */
export function registrable(host) {
  const h = String(host || '').toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');
  if (!h || /^[\d.]+$/.test(h) || h.includes(':')) return h;
  const labels = h.split('.');
  if (labels.length <= 2) return h;
  const second = labels[labels.length - 2];
  const tld = labels[labels.length - 1];
  const keep = tld.length === 2 && ['co', 'com', 'net', 'org', 'gov', 'edu', 'ac', 'or', 'ne', 'go'].includes(second) ? 3 : 2;
  return labels.slice(-keep).join('.');
}

/** Two addresses on the same site (registrable domain). */
export function sameSite(a, b) {
  try { return registrable(new URL(a).hostname) === registrable(new URL(b).hostname); } catch { return false; }
}

// ── Small helpers ─────────────────────────────────────────────────────────

/** One line of text: white space collapsed, trimmed, cut at `max`. */
export function oneLine(value, max = 500) {
  return String(value == null ? '' : value).replace(/[\u0000-\u001f\u007f\s]+/g, ' ').trim().slice(0, max).trim();
}

/** Text with markup taken out — for descriptions that arrive as HTML. */
export function plainText(html, doc) {
  const s = String(html == null ? '' : html);
  if (!/[<&]/.test(s)) return s;
  // Parsed in an inert document of its own: nothing in it loads or runs.
  const inert = doc.implementation.createHTMLDocument('');
  const box = inert.createElement('div');
  // A paragraph or a line break is a new line in the excerpt, not a run-on.
  box.innerHTML = s.replace(/<(br|\/p|\/li|\/div|\/h[1-6])\b[^>]*>/gi, '\n$&');
  return box.textContent || '';
}

/** An excerpt for the record: paragraphs kept, the rest of the white space folded. */
export function excerpt(value, max = MAX_DESCRIPTION) {
  const text = String(value == null ? '' : value)
    .split(/\n+/).map((l) => oneLine(l, max)).filter(Boolean).join('\n');
  if (text.length <= max) return text;
  const cut = text.slice(0, max - 1);
  const space = cut.lastIndexOf(' ');
  return (space > max * 0.6 ? cut.slice(0, space) : cut).trim() + '…';
}

/** An absolute https address, or ''. */
export function httpsUrl(value, base) {
  if (!value) return '';
  try {
    const u = new URL(String(value).trim(), base);
    if (u.protocol !== 'https:' || !u.hostname || u.username || u.password) return '';
    u.hash = '';
    return u.href.length <= 2048 ? u.href : '';
  } catch { return ''; }
}

function meta(doc, ...names) {
  for (const n of names) {
    const el = doc.querySelector(`meta[property="${n}"], meta[name="${n}"], meta[itemprop="${n}"]`);
    const v = el && el.getAttribute('content');
    if (v && v.trim()) return v.trim();
  }
  return '';
}

function metaAll(doc, name) {
  return [...doc.querySelectorAll(`meta[property="${name}"], meta[name="${name}"]`)]
    .map((m) => (m.getAttribute('content') || '').trim()).filter(Boolean);
}

function textOf(el) { return el ? oneLine(el.textContent) : ''; }

function uniqueTags(list) {
  const out = []; const seen = new Set();
  for (const raw of list) {
    const t = oneLine(String(raw || '').replace(/^#/, ''), 40);
    const k = t.toLowerCase();
    if (!t || seen.has(k)) continue;
    seen.add(k); out.push(t);
    if (out.length === MAX_TAGS) break;
  }
  return out;
}

// ── Licences ──────────────────────────────────────────────────────────────

/**
 * A licence as Khayt's own id (`cc-by-nc-sa`, `cc0`) when it is a Creative
 * Commons one this can name, or the page's own words. Khayt's `ModelLicence`
 * translates only what it is sure of, so passing the words is always safe.
 */
export function licenceId(value) {
  const raw = oneLine(value, 200);
  if (!raw) return '';
  const s = raw.toLowerCase();
  const url = s.match(/creativecommons\.org\/(licenses|publicdomain)\/([a-z-]+)/);
  if (url) {
    if (url[1] === 'publicdomain') return 'cc0';
    const clauses = url[2].split('-').filter((c) => ['by', 'nc', 'sa', 'nd'].includes(c));
    if (clauses[0] === 'by') return 'cc-' + clauses.join('-');
  }
  if (/\bcc0\b|public domain/.test(s)) return 'cc0';
  const short = s.match(/\bcc[\s-]?(by(?:[\s-](?:nc|sa|nd))*)\b/);
  if (short) return 'cc-' + short[1].replace(/\s/g, '-');
  // A bare clause list, as MakerWorld writes it: `BY-NC-SA`.
  const bare = s.match(/^(by(?:[\s-](?:nc|sa|nd))*)(?:[\s-]\d\.\d)?$/);
  if (bare) return 'cc-' + bare[1].replace(/\s/g, '-');
  if (/creative\s*commons/.test(s)) {
    const parts = ['by'];
    if (/non[\s-]?commercial/.test(s)) parts.push('nc');
    if (/share[\s-]?alike/.test(s)) parts.push('sa');
    if (/no[\s-]?deriv/.test(s)) parts.push('nd');
    if (/attribution|\bby\b/.test(s) || parts.length > 1) return 'cc-' + parts.join('-');
  }
  return raw;
}

/** The first Creative Commons link on the page, as an id, or ''. */
function ccLink(doc) {
  const a = doc.querySelector('a[href*="creativecommons.org/licenses/"], a[href*="creativecommons.org/publicdomain/"], link[rel="license"]');
  return a ? licenceId(a.getAttribute('href')) : '';
}

// ── JSON-LD ───────────────────────────────────────────────────────────────

/** Every JSON-LD object on the page, `@graph`s flattened. Bad JSON is skipped. */
export function jsonLd(doc) {
  const out = [];
  const visit = (v) => {
    if (Array.isArray(v)) { v.forEach(visit); return; }
    if (!v || typeof v !== 'object') return;
    out.push(v);
    if (Array.isArray(v['@graph'])) v['@graph'].forEach(visit);
  };
  for (const s of doc.querySelectorAll('script[type="application/ld+json"]')) {
    try { visit(JSON.parse(s.textContent)); } catch { /* not ours to fix */ }
  }
  return out;
}

const MODEL_TYPES = ['3dmodel', 'product', 'creativework', 'thing', 'sculpture', 'visualartwork', 'dataset'];

function typesOf(o) {
  const t = o['@type'];
  return (Array.isArray(t) ? t : [t]).map((x) => String(x || '').toLowerCase());
}

function nameOf(v) {
  if (!v) return '';
  if (typeof v === 'string') return oneLine(v, MAX_CREATOR);
  if (Array.isArray(v)) return nameOf(v[0]);
  return oneLine(v.name || v.alternateName || '', MAX_CREATOR);
}

function imageOf(v) {
  if (!v) return '';
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) return imageOf(v[0]);
  return v.url || v.contentUrl || '';
}

// ── Download links ────────────────────────────────────────────────────────

function extOf(pathname) {
  const m = String(pathname || '').toLowerCase().match(/\.([a-z0-9]{1,6})$/);
  return m ? m[1] : '';
}

/** Links on the page that point straight at a model file. */
export function fileLinks(doc, base) {
  const out = []; const seen = new Set();
  for (const a of doc.querySelectorAll('a[href]')) {
    const href = httpsUrl(a.getAttribute('href'), base);
    if (!href || seen.has(href)) continue;
    let path = '';
    try { path = new URL(href).pathname; } catch { continue; }
    const named = oneLine(a.getAttribute('download') || '', 200);
    const ext = extOf(path) || extOf(named);
    if (!MODEL_EXTS.includes(ext)) continue;
    seen.add(href);
    let name = named || decodeURIComponent(path.split('/').pop() || '');
    out.push({ url: href, name: oneLine(name, 200) });
    if (out.length === MAX_FILES) break;
  }
  return out;
}

// ── The generic reader ────────────────────────────────────────────────────

/** Strip a site's own name off a page title: "Dragon | Printables.com" → "Dragon". */
export function cleanTitle(title, siteWords = []) {
  let t = oneLine(title, 400);
  for (const w of siteWords) {
    const re = new RegExp(`\\s*[|\\-–—·:]\\s*[^|\\-–—·:]*${w}[^|]*$`, 'i');
    t = t.replace(re, '');
  }
  return t.slice(0, MAX_TITLE).trim();
}

export function generic(doc, pageUrl) {
  // The page's own claim of its address counts only on the tab's own site: a
  // mirror calling itself printables.com/model/123 would otherwise be saved
  // as that model, and overwrite the shop's record of it.
  const own = (u) => (u && sameSite(u, pageUrl) ? u : null);
  const canonical = own(httpsUrl(doc.querySelector('link[rel="canonical"]')?.getAttribute('href'), pageUrl))
    || own(httpsUrl(meta(doc, 'og:url'), pageUrl)) || httpsUrl(pageUrl);
  const site = siteOf(canonical || pageUrl);
  const ld = jsonLd(doc);
  const model = ld.find((o) => typesOf(o).some((t) => MODEL_TYPES.includes(t))) || {};
  const keywords = Array.isArray(model.keywords) ? model.keywords
    : String(model.keywords || meta(doc, 'keywords') || '').split(',');
  const title = oneLine(model.name || meta(doc, 'og:title', 'twitter:title') || doc.title, MAX_TITLE);
  return {
    url: canonical,
    site,
    title,
    creator: nameOf(model.author || model.creator || model.brand) || oneLine(meta(doc, 'author', 'article:author'), MAX_CREATOR),
    licence: licenceId(typeof model.license === 'string' ? model.license : (model.license && model.license.url) || '') || ccLink(doc),
    description: excerpt(plainText(model.description || meta(doc, 'og:description', 'description', 'twitter:description'), doc)),
    tags: uniqueTags([...keywords, ...metaAll(doc, 'article:tag')]),
    cover: httpsUrl(imageOf(model.image) || meta(doc, 'og:image', 'og:image:url', 'twitter:image'), canonical || pageUrl),
    files: fileLinks(doc, canonical || pageUrl),
  };
}

/** `over` wins wherever it says something; `base` fills the rest. */
function merge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over)) {
    if (Array.isArray(v) ? v.length : v) out[k] = v;
  }
  return out;
}

/** Tag links on the page whose address matches `pattern`. */
function tagLinks(doc, selector) {
  return uniqueTags([...doc.querySelectorAll(selector)].map(textOf));
}

/** "Name by Creator" → [Name, Creator]. */
function splitBy(title) {
  const m = String(title || '').match(/^(.*\S)\s+by\s+(\S.*)$/i);
  return m ? [m[1].trim(), m[2].trim()] : [String(title || ''), ''];
}

// ── The sites ─────────────────────────────────────────────────────────────

export function printables(doc, pageUrl) {
  const base = generic(doc, pageUrl);
  const [name, by] = splitBy(cleanTitle(meta(doc, 'og:title') || doc.title, ['Printables', 'Download free']));
  const creatorLink = doc.querySelector('a[href^="/@"], a[href*="printables.com/@"]');
  return merge(base, {
    title: oneLine(doc.querySelector('h1')?.textContent || name, MAX_TITLE),
    creator: textOf(creatorLink) || by,
    licence: ccLink(doc) || licenceId(textOf(doc.querySelector('[class*="license"] a, [class*="licence"] a, [class*="license"]'))),
    tags: tagLinks(doc, 'a[href*="/tag/"]'),
  });
}

export function makerworld(doc, pageUrl) {
  const base = generic(doc, pageUrl);
  let design = null;
  try {
    const data = JSON.parse(doc.getElementById('__NEXT_DATA__')?.textContent || 'null');
    design = data && data.props && data.props.pageProps && data.props.pageProps.design;
  } catch { /* the page's own data is optional */ }
  if (!design || typeof design !== 'object') {
    return merge(base, { title: cleanTitle(base.title, ['MakerWorld']) });
  }
  const tags = Array.isArray(design.tags) ? design.tags.map((t) => (typeof t === 'string' ? t : t && t.name)) : [];
  const creator = design.designCreator || design.creator || {};
  return merge(base, {
    title: oneLine(design.title || design.name, MAX_TITLE),
    creator: oneLine(creator.name || creator.nickname || '', MAX_CREATOR),
    licence: licenceId(design.license || design.licence || ''),
    description: excerpt(plainText(design.summary || design.description || '', doc)),
    tags: uniqueTags(tags),
    cover: httpsUrl(design.coverUrl || design.cover || '', pageUrl),
  });
}

export function thingiverse(doc, pageUrl) {
  const base = generic(doc, pageUrl);
  const [name, by] = splitBy(cleanTitle(meta(doc, 'og:title') || doc.title, ['Thingiverse']));
  const creatorLink = doc.querySelector('a[href*="/designs"], a[class*="creator"], a[class*="Creator"]');
  return merge(base, {
    title: name,
    creator: textOf(creatorLink) || by,
    licence: ccLink(doc) || licenceId(textOf(doc.querySelector('[class*="License"], [class*="license"]'))),
    tags: tagLinks(doc, 'a[href*="/tag:"]'),
  });
}

export function thangs(doc, pageUrl) {
  const base = generic(doc, pageUrl);
  const [name, by] = splitBy(cleanTitle(meta(doc, 'og:title') || doc.title, ['Thangs', '3D model', 'Download']));
  return merge(base, {
    title: name,
    creator: textOf(doc.querySelector('a[href*="/designer/"]')) || by,
    tags: tagLinks(doc, 'a[href*="/search/"][href*="tag"], a[href*="/tag/"]'),
  });
}

export function cults3d(doc, pageUrl) {
  const base = generic(doc, pageUrl);
  return merge(base, {
    title: cleanTitle(base.title, ['Cults']),
    creator: textOf(doc.querySelector('a[href*="/users/"]')),
    licence: ccLink(doc) || licenceId(textOf(doc.querySelector('[class*="license"], [class*="licence"]'))),
    tags: tagLinks(doc, 'a[href*="/tags/"]'),
  });
}

export function myminifactory(doc, pageUrl) {
  const base = generic(doc, pageUrl);
  const [name, by] = splitBy(cleanTitle(base.title, ['MyMiniFactory']));
  return merge(base, {
    title: name,
    creator: textOf(doc.querySelector('a[href*="/users/"]')) || by,
    licence: ccLink(doc) || base.licence,
    tags: tagLinks(doc, 'a[href*="tags="], a[href*="/tag/"]'),
  });
}

export const ADAPTERS = { printables, makerworld, thingiverse, thangs, cults3d, myminifactory, web: generic };

/**
 * The page, read by its site's reader. Returns null when there is nothing a
 * library could keep — no https address or no title.
 */
export function extract(doc, pageUrl) {
  const site = siteOf(httpsUrl(pageUrl) || pageUrl);
  const read = (ADAPTERS[site] || generic)(doc, pageUrl);
  // The address decides the site, never the page.
  read.site = siteOf(read.url || pageUrl);
  if (!read.url || !read.title) return null;
  return read;
}
