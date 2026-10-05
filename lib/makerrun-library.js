'use strict';

/**
 * MakerRun library client (main-process). Pulls the signed-in user's saved designs from makerrun.com
 * (GET /api/library) using their MakerRun access token, and downloads the files locally. This is the
 * desktop side of site↔app library sync.
 *
 * The library was called BedReady and lived on bedready.io until the 2026-08-21 split; bedready.io is
 * the *converter* now and has no library API. Paths and payloads are unchanged — this was a host move,
 * not a contract change.
 *
 * The UI half is renderer/bedready-library.js — same feature, different prefix, because that file
 * belongs to the Bed Ready flavor's renderer family rather than to this product. Renaming one without
 * the other is the trap; they are cross-referenced so neither is found alone.
 *
 * Deliberately SEPARATE from Khayt Cloud (lib/cloud-client): Khayt Cloud is E2E-encrypted shop-data
 * backup across the user's devices; this is a read-only pull of the user's *public* MakerRun library
 * (their saved designs). Different identity, different data, no crossover.
 *
 * Auth: the user signs in on makerrun.com (openSignIn opens it in the system browser) and supplies their
 * access token; we send it as a Bearer to /api/library. No Supabase SDK or secrets live in the app.
 * Node-only (uses Node fetch + fs) — never loaded in the renderer.
 */
const fs = require('fs');
const MAINT = require('./makerrun-maintenance');
const path = require('path');
const crypto = require('crypto');
const { resolvesToBlockedHost } = require('./host-guard');

const { BASE } = require('./makerrun'); // one host constant, shared with lib/makerrun-account
const MAX_FILE_BYTES = 512 * 1024 * 1024; // 512 MB ceiling per design file (3MF/STL/OBJ/STEP)

/**
 * Reject a download URL that isn't HTTPS or resolves to a private/loopback/metadata address (SSRF).
 * `downloadUrl` comes from the /api/library response and is relayed back through the renderer, so the
 * privileged main process must not blindly fetch it — this mirrors the host-guard already applied to
 * every other outbound surface (webhooks, SMTP, printer polling, etc.).
 */
async function assertSafeDownloadUrl(url) {
  let u;
  try { u = new URL(String(url || '')); } catch { throw new Error('That design has an invalid download URL.'); }
  if (u.protocol !== 'https:') throw new Error('Refusing a non-HTTPS download URL.');
  if (await resolvesToBlockedHost(u.hostname)) throw new Error('Refusing a download from a private/internal address.');
}

/**
 * Fetch a download URL, following redirects MANUALLY so every hop is re-validated by
 * assertSafeDownloadUrl. undici's default `redirect:'follow'` would let a 3xx bounce the
 * request past the initial guard to a private/loopback/metadata address (SSRF) — the same
 * hole the outbound webhook handlers avoid with `redirect:'manual'`. Bounded to maxHops so a
 * redirect loop can't spin forever; the caller's abort signal covers the whole chain.
 */
async function safeFetchDownload(url, signal, maxHops = 5) {
  let current = String(url);
  for (let hop = 0; ; hop++) {
    await assertSafeDownloadUrl(current);
    const res = await fetch(current, { signal, redirect: 'manual' });
    if (res.status < 300 || res.status >= 400) return res;
    const loc = res.headers.get('location');
    if (!loc) return res; // 3xx with no target — let the caller surface the non-ok status
    if (hop >= maxHops) throw new Error('Too many redirects while downloading that design.');
    try { current = new URL(loc, current).toString(); }
    catch { throw new Error('That design has an invalid download URL.'); }
  }
}

/**
 * Resolve a collision-free destination path within a single download batch. safeBase() collapses
 * distinct titles (punctuation stripped, truncated to 60 chars), so two library designs can map to
 * the same filename — without this, the second write would silently clobber the first while the UI
 * still reported both as saved. `used` tracks paths already claimed this batch; a taken name gets a
 * " (n)" suffix. (Re-downloading the SAME design across batches still overwrites, which is intended.)
 */
function uniqueDest(destDir, base, ext, used) {
  let full = path.join(destDir, base + ext);
  if (used) {
    let i = 1;
    while (used.has(full)) { full = path.join(destDir, base + ' (' + i + ')' + ext); i++; }
    used.add(full);
  }
  return full;
}

/** GET /api/library → array of items. Throws with a user-facing message on failure. */
/**
 * @param {string} token
 * @param {{baseUrl?: string}} [opts]  test seam only. Deliberately a PARAMETER and
 *        not an environment variable: this request carries the user's Bearer
 *        token, and an ambient override would let a stray env var send that
 *        token to an arbitrary host. Production never passes it.
 */
async function fetchLibrary(token, opts) {
  const t = String(token || '').trim();
  if (!t) throw new Error('Sign in to MakerRun first, then paste your access token.');
  const base = (opts && opts.baseUrl) || BASE;
  // `?since=` is the cursor the previous response handed back, verbatim. Never a
  // timestamp of our own: the server mints it before its own read, so it is the
  // only instant that is safe to ask "what changed after" about.
  const since = opts && opts.since ? String(opts.since) : '';
  const offset = opts && Number.isFinite(opts.offset) && opts.offset > 0 ? Math.trunc(opts.offset) : 0;
  const params = [];
  if (since) params.push('since=' + encodeURIComponent(since));
  if (offset) params.push('offset=' + String(offset));
  const qs = params.length ? ('?' + params.join('&')) : '';
  const res = await fetch(base + '/api/library' + qs, {
    headers: { authorization: 'Bearer ' + t },
    signal: AbortSignal.timeout(30000),
  });
  if (res.status === 401) throw new Error('Your MakerRun session expired — sign in again.');
  const data = await res.json().catch(() => null);
  // A planned migration closes every endpoint with 503 + maintenance. Reporting
  // that as "Library fetch failed" tells a shop its sync is broken during a
  // window in which nothing is broken and nothing was half-written.
  //
  // Branched on error.code, not the status: 503 is also `unavailable`, which
  // means a misconfigured server that retrying will not fix.
  if (MAINT.isMaintenance(res.status, data)) {
    throw MAINT.maintenanceError(MAINT.retryAfterSeconds(res.headers.get('retry-after'), Date.now()));
  }
  if (!res.ok) throw new Error(explainLibraryStatus(res.status));

  /*
   * AN UNREADABLE ANSWER IS NOT AN EMPTY LIBRARY.
   *
   * This used to end `data && Array.isArray(data.items) ? data.items : []`, so
   * every shape it did not recognise became zero designs and no error:
   *
   *   {items:[a,b]}      -> 2 designs
   *   {designs:[a,b]}    -> 0 designs, silently   (a field rename on the server)
   *   [a,b]              -> 0 designs, silently
   *   malformed JSON     -> 0 designs, silently   (res.json() already .catch(->null))
   *
   * A shop with forty saved designs would open the library, see nothing, and be
   * told nothing — indistinguishable from a shop that has saved none. That is
   * the carrier-webhook defect exactly (#777): answering "received, handled" to
   * something you could not read hides a broken integration completely.
   *
   * It is also a two-repo contract with nothing comparing the halves — makerrun
   * owns the response shape, this file owns the reader — which is the same shape
   * as the Medusa field list.
   *
   * So: recognise the documented shape, tolerate the one unambiguous variant,
   * and REFUSE anything else rather than flatten it to empty. A bare array is
   * accepted deliberately even though the server does not send one today: it
   * cannot be mistaken for anything else, so accepting it can never produce a
   * WRONG answer, only avoid a false failure.
   */
  /*
   * Returns the ENVELOPE, not just the items, because two of its fields are
   * load-bearing rather than decorative:
   *
   *   filtered  distinguishes "nothing changed" from "you have saved nothing".
   *             `count: 0` means both, and a client that cannot tell them apart
   *             has to guess — and the expensive guess is re-syncing everything.
   *   syncedAt  the next cursor, minted server-side before its own read.
   *
   * A bare array is still accepted (see above) and reports neither, which is the
   * honest answer for a shape that carries neither.
   */
  if (data && Array.isArray(data.items)) {
    return {
      items: data.items,
      count: Number.isFinite(data.count) ? data.count : data.items.length,
      filtered: data.filtered === true,
      syncedAt: typeof data.syncedAt === 'string' ? data.syncedAt : null,
      // Paging. `truncated` is the only one of these that changes what a client
      // may DO: a truncated answer is not authoritative for deletion, because
      // the designs on the pages you did not fetch are absent for the same
      // reason a removed one is.
      total: Number.isFinite(data.total) ? data.total : null,
      offset: Number.isFinite(data.offset) ? data.offset : 0,
      truncated: data.truncated === true,
      // What LEFT since the cursor. `null` on a full sync, where the list is
      // already the whole answer.
      removed: Array.isArray(data.removed) ? data.removed : null,
      // Tombstones are pruned, so a cursor older than this cannot be given a
      // complete `removed`. Stated by the server rather than guessed at here.
      removalsCompleteSince: typeof data.removalsCompleteSince === 'string' ? data.removalsCompleteSince : null,
    };
  }
  if (Array.isArray(data)) {
    return {
      items: data, count: data.length, filtered: false, syncedAt: null,
      total: data.length, offset: 0, truncated: false, removed: null, removalsCompleteSince: null,
    };
  }
  throw new Error(
    'MakerRun replied, but not with a library Khayt recognises. Your designs are '
    + 'safe — this is a problem between the two, not with your account. Try again '
    + 'shortly, and if it persists this needs reporting.');
}

/**
 * What a failing status means, rather than what number it was.
 *
 * Same reasoning as `explainUpdateError` in lib/updater.js, and the same defect
 * being avoided: `HTTP 502` names a number the shop cannot act on. These are the
 * ordinary ones — a CDN hiccup, a rate limit, a lapsed session — and none is a
 * fault of the shop's or of its data.
 *
 * An unrecognised status keeps its number, deliberately: inventing a reassuring
 * sentence for something nobody has classified hides a real fault.
 */
function explainLibraryStatus(status) {
  if (status === 403) return 'MakerRun refused that request. If you have just changed your password, sign in again.';
  if (status === 429) return 'MakerRun is asking Khayt to slow down. Wait a minute and sync again.';
  if (status === 404) return 'The MakerRun library endpoint has moved. Khayt needs an update to find it.';
  // 503 KEEPS ITS NUMBER, and that is not an oversight.
  //
  // A PLANNED window is caught earlier by MAINT.isMaintenance, branched on
  // `error.code` rather than the status. What reaches here as a 503 is the other
  // kind — `unavailable`, a misconfigured server — and the comment at that
  // branch says it plainly: retrying will not fix it.
  //
  // A first draft of this function folded 503 into a warm "having trouble right
  // now, nothing is wrong with your designs", and test/makerrun-maintenance
  // caught it. That message would have told a shop to wait for something that
  // was never going to clear on its own: a reassuring sentence over an
  // unclassified fault, which is the failure this whole family of fixes exists
  // to remove. Keeping the number is what makes it reportable.
  if (status === 503) return 'MakerRun is unavailable (HTTP 503). If it does not clear shortly, this needs reporting.';
  if (status >= 500) return 'MakerRun is having trouble right now, so the library could not be loaded. Nothing is wrong with your designs.';
  return 'Library fetch failed (HTTP ' + status + ').';
}

/**
 * One sync pass: what to show, and what the caller may skip downloading.
 *
 * ── THE CURSOR IS A PROBE, NOT A DELTA FEED ────────────────────────────────
 *
 * `?since=` narrows to designs whose listing or file changed after that instant,
 * "plus anything newly saved". It cannot report an UNSAVE — removing a design
 * from a library changes no row it would return — so merging its results into a
 * cached list would show a design the user had removed, indefinitely, with
 * nothing to correct it.
 *
 * There is exactly one answer it gives that is safe to act on alone:
 * `filtered && count === 0`, which means nothing changed, so the cached listing
 * is still right. Every other answer is discarded and an authoritative full
 * fetch is made instead — the whole list, which reflects removals because it is
 * the whole list.
 *
 * That sounds like it wastes the feature and does the opposite: the common case
 * IS "nothing changed", and in that case the probe costs one small response and
 * NO signed URLs, against a full listing that presigns one per design. When
 * something has changed, a second request is the price of a correct answer.
 *
 * The endpoint is rate limited at 20 per 5 minutes per IP and its own docs say a
 * real client refreshes about hourly; two requests on a change is comfortably
 * inside that, and a refresh loop would not be whatever we did here.
 */
/** Never page for ever. 50 × 200 is 10,000 saved designs; a server that keeps
 *  saying `truncated` past that is broken, and looping is not the way to find out. */
const MAX_PAGES = 50;

/**
 * Every page of a listing, and whether we actually reached the end.
 *
 * `complete` is the field that matters and it is not decoration. The endpoint
 * capped at 200 and said nothing about it until 2026-08-28 — a shop with 250
 * saved designs received 200 and had no way to know. Now that a client mirrors
 * the list, that silence becomes deletion: the 50 it never received look exactly
 * like 50 it was told had gone.
 *
 * So an incomplete read is reported as incomplete, and the caller must not treat
 * absence as removal when it is.
 */
async function fetchAllPages(token, opts) {
  const o = opts || {};
  const fetchOne = o.fetchLibrary || fetchLibrary;
  const items = [];
  let first = null;
  let offset = 0;
  for (let page = 0; page < MAX_PAGES; page++) {
    const res = await fetchOne(token, { baseUrl: o.baseUrl, since: o.since, offset });
    if (!first) first = res;
    for (const it of res.items) items.push(it);
    if (!res.truncated) return { ...first, items, complete: true };
    // A page that advances nothing would loop for ever; stop and say so.
    if (!res.items.length) return { ...first, items, complete: false };
    offset += res.items.length;
  }
  return { ...first, items, complete: false };
}

async function syncLibrary(token, opts) {
  const o = opts || {};
  const state = o.state || { syncedAt: null, items: [], files: {} };
  const fetchOne = o.fetchLibrary || fetchLibrary;

  const fullSync = async () => {
    const full = await fetchAllPages(token, { baseUrl: o.baseUrl, fetchLibrary: fetchOne });
    return {
      items: full.items,
      syncedAt: full.syncedAt || state.syncedAt,
      unchanged: false,
      complete: full.complete,
      fetched: 'full',
    };
  };

  if (!state.syncedAt) return fullSync();

  const probe = await fetchOne(token, { baseUrl: o.baseUrl, since: state.syncedAt });

  // Nothing changed. Keep the cursor we already have rather than the one this
  // probe returned: they describe the same "nothing since", and holding the
  // older one can only ever widen the next question, never narrow it past a
  // change.
  if (probe.filtered && probe.count === 0) {
    return { items: state.items, syncedAt: state.syncedAt, unchanged: true, complete: true, fetched: 1 };
  }

  /*
   * APPLY THE DELTA — but only when all three of these hold.
   *
   * `removed` is what made a delta usable at all: a design that leaves a library
   * is absent from a delta, and so is every design that did not change. Same
   * absence, two meanings. With the list of what left, the changed case costs one
   * request instead of two.
   *
   *   filtered              this really is a delta and not a full list
   *   !truncated            a truncated answer is NOT authoritative for deletion —
   *                         the pages we did not fetch are absent for the same
   *                         reason a removed design is, and `removed` is computed
   *                         per request rather than per query
   *   cursor new enough     tombstones are pruned at 180 days, so a cursor older
   *                         than `removalsCompleteSince` cannot be given a complete
   *                         `removed`. The server states the boundary; believing a
   *                         short list would be the same lie as the absence it
   *                         replaces.
   *
   * Anything else falls back to a full paged sync, which is authoritative because
   * it is the whole list.
   */
  const cursorCoversRemovals = probe.removalsCompleteSince
    ? Date.parse(state.syncedAt) >= Date.parse(probe.removalsCompleteSince)
    : false;
  if (probe.filtered && !probe.truncated && Array.isArray(probe.removed) && cursorCoversRemovals) {
    const gone = new Set(probe.removed.map(String));
    const changed = new Map(probe.items.map((it) => [String(it.designId || it.slug), it]));
    const merged = [];
    for (const it of state.items) {
      const key = String(it.designId || it.slug);
      if (gone.has(key)) continue;
      merged.push(changed.has(key) ? changed.get(key) : it);
      changed.delete(key);
    }
    for (const it of changed.values()) merged.push(it);
    return {
      items: merged,
      syncedAt: probe.syncedAt || state.syncedAt,
      unchanged: false,
      complete: true,
      removed: probe.removed.length,
      fetched: 1,
    };
  }

  return fullSync();
}

/**
 * Verify downloaded bytes against the checksum the API gave for them.
 *
 * `checksumAlgo` is read rather than assumed — the API's own documentation says
 * "null when unavailable; never assume the algorithm", and it is `md5` today
 * only because that is what the storage layer computes. Hard-coding it would
 * turn a future move to sha256 into every download failing verification, which
 * is a worse outcome than not verifying.
 *
 * Returns null when there is nothing to check against: no checksum (a gated
 * design deliberately has none), no algorithm, or an algorithm this Node build
 * cannot compute. That is "unverified", NOT "verified" — the caller keeps the
 * file either way, because refusing a download over a hash we cannot compute
 * would break the feature to protect against nothing.
 */
function verifyChecksum(buf, item) {
  const algo = item && item.checksumAlgo ? String(item.checksumAlgo).toLowerCase() : '';
  const want = item && item.checksum ? String(item.checksum).toLowerCase() : '';
  if (!algo || !want) return null;
  let hashes;
  try { hashes = crypto.getHashes(); } catch (_) { return null; }
  if (!hashes.includes(algo)) return null;
  const got = crypto.createHash(algo).update(buf).digest('hex');
  return got === want;
}

/** Turn a design title into a safe filename base. */
function safeBase(s) {
  return String(s || 'design').replace(/[^a-z0-9._-]+/gi, '_').replace(/^_+|_+$/g, '').slice(0, 60) || 'design';
}

/**
 * Pick a file extension from the item's declared type, else its filename, else .3mf. Only ever returns
 * one of the four model extensions — a renderer-supplied filename can't smuggle e.g. `.command`/`.bat`
 * into ~/Downloads (the fileType/filename both originate from the /api/library payload).
 */
function extFor(item) {
  // `.stp` is STEP under its other common name — MakerRun accepts both spellings on upload. It is
  // written out as `.step` so the library has one extension per format; before this it fell through
  // to the `.3mf` default, and a STEP file landed on disk wearing a 3MF name no slicer could open.
  if (item && item.fileType && /^(3mf|stl|obj|step|stp)$/i.test(item.fileType)) {
    const t = item.fileType.toLowerCase();
    return t === 'stp' ? '.step' : '.' + t;
  }
  const e = item && item.filename ? path.extname(item.filename).toLowerCase() : '';
  if (e === '.stp') return '.step';
  return /^\.(3mf|stl|obj|step)$/.test(e) ? e : '.3mf';
}

/**
 * Download one item's file into destDir. Returns the written path, or null when the item has no
 * downloadable file (age-gated NSFW, or a link-only design).
 */
async function downloadItem(item, destDir, used, opts) {
  if (!item || !item.downloadUrl) return null;
  const tooLarge = '"' + (item.title || item.slug) + '" is too large to download.';
  // Own AbortController so we can tear the connection down the instant the body
  // exceeds the cap; combine with a wall-clock timeout via AbortSignal.any.
  const ac = new AbortController();
  // safeFetchDownload re-validates every redirect hop (guards the initial URL too).
  const res = await safeFetchDownload(item.downloadUrl, AbortSignal.any([ac.signal, AbortSignal.timeout(120000)]));
  if (!res.ok) throw new Error('Download failed for "' + (item.title || item.slug) + '" (HTTP ' + res.status + ').');
  // Trust the declared size as a cheap first gate, but never rely on it: a server can lie
  // about (or omit) content-length. Stream the body with a running byte counter and abort
  // the moment it crosses MAX_FILE_BYTES, so one design file can't exhaust memory/disk.
  const declared = Number(res.headers.get('content-length') || 0);
  if (declared > MAX_FILE_BYTES) throw new Error(tooLarge);
  const chunks = [];
  let total = 0;
  if (res.body && typeof res.body.getReader === 'function') {
    const reader = res.body.getReader();
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.byteLength;
        if (total > MAX_FILE_BYTES) {
          try { ac.abort(); } catch { /* already torn down */ }
          try { await reader.cancel(); } catch { /* best effort */ }
          throw new Error(tooLarge);
        }
        chunks.push(Buffer.from(value));
      }
    } finally {
      try { reader.releaseLock(); } catch { /* stream already closed */ }
    }
  } else {
    // Environments without a streaming body (older runtimes): fall back to the buffered read,
    // still bounded by the post-facto length check.
    const buf = Buffer.from(await res.arrayBuffer());
    if (buf.length > MAX_FILE_BYTES) throw new Error(tooLarge);
    chunks.push(buf);
    total = buf.length;
  }
  const body = Buffer.concat(chunks, total);

  /*
   * VERIFY BEFORE WRITING, and refuse a file whose bytes are not the bytes the
   * API described.
   *
   * `checksum` is the storage layer's own digest of the object, so it cannot
   * drift from the content the way a column maintained alongside it could. A
   * mismatch means the bytes changed in transit or the signed URL served
   * something else — either way it is not the design, and writing it would put a
   * corrupt model in a shop's library under the right name, which is worse than
   * failing.
   *
   * `verifyChecksum` returns null for "nothing to check against": a gated design
   * has no checksum by design, and an algorithm this Node build cannot compute
   * is not the shop's problem. Unverified is recorded and the file is kept —
   * refusing a download over a hash we cannot compute would break the feature to
   * protect against nothing.
   */
  const verdict = verifyChecksum(body, item);
  if (verdict === false) {
    throw new Error('"' + (item.title || item.slug) + '" did not match the checksum MakerRun gave for it, so it was not saved.');
  }
  item.__checksumVerified = verdict === true;

  await fs.promises.mkdir(destDir, { recursive: true });
  const out = uniqueDest(destDir, safeBase(item.title), extFor(item), used);
  await fs.promises.writeFile(out, body);
  return out;
}

/** Download every item that has a file, into destDir. Never throws for one bad item — collects results. */
/**
 * @param {object[]} items
 * @param {string} destDir
 * @param {{state?: object, onKept?: (item: object, path: string) => void}} [opts]
 *        `state` is makerrun-sync-state's record of what is already on disk. Pass
 *        it and a design whose bytes have not moved is not fetched again; omit it
 *        and this behaves exactly as it always did.
 */
async function downloadAll(items, destDir, opts) {
  const o = opts || {};
  const state = o.state || null;
  const SyncState = state ? require('./makerrun-sync-state.js') : null;
  const saved = [], skipped = [], failed = [], kept = [];
  const unverified = [];
  const used = new Set(); // claimed output paths, so same-named designs don't clobber each other
  for (const it of items || []) {
    if (!it || !it.downloadUrl) { skipped.push(it && (it.title || it.slug)); continue; }
    // ALREADY HELD, and proved so — same checksum, same algorithm, same byte
    // timestamp, and the file is still where we left it. `kept` is reported apart
    // from `skipped` on purpose: skipped means "there was nothing to fetch",
    // kept means "you already have it", and a shop reading a sync result should
    // not have to guess which of those happened to its designs.
    const held = SyncState ? SyncState.alreadyHave(state, it) : null;
    if (held) {
      kept.push(held);
      used.add(held);
      continue;
    }
    try {
      const p = await downloadItem(it, destDir, used, o);
      if (p) {
        saved.push(p);
        if (o.onKept) o.onKept(it, p);
        if (it.__checksumVerified === false) unverified.push(it.title || it.slug);
        delete it.__checksumVerified;
      } else skipped.push(it.title || it.slug);
    } catch (e) {
      failed.push({ title: it.title || it.slug, error: e && e.message ? e.message : String(e) });
    }
  }
  return { saved, skipped, failed, kept, unverified };
}

const MAX_COVER_BYTES = 4 * 1024 * 1024; // a design cover thumbnail; anything larger isn't a thumbnail

/**
 * Fetch a design's cover image and return it as a `data:` URI. The covers live on remote hosts
 * (Supabase storage) that the renderer's CSP (correctly) forbids as `img-src`, so the privileged main
 * process fetches them — with the same SSRF/redirect guards as a file download — and hands back an
 * inline data URL the renderer can show without widening its CSP. Only real images, size-capped.
 */
async function fetchCoverDataUrl(url) {
  const res = await safeFetchDownload(url, AbortSignal.timeout(15000)); // https-only + per-hop re-validation
  if (!res.ok) throw new Error('Cover fetch failed (HTTP ' + res.status + ').');
  const ct = String(res.headers.get('content-type') || '').toLowerCase();
  if (!/^image\//.test(ct)) throw new Error('That cover is not an image.');
  const declared = Number(res.headers.get('content-length') || 0);
  if (declared > MAX_COVER_BYTES) throw new Error('Cover too large.');
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.length > MAX_COVER_BYTES) throw new Error('Cover too large.');
  return 'data:' + ct.split(';')[0].trim() + ';base64,' + buf.toString('base64');
}

/** Where the user connects the app (deep-link handoff page). */
const signInUrl = () => BASE + '/app-link';

const LIBRARY_FOLDER = 'MakerRun-Library';
const LEGACY_LIBRARY_FOLDER = 'BedReady-Library'; // what "Download to folder" used before the rename

/**
 * The folder "Download to folder" saves into, under the user's Downloads.
 *
 * The library was renamed BedReady → MakerRun, but a shop that already downloaded
 * designs has them sitting in Downloads/BedReady-Library. Renaming unconditionally
 * would not lose those files, but it would scatter one library across two folders
 * with no hint that the older half exists — so an existing folder keeps being used
 * and only a first-time download gets the new name. Nothing is moved or renamed on
 * disk: a rename here would be this code reaching into the user's Downloads, which
 * is theirs, not ours.
 *
 * The caller must report the folder it got back rather than naming one in a
 * message — which is why the IPC handler returns it and the UI string takes it as
 * a placeholder. A hardcoded folder name in a translated string is how the message
 * and the disk drift apart.
 */
function downloadsDir(downloadsRoot) {
  const legacy = path.join(downloadsRoot, LEGACY_LIBRARY_FOLDER);
  try { if (fs.existsSync(legacy)) return legacy; } catch { /* unreadable Downloads — use the new name */ }
  return path.join(downloadsRoot, LIBRARY_FOLDER);
}

module.exports = {
  explainLibraryStatus, syncLibrary, verifyChecksum, fetchAllPages, MAX_PAGES,
  fetchLibrary, downloadItem, downloadAll, fetchCoverDataUrl, signInUrl, safeBase, extFor, BASE,
  downloadsDir, LIBRARY_FOLDER, LEGACY_LIBRARY_FOLDER,
};
