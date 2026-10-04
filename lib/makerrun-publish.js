'use strict';

/**
 * Publish a print file from the library to MakerRun (main-process).
 *
 * A MakerRun listing is built in three calls because a design is a row, a model file and photographs,
 * and any one of them can fail on its own:
 *
 *   1. POST /designs                 → { design: { slug } }, status "pending"
 *   2. POST /designs/{slug}/files    → stores the model and VERIFIES it (a .3mf with a real profile)
 *   3. POST /designs/{slug}/images   → stores photos, strips their metadata server-side, sets the cover
 *
 * Nothing here publishes: MakerRun reviews every new listing, and `status` cannot be set by a client.
 * Free listings only — no sale field is ever sent; a creator who sells does that on makerrun.com.
 *
 * ── PREFLIGHT BEFORE THE NETWORK ─────────────────────────────────────────────────────────────────
 *
 * Every limit the server enforces that can be known in advance is checked here first, and a refusal
 * makes NO request. The caps are MakerRun's own (makerrun/src/lib/api/upload.ts, validate.ts and the
 * images route): a 100 MB model in one of five extensions, at most 8 images per request in JPEG, PNG
 * or WebP, 15 MB each, title ≤ 120 characters, description ≤ 20 000. An upload rejected after 100 MB
 * has crossed the wire is the expensive way to learn a rule we could read.
 */
const fs = require('fs');
const path = require('path');
const MRV1 = require('./makerrun-v1');
const TERMS = require('./makerrun-terms');
const { validSlug } = require('./makerrun-catalog');

const MAX_MODEL_BYTES = 100 * 1024 * 1024;
const MODEL_EXTENSIONS = ['.3mf', '.stl', '.obj', '.step', '.stp'];
const MAX_IMAGES_PER_REQUEST = 8;
const MAX_IMAGE_BYTES = 15 * 1024 * 1024;
const IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp'];
const IMAGE_KINDS = ['gallery', 'print'];
const MAX_TITLE = 120;
const MAX_DESCRIPTION = 20000;

const invalid = (details, message) => MRV1.codedError('invalid', message || (details[0] && details[0].message) || 'Some fields were rejected.', { details, status: 0 });
const str = (v) => (typeof v === 'string' ? v.trim() : '');

/** Same storage-safe filename rule as MakerRun's safeName, so what we send is what gets stored. */
function safeName(n, fallback) {
  return (String(n || '') || fallback).replace(/[^a-zA-Z0-9._-]/g, '_').replace(/^\.+/, '_').slice(0, 120) || fallback;
}

function assertSlug(slug) {
  if (!validSlug(slug)) throw MRV1.codedError('bad_request', 'That is not a MakerRun design id.');
}

/**
 * Validate the listing fields and build the exact JSON body. Only whitelisted keys reach the body, so
 * a sale field (or `status`) passed by mistake is dropped rather than sent.
 *
 * @returns {{errors: {field:string, message:string}[], body: object}}
 */
function validateCreateInput(input) {
  const i = input || {};
  const errors = [];
  const body = {};
  const title = str(i.title);
  if (!title) errors.push({ field: 'title', message: 'A title is required.' });
  else if (title.length > MAX_TITLE) errors.push({ field: 'title', message: 'The title must be ' + MAX_TITLE + ' characters or fewer.' });
  else body.title = title;

  const description = str(i.description);
  if (description.length > MAX_DESCRIPTION) errors.push({ field: 'description', message: 'The description is too long.' });
  else if (description) body.description = description;

  if (!TERMS.CATEGORY_VALUES.includes(i.category)) errors.push({ field: 'category', message: 'Choose a category.' });
  else body.category = i.category;

  if (i.material != null && i.material !== '') {
    if (!TERMS.MATERIALS.includes(i.material)) errors.push({ field: 'material', message: 'Choose rigid, flexible or multi-material.' });
    else body.material = i.material;
  }

  // One of the strings MakerRun's own upload form offers — the API stores free text, and a listing
  // published under a string no other client recognises is a listing whose terms nobody can read.
  if (!TERMS.LICENCES.includes(i.license)) errors.push({ field: 'license', message: 'Choose a licence MakerRun offers.' });
  else body.license = i.license;

  body.nsfw = i.nsfw === true;
  return { errors, body };
}

/** POST /designs. Returns the new listing's slug and status ("pending"). */
async function createDesign(token, input, net) {
  const { errors, body } = validateCreateInput(input);
  if (errors.length) throw invalid(errors, 'Some fields need attention before this can be published.');
  const res = await MRV1.request('POST', '/designs', { token, json: body, baseUrl: net && net.baseUrl });
  const d = res && res.design;
  if (!d || !validSlug(d.slug)) {
    throw MRV1.codedError('bad_response', 'MakerRun created something, but did not say what. Check your MakerRun account before trying again.');
  }
  return { slug: d.slug, status: typeof res.status === 'string' ? res.status : 'pending', url: typeof d.url === 'string' ? d.url : null };
}

/** Refusals for a model file, with no network. `size` in bytes. */
function checkModel(filename, size) {
  const ext = path.extname(String(filename || '')).toLowerCase();
  if (!MODEL_EXTENSIONS.includes(ext)) {
    return { field: 'file', message: 'MakerRun accepts ' + MODEL_EXTENSIONS.join(', ') + ' files.' };
  }
  if (!(size > 0)) return { field: 'file', message: 'That file is empty.' };
  if (size > MAX_MODEL_BYTES) return { field: 'file', message: 'MakerRun accepts model files up to 100 MB.' };
  return null;
}

/**
 * POST /designs/{slug}/files — multipart field `file`.
 * @param {{filename:string, bytes:Buffer|Uint8Array}} file
 */
async function uploadModel(token, slug, file, net) {
  assertSlug(slug);
  const f = file || {};
  const bytes = f.bytes;
  const issue = checkModel(f.filename, bytes ? bytes.byteLength : 0);
  if (issue) throw invalid([issue]);
  const form = new FormData();
  form.append('file', new Blob([bytes], { type: 'application/octet-stream' }), safeName(path.basename(String(f.filename)), 'model.3mf'));
  const res = await MRV1.request('POST', '/designs/' + encodeURIComponent(slug) + '/files',
    { token, form, baseUrl: net && net.baseUrl, timeoutMs: MRV1.uploadTimeoutFor(bytes.byteLength) });
  const v = res && typeof res.verification === 'object' && res.verification ? res.verification : {};
  return {
    file: res.file && typeof res.file === 'object' ? { filename: String(res.file.filename || ''), sizeBytes: Number(res.file.sizeBytes) || 0 } : null,
    verification: {
      verified: v.verified === true,
      printer: typeof v.printer === 'string' ? v.printer : null,
      brand: typeof v.brand === 'string' ? v.brand : null,
      reason: typeof v.reason === 'string' ? v.reason : null,
    },
    status: typeof res.status === 'string' ? res.status : 'pending',
  };
}

/** Refusals for an image batch, with no network. */
function checkImages(images, kind) {
  const list = Array.isArray(images) ? images : [];
  if (!list.length) return [{ field: 'images', message: 'Choose at least one image.' }];
  if (list.length > MAX_IMAGES_PER_REQUEST) return [{ field: 'images', message: 'At most ' + MAX_IMAGES_PER_REQUEST + ' images at a time.' }];
  if (!IMAGE_KINDS.includes(kind)) return [{ field: 'kind', message: 'An image is either a gallery picture or a photo of the print.' }];
  const out = [];
  for (const im of list) {
    const name = String((im && im.filename) || 'image');
    if (!im || !IMAGE_TYPES.includes(im.type)) out.push({ field: 'images', message: name + ': must be JPEG, PNG or WebP.' });
    else if (!im.bytes || !im.bytes.byteLength) out.push({ field: 'images', message: name + ': empty image.' });
    else if (im.bytes.byteLength > MAX_IMAGE_BYTES) out.push({ field: 'images', message: name + ': larger than 15 MB.' });
  }
  return out;
}

/**
 * POST /designs/{slug}/images — one `images` part per picture, plus `kind`. Each Blob carries its real
 * type, because MakerRun refuses an image whose declared type is not one it measures.
 * @param {{filename:string, bytes:Buffer|Uint8Array, type:string}[]} images
 * @param {{kind?:'gallery'|'print'}} [opts]
 */
async function uploadImages(token, slug, images, opts, net) {
  assertSlug(slug);
  const kind = (opts && opts.kind) || 'gallery';
  const issues = checkImages(images, kind);
  if (issues.length) throw invalid(issues);
  const form = new FormData();
  images.forEach((im, i) => {
    const fallback = 'image-' + (i + 1) + (im.type === 'image/png' ? '.png' : im.type === 'image/webp' ? '.webp' : '.jpg');
    form.append('images', new Blob([im.bytes], { type: im.type }), safeName(im.filename, fallback));
  });
  form.append('kind', kind);
  const total = images.reduce((n, im) => n + im.bytes.byteLength, 0);
  const res = await MRV1.request('POST', '/designs/' + encodeURIComponent(slug) + '/images',
    { token, form, baseUrl: net && net.baseUrl, timeoutMs: MRV1.uploadTimeoutFor(total) });
  return {
    stored: Array.isArray(res.images) ? res.images.length : 0,
    coverSet: typeof res.coverSet === 'string' ? res.coverSet : null,
    failures: Array.isArray(res.failures) ? res.failures.filter((x) => x && typeof x.message === 'string').map((x) => x.message) : [],
  };
}

const ME_PAGE = 100;   // GET /me pages with limit (≤100) and offset — makerrun/src/lib/api/http.ts pageParams
const ME_MAX_PAGES = 20; // 2,000 listings; past that, the answer is reported as incomplete, not as "gone"

function normalizeMine(d) {
  return {
    slug: d.slug,
    title: typeof d.title === 'string' ? d.title : '',
    status: typeof d.status === 'string' ? d.status : null,
    createdAt: typeof d.createdAt === 'string' ? d.createdAt : null,
    verification: d.verification && typeof d.verification === 'object'
      ? { badge: d.verification.badge === true, fileChecked: d.verification.fileChecked === true }
      : null,
  };
}

/** One page of GET /me. Listings come newest first (ordered by created_at descending). */
async function getMePage(token, offset, net) {
  const qs = '?limit=' + ME_PAGE + (offset > 0 ? '&offset=' + offset : '');
  const res = await MRV1.request('GET', '/me' + qs, { token, baseUrl: net && net.baseUrl });
  if (!res.user || typeof res.user !== 'object' || !Array.isArray(res.designs)) {
    throw MRV1.codedError('bad_response', 'MakerRun replied, but not with an account Bed Ready recognises.');
  }
  return res;
}

/**
 * GET /me — the token's owner and their listings at every status, paged until a short page.
 * `complete: false` when the page cap was reached first, so a listing that was not seen is NOT
 * reported as gone.
 */
async function getMe(token, net, opts) {
  const maxPages = (opts && opts.maxPages) || ME_MAX_PAGES;
  const designs = [];
  let user = null;
  let complete = false;
  for (let page = 0; page < maxPages; page++) {
    const res = await getMePage(token, page * ME_PAGE, net);
    if (!user) user = res.user;
    for (const d of res.designs) if (d && validSlug(d.slug)) designs.push(normalizeMine(d));
    if (res.designs.length < ME_PAGE) { complete = true; break; }
    if (opts && typeof opts.stopWhen === 'function' && opts.stopWhen(designs)) break;
  }
  const u = user;
  return {
    user: {
      displayName: typeof u.displayName === 'string' ? u.displayName : null,
      trusted: u.trusted === true,
      twoFactor: u.twoFactor && typeof u.twoFactor === 'object'
        ? { enabled: u.twoFactor.enabled === true, satisfiedByThisSession: u.twoFactor.satisfiedByThisSession === true }
        : null,
    },
    designs,
    complete,
  };
}

/**
 * Where one of the user's listings stands. `found: false, complete: true` means it is not among their
 * listings any more (deleted on the website, or removed by moderation). `complete: false` means it was
 * not in the listings that were read — said as that, never as "gone".
 */
async function getStatus(token, slug, net, opts) {
  assertSlug(slug);
  const me = await getMe(token, net, Object.assign({}, opts, { stopWhen: (list) => list.some((x) => x.slug === slug) }));
  const d = me.designs.find((x) => x.slug === slug);
  if (d) return { found: true, status: d.status, verification: d.verification, complete: true };
  return { found: false, status: null, verification: null, complete: me.complete, searched: me.designs.length };
}

/**
 * After a create whose answer never arrived (timeout, dropped connection), the listing may exist
 * anyway. Look for it before creating another: the user's newest pending listing with the SAME
 * title, created since `sinceMs`. Reads only the first page — new listings sort first.
 */
async function findRecentListing(token, title, sinceMs, net) {
  const want = String(title || '').trim();
  if (!want) return null;
  const res = await getMePage(token, 0, net);
  const hit = res.designs
    .filter((d) => d && validSlug(d.slug))
    .map(normalizeMine)
    .find((d) => d.title.trim() === want
      && (d.status === 'pending' || d.status === 'draft')
      && d.createdAt && Date.parse(d.createdAt) >= sinceMs);
  return hit ? { slug: hit.slug, status: hit.status, createdAt: hit.createdAt } : null;
}

/** DELETE /designs/{slug} — only ever on an explicit, confirmed user action. */
async function deleteDesign(token, slug, net) {
  assertSlug(slug);
  const res = await MRV1.request('DELETE', '/designs/' + encodeURIComponent(slug), { token, baseUrl: net && net.baseUrl });
  return { deleted: res.deleted === true };
}

/**
 * A regular file directly inside `dir`, by basename — or null.
 *
 * Refuses a symlink (lstat, never stat), anything that is not a plain file, and anything whose real
 * path is not directly inside the real `dir`. The renderer names the file; this is what makes sure
 * the name cannot point the upload at something else on the disk.
 *
 * @returns {{full:string, size:number}|null}
 */
function resolveVaultFile(dir, filename) {
  if (typeof dir !== 'string' || !dir || typeof filename !== 'string' || !filename) return null;
  const name = path.basename(filename);
  // A bare name only: anything carrying a separator is refused rather than quietly stripped.
  if (!name || name === '.' || name === '..' || name !== filename || /[\\/]/.test(filename)) return null;
  const full = path.join(dir, name);
  let st;
  try { st = fs.lstatSync(full); } catch { return null; }
  if (st.isSymbolicLink() || !st.isFile()) return null;
  let realDir, realFull;
  try { realDir = fs.realpathSync(dir); realFull = fs.realpathSync(full); } catch { return null; }
  const rel = path.relative(realDir, realFull);
  if (!rel || rel.startsWith('..') || path.isAbsolute(rel) || rel.includes(path.sep)) return null;
  return { full, size: st.size };
}

/**
 * Read a file resolved by resolveVaultFile without following a symlink swapped in since: O_NOFOLLOW
 * where the platform has it, and an fstat of the handle that was actually opened.
 */
async function readVaultFile(full, maxBytes) {
  const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0);
  const fh = await fs.promises.open(full, flags);
  try {
    const st = await fh.stat();
    if (!st.isFile()) throw MRV1.codedError('missing', 'That print file is missing from the library folder.');
    if (maxBytes && st.size > maxBytes) throw MRV1.codedError('invalid', 'That file is too large.');
    return await fh.readFile();
  } finally { await fh.close(); }
}

/** The image types we can name from the bytes themselves — never from a filename. */
function sniffImageType(buf) {
  if (!buf || buf.length < 12) return null;
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'image/png';
  if (buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
  return null;
}

module.exports = {
  createDesign, uploadModel, uploadImages, getMe, getStatus, deleteDesign, findRecentListing,
  resolveVaultFile, readVaultFile,
  validateCreateInput, checkModel, checkImages, sniffImageType, safeName,
  MAX_MODEL_BYTES, MODEL_EXTENSIONS, MAX_IMAGES_PER_REQUEST, MAX_IMAGE_BYTES, IMAGE_TYPES, IMAGE_KINDS,
};
