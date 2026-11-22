'use strict';

/**
 * MakerRun public catalogue (main-process): browse published designs, read one, and download a file
 * from one into the print-file library.
 *
 * Different from lib/makerrun-library.js, which syncs the user's OWN saved designs through
 * `/api/library`. This reads the whole public catalogue through `/api/v1/designs`, which needs no
 * token — browsing works signed out — and only the download step needs the user's MakerRun account.
 *
 * ── AN UNREADABLE ANSWER IS AN ERROR, NOT AN EMPTY CATALOGUE ─────────────────────────────────────
 *
 * The same rule fetchLibrary learned the hard way: a field renamed on the server must not render as
 * "no designs found". Every response is checked against the documented shape and refused, loudly, if
 * it does not match. A design row missing its slug or title is refused rather than skipped, because a
 * grid that silently drops rows is a grid nobody can trust.
 *
 * ── WHAT IS PASSED ON ────────────────────────────────────────────────────────────────────────────
 *
 * Each DesignDTO is narrowed to the fields the panel renders, so a new server field cannot reach the
 * renderer by accident, and URLs are kept only when they are https. The sale link is NEVER passed: the
 * panel links to the design's page on makerrun.com, which is where the Buy button lives.
 */
const MRV1 = require('./makerrun-v1');
const TERMS = require('./makerrun-terms');
const makerrunLibrary = require('./makerrun-library');

const LIST_DEFAULT = 24;
const LIST_MAX = 100;
const MAX_QUERY_CHARS = 200;

const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const optStr = (v) => (typeof v === 'string' ? v : null);
const optNum = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const httpsOrNull = (v) => (typeof v === 'string' && /^https:\/\//i.test(v) ? v : null);

function shapeError(what) {
  return MRV1.codedError('bad_response',
    'MakerRun replied, but not with ' + what + ' Bed Ready recognises. Try again shortly, and if it persists this needs reporting.');
}

/**
 * A slug as MakerRun mints them: letters (any script — designSlug keeps CJK and Arabic) and numbers,
 * joined by hyphens. Anything with a slash, dot, percent or space is refused before a request is
 * built, so a slug relayed through the renderer cannot reshape the path.
 */
function validSlug(slug) {
  return typeof slug === 'string' && slug.length > 0 && slug.length <= 200
    && /^[\p{L}\p{N}][\p{L}\p{N}_-]*$/u.test(slug);
}
function assertSlug(slug) {
  if (!validSlug(slug)) throw MRV1.codedError('bad_request', 'That is not a MakerRun design id.');
  return slug;
}

/** A filename as GET /designs/{slug} reports it. No separators, no NUL, no dot-only names. */
function validFilename(name) {
  return typeof name === 'string' && name.length > 0 && name.length <= 255
    && !/[\\/\u0000]/.test(name) && !/^\.+$/.test(name);
}

/** Build the `GET /designs` query string. Unknown categories and materials are dropped, not sent. */
function buildListQuery(opts) {
  const o = opts || {};
  const p = new URLSearchParams();
  const q = typeof o.q === 'string' ? o.q.trim().slice(0, MAX_QUERY_CHARS) : '';
  if (q) p.set('q', q);
  if (typeof o.category === 'string' && TERMS.CATEGORY_VALUES.includes(o.category)) p.set('category', o.category);
  if (typeof o.material === 'string' && TERMS.MATERIALS.includes(o.material)) p.set('material', o.material);
  if (o.verified === true) p.set('verified', 'true');
  if (o.forSale === true) p.set('forSale', 'true');
  else if (o.forSale === false) p.set('forSale', 'false');
  const lim = Math.trunc(Number(o.limit));
  p.set('limit', String(Number.isFinite(lim) && lim > 0 ? Math.min(lim, LIST_MAX) : LIST_DEFAULT));
  const off = Math.trunc(Number(o.offset));
  if (Number.isFinite(off) && off > 0) p.set('offset', String(off));
  return p.toString();
}

/** One DesignDTO → what the panel renders. Throws on a row that is not a design. */
function normalizeDesign(d) {
  if (!isObj(d) || !validSlug(d.slug) || typeof d.title !== 'string') throw shapeError('a design');
  const v = isObj(d.verification) ? d.verification : {};
  const pr = isObj(v.printer) ? v.printer : null;
  const sale = isObj(d.sale) ? d.sale : null;
  const cover = isObj(d.cover) ? d.cover : {};
  const licence = optStr(d.license);
  return {
    slug: d.slug,
    title: d.title,
    description: optStr(d.description) || '',
    creator: optStr(d.creator),
    license: licence,
    commercialUse: TERMS.commercialUse(licence),
    category: optStr(d.category),
    material: TERMS.MATERIALS.includes(d.material) ? d.material : null,
    colorCount: optNum(d.colorCount),
    nsfw: d.nsfw === true,
    createdAt: optStr(d.createdAt),
    downloadCount: optNum(d.downloadCount) || 0,
    url: httpsOrNull(d.url),
    cover: httpsOrNull(cover.url),
    coverAiGenerated: cover.aiGenerated === true,
    external: d.external === true,
    listingKind: optStr(d.listingKind),
    verification: {
      badge: v.badge === true,
      fileChecked: v.fileChecked === true,
      printPhotoConfirmed: v.printPhotoConfirmed === true,
      printer: pr ? { brand: optStr(pr.brand), model: optStr(pr.model) } : null,
    },
    // Free vs for sale, and the price to show — never the payment URL (see the header).
    sale: sale && sale.kind ? {
      kind: optStr(sale.kind), price: optNum(sale.price), currency: optStr(sale.currency),
      provider: optStr(sale.provider),
    } : null,
  };
}

/**
 * GET /designs — public, no token.
 * @returns {Promise<{designs: object[], page: {limit:number, offset:number, total:number, returned:number}}>}
 */
async function listDesigns(opts, net) {
  const n = net || {};
  const body = await MRV1.request('GET', '/designs?' + buildListQuery(opts), { baseUrl: n.baseUrl });
  if (!Array.isArray(body.designs) || !isObj(body.page) || !Number.isFinite(body.page.total)) {
    throw shapeError('a design list');
  }
  const designs = body.designs.map(normalizeDesign);
  const pg = body.page;
  return {
    designs,
    page: {
      limit: optNum(pg.limit) || designs.length,
      offset: optNum(pg.offset) || 0,
      total: pg.total,
      returned: optNum(pg.returned) == null ? designs.length : pg.returned,
    },
  };
}

/** GET /designs/{slug} — public. Files, gallery and print profiles, narrowed. */
async function getDesign(slug, net) {
  const n = net || {};
  assertSlug(slug);
  const body = await MRV1.request('GET', '/designs/' + encodeURIComponent(slug), { baseUrl: n.baseUrl });
  if (!isObj(body.design) || !Array.isArray(body.files) || !Array.isArray(body.images) || !Array.isArray(body.profiles)) {
    throw shapeError('a design');
  }
  const files = body.files.map((f) => {
    if (!isObj(f) || typeof f.filename !== 'string') throw shapeError('a file list');
    return { filename: f.filename, sizeBytes: optNum(f.sizeBytes), hosted: f.hosted === true };
  });
  const images = body.images
    .filter((i) => isObj(i) && httpsOrNull(i.url))
    .map((i) => ({ url: i.url, kind: optStr(i.kind) || 'gallery', printConfirmed: i.printConfirmed === true }));
  const profiles = body.profiles.filter(isObj).map((p) => ({
    printerBrand: optStr(p.printerBrand), printerModel: optStr(p.printerModel),
    filamentType: optStr(p.filamentType), colorCount: optNum(p.colorCount),
    badge: p.badge === true, fileChecked: p.fileChecked === true, printPhotoConfirmed: p.printPhotoConfirmed === true,
  }));
  return { design: normalizeDesign(body.design), files, images, profiles };
}

/**
 * GET /designs/{slug}/files/{filename}/download — needs a token. Returns a 300-second signed URL,
 * which is fetched straight away and never stored.
 */
async function requestDownloadUrl(token, slug, filename, net) {
  const n = net || {};
  assertSlug(slug);
  if (!validFilename(filename)) throw MRV1.codedError('bad_request', 'That is not a file on this design.');
  const body = await MRV1.request('GET',
    '/designs/' + encodeURIComponent(slug) + '/files/' + encodeURIComponent(filename) + '/download',
    { token, baseUrl: n.baseUrl });
  if (!httpsOrNull(body.url)) throw shapeError('a download link');
  return {
    url: body.url,
    expiresInSeconds: optNum(body.expiresInSeconds),
    filename: typeof body.filename === 'string' ? body.filename : filename,
    sizeBytes: optNum(body.sizeBytes),
  };
}

/**
 * Two steps: ask MakerRun for the signed URL, then fetch it through makerrun-library's downloadItem —
 * the same HTTPS-only, per-redirect-hop host guard and streaming size cap the library sync uses, so a
 * signed URL that bounces to a private address is refused here exactly as it is there.
 *
 * @returns {Promise<string>} the written path inside destDir
 */
async function downloadDesignFile(token, { slug, filename, title }, destDir, net) {
  const signed = await requestDownloadUrl(token, slug, filename, net);
  const item = { slug, title: title || slug, filename: signed.filename, downloadUrl: signed.url };
  const out = await (net && net.downloadItem ? net.downloadItem : makerrunLibrary.downloadItem)(item, destDir);
  if (!out) throw MRV1.codedError('not_found', 'That design has no file to download.');
  return out;
}

module.exports = {
  listDesigns, getDesign, requestDownloadUrl, downloadDesignFile,
  buildListQuery, normalizeDesign, validSlug, validFilename,
  LIST_DEFAULT, LIST_MAX,
  // The pure vocabularies, re-exported so a caller of the catalogue needs one require.
  CATEGORIES: TERMS.CATEGORIES, LICENCES: TERMS.LICENCES, MATERIALS: TERMS.MATERIALS,
  toRecordLicence: TERMS.toRecordLicence, toMakerRunLicence: TERMS.toMakerRunLicence,
  commercialUse: TERMS.commercialUse,
};
