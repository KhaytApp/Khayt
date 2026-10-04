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
  const res = await MRV1.request('POST', '/designs/' + encodeURIComponent(slug) + '/files', { token, form, baseUrl: net && net.baseUrl });
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
  const res = await MRV1.request('POST', '/designs/' + encodeURIComponent(slug) + '/images', { token, form, baseUrl: net && net.baseUrl });
  return {
    stored: Array.isArray(res.images) ? res.images.length : 0,
    coverSet: typeof res.coverSet === 'string' ? res.coverSet : null,
    failures: Array.isArray(res.failures) ? res.failures.filter((x) => x && typeof x.message === 'string').map((x) => x.message) : [],
  };
}

/** GET /me — the token's owner and their listings at every status. */
async function getMe(token, net) {
  const res = await MRV1.request('GET', '/me?limit=100', { token, baseUrl: net && net.baseUrl });
  if (!res.user || typeof res.user !== 'object' || !Array.isArray(res.designs)) {
    throw MRV1.codedError('bad_response', 'MakerRun replied, but not with an account Bed Ready recognises.');
  }
  const u = res.user;
  return {
    user: {
      displayName: typeof u.displayName === 'string' ? u.displayName : null,
      trusted: u.trusted === true,
      twoFactor: u.twoFactor && typeof u.twoFactor === 'object'
        ? { enabled: u.twoFactor.enabled === true, satisfiedByThisSession: u.twoFactor.satisfiedByThisSession === true }
        : null,
    },
    designs: res.designs.filter((d) => d && validSlug(d.slug)).map((d) => ({
      slug: d.slug,
      title: typeof d.title === 'string' ? d.title : '',
      status: typeof d.status === 'string' ? d.status : null,
      verification: d.verification && typeof d.verification === 'object'
        ? { badge: d.verification.badge === true, fileChecked: d.verification.fileChecked === true }
        : null,
    })),
  };
}

/**
 * Where one of the user's listings stands. `found: false` when it is not among their listings any
 * more (deleted on the website, or removed by moderation) — said, not guessed at.
 */
async function getStatus(token, slug, net) {
  assertSlug(slug);
  const me = await getMe(token, net);
  const d = me.designs.find((x) => x.slug === slug);
  return d ? { found: true, status: d.status, verification: d.verification } : { found: false, status: null, verification: null };
}

/** DELETE /designs/{slug} — only ever on an explicit, confirmed user action. */
async function deleteDesign(token, slug, net) {
  assertSlug(slug);
  const res = await MRV1.request('DELETE', '/designs/' + encodeURIComponent(slug), { token, baseUrl: net && net.baseUrl });
  return { deleted: res.deleted === true };
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
  createDesign, uploadModel, uploadImages, getMe, getStatus, deleteDesign,
  validateCreateInput, checkModel, checkImages, sniffImageType, safeName,
  MAX_MODEL_BYTES, MODEL_EXTENSIONS, MAX_IMAGES_PER_REQUEST, MAX_IMAGE_BYTES, IMAGE_TYPES, IMAGE_KINDS,
};
