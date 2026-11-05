'use strict';

/**
 * Google Drive as a print-library backend.
 *
 * Every other provider Khayt talks to is S3, and lib/s3-client.js covers all of
 * them in 126 lines because they share a protocol. Drive shares nothing with it,
 * which is the whole reason this file exists — and the reason it is the only
 * non-S3 backend: the same work would have to be redone from scratch for Dropbox
 * and OneDrive, and a shop that wants those already has them as a synced folder
 * through settings.printLibrary.root, at no code cost at all.
 *
 * Drive earns the exception because a large share of makers already pay for the
 * storage and would rather not open a second account to use it.
 *
 * ── The scope, which is the most important decision here ────────────────────
 * `drive.file` — and NOT `drive`, `drive.readonly`, or anything else.
 *
 * `drive.file` grants access only to files this app itself created. It cannot
 * read the shop's tax returns, its family photos, or anything it did not put
 * there. That is the right level of access on its own merits, and it also keeps
 * this out of Google's restricted-scope programme: the broad Drive scopes are
 * "restricted", which means an annual third-party security assessment costing
 * more than most shops using Khayt make in a year. `drive.file` is not.
 *
 * The cost of `drive.file` is that the app cannot adopt files already in Drive —
 * a library uploaded by hand is invisible to it. That is a real limitation, it
 * is stated in the docs, and it is still the right trade.
 *
 * ── Why keys live in appProperties rather than folders ──────────────────────
 * S3 keys are paths; Drive has no paths, only parent ids, and two files in one
 * folder may share a name. Rebuilding `print-files/<id>/<name>` as a folder tree
 * would mean a lookup per path segment on every operation, and would break the
 * moment someone tidied their Drive.
 *
 * So every file goes in ONE app folder, tagged `appProperties.khaytKey` with the
 * S3-style key it would have had. Lookup is a single indexed query, the shop can
 * move or rename the folder freely, and the same key works across backends —
 * which is what lets tiering treat Drive and a bucket identically.
 *
 * Drive returns `md5Checksum` on file metadata, so head() can answer in exactly
 * the shape the S3 client's etag does, and print-library-tier's etagVerdict()
 * verifies a Drive upload with no extra work and no download.
 *
 * No Electron and no fs: fetch is injected, so this is testable without a
 * network or a Google account.
 */

const crypto = require('crypto');

const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const API = 'https://www.googleapis.com/drive/v3';
const UPLOAD = 'https://www.googleapis.com/upload/drive/v3';

/** Only files this app made. See the note above before widening this. */
const SCOPE = 'https://www.googleapis.com/auth/drive.file';

const str = (v) => String(v == null ? '' : v).trim();
const b64url = (buf) => buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/**
 * PKCE, which is what makes a desktop OAuth flow safe.
 *
 * A desktop app cannot keep a client secret — it ships inside the app, where
 * anyone can read it. PKCE replaces that with a one-time secret generated per
 * attempt: the authorisation request commits to a hash, and only the process
 * holding the original can redeem the code. Another app that intercepts the
 * redirect gets a code it cannot spend.
 */
function pkcePair() {
  const verifier = b64url(crypto.randomBytes(48));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
  return { verifier, challenge };
}

/**
 * Where to send the browser.
 *
 * `access_type=offline` with `prompt=consent` is what makes Google return a
 * refresh token. Without both, the shop reconnects every hour — and Google only
 * issues a refresh token on the FIRST consent unless prompt=consent forces it,
 * which is a failure that appears days later as "it keeps signing me out".
 */
function authUrl({ clientId, redirectUri, challenge, state }) {
  const q = new URLSearchParams({
    client_id: str(clientId),
    redirect_uri: str(redirectUri),
    response_type: 'code',
    scope: SCOPE,
    code_challenge: str(challenge),
    code_challenge_method: 'S256',
    access_type: 'offline',
    prompt: 'consent',
    state: str(state),
  });
  return `${AUTH_URL}?${q.toString()}`;
}

async function postForm(doFetch, url, params) {
  const r = await doFetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params).toString(),
    signal: AbortSignal.timeout(30000),
  });
  const text = await r.text();
  let body;
  try { body = JSON.parse(text); } catch (_) { body = {}; }
  if (r.status < 200 || r.status >= 300) {
    // Google's errors are genuinely useful and the shop cannot see them
    // otherwise — "redirect_uri_mismatch" tells them exactly what to fix in the
    // Cloud console, where "Sign-in failed" sends them to us.
    const msg = body.error_description || body.error || `HTTP ${r.status}`;
    throw new Error(String(msg));
  }
  return body;
}

/** Swap the one-time code for tokens. */
async function exchangeCode(doFetch, { clientId, clientSecret, code, verifier, redirectUri }) {
  return postForm(doFetch, TOKEN_URL, {
    client_id: str(clientId),
    ...(str(clientSecret) ? { client_secret: str(clientSecret) } : {}),
    code: str(code),
    code_verifier: str(verifier),
    grant_type: 'authorization_code',
    redirect_uri: str(redirectUri),
  });
}

async function refreshToken(doFetch, { clientId, clientSecret, refresh }) {
  return postForm(doFetch, TOKEN_URL, {
    client_id: str(clientId),
    ...(str(clientSecret) ? { client_secret: str(clientSecret) } : {}),
    refresh_token: str(refresh),
    grant_type: 'refresh_token',
  });
}

/** Enough to attempt a connection at all. */
function isConfigured(cfg) {
  const c = cfg || {};
  return !!(str(c.clientId) && str(c.refreshToken));
}

/**
 * A Drive-backed store with the same surface as createS3(): put/get/head/del over
 * opaque string keys. Tiering does not know which one it is holding.
 *
 * @param {{clientId,clientSecret,refreshToken,folderId,folderName}} cfg
 * @param {{fetch?: Function, now?: Function, onTokens?: Function}} [deps]
 */
function createDrive(cfg, deps = {}) {
  const doFetch = deps.fetch || globalThis.fetch;
  const now = deps.now || (() => Date.now());
  let access = '';
  let expires = 0;
  let folderId = str(cfg.folderId);

  /**
   * A valid access token, refreshed when it is close to expiring.
   *
   * The 60-second margin matters: a token that is valid when checked and expired
   * when the request lands fails as a 401 in the middle of a 400 MB upload.
   */
  async function token() {
    if (access && now() < expires - 60000) return access;
    const t = await refreshToken(doFetch, {
      clientId: cfg.clientId, clientSecret: cfg.clientSecret, refresh: cfg.refreshToken,
    });
    access = str(t.access_token);
    expires = now() + (Number(t.expires_in) || 3600) * 1000;
    if (!access) throw new Error('Google did not return an access token.');
    return access;
  }

  async function api(url, opts = {}) {
    const headers = { ...(opts.headers || {}), authorization: `Bearer ${await token()}` };
    return doFetch(url, { ...opts, headers, signal: opts.signal || AbortSignal.timeout(120000) });
  }

  async function json(url, opts) {
    const r = await api(url, opts);
    const text = await r.text();
    let body;
    try { body = JSON.parse(text); } catch (_) { body = {}; }
    if (r.status < 200 || r.status >= 300) {
      throw new Error(String((body.error && body.error.message) || `Drive ${r.status}`));
    }
    return body;
  }

  /**
   * The app's folder, created on first use.
   *
   * Looked up by name only when no id is stored, and the id is what is kept
   * afterwards — so the shop can rename the folder or move it anywhere in their
   * Drive without breaking the library. Trashed folders are excluded or the app
   * adopts a folder the shop deliberately threw away.
   */
  async function ensureFolder() {
    if (folderId) return folderId;
    const name = str(cfg.folderName) || 'Khayt print library';
    const q = `mimeType='application/vnd.google-apps.folder' and name='${name.replace(/'/g, "\\'")}' and trashed=false`;
    const found = await json(`${API}/files?q=${encodeURIComponent(q)}&fields=files(id)&pageSize=1`);
    if (found.files && found.files.length) { folderId = found.files[0].id; return folderId; }
    const made = await json(`${API}/files?fields=id`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name, mimeType: 'application/vnd.google-apps.folder' }),
    });
    folderId = str(made.id);
    if (!folderId) throw new Error('Could not create the Drive folder.');
    return folderId;
  }

  /** The file carrying this key, or null. One indexed query, no path walking. */
  async function findByKey(key) {
    const k = str(key).replace(/'/g, "\\'");
    const q = `appProperties has { key='khaytKey' and value='${k}' } and trashed=false`;
    const r = await json(`${API}/files?q=${encodeURIComponent(q)}&fields=files(id,size,md5Checksum)&pageSize=1`);
    return r.files && r.files.length ? r.files[0] : null;
  }

  return {
    ensureFolder,
    findByKey,

    /**
     * Resumable upload, even though we send the body in one request.
     *
     * Drive's simple and multipart uploads are capped at 5 MB, which most model
     * files clear on their own. The resumable endpoint has no such cap; starting
     * a session and then sending the whole body is the documented way to use it
     * for a file you already hold in memory.
     */
    async put(key, buf) {
      const parent = await ensureFolder();
      const existing = await findByKey(key);
      const name = str(key).split('/').pop() || 'model';
      const meta = existing
        ? { name }                                   // updating: parents cannot be re-sent
        : { name, parents: [parent], appProperties: { khaytKey: str(key) } };

      const start = await api(
        `${UPLOAD}/files${existing ? `/${existing.id}` : ''}?uploadType=resumable&fields=id`,
        {
          method: existing ? 'PATCH' : 'POST',
          headers: { 'content-type': 'application/json; charset=UTF-8' },
          body: JSON.stringify(meta),
        },
      );
      if (start.status < 200 || start.status >= 300) throw new Error(`Drive upload start ${start.status}`);
      const location = start.headers.get('location');
      if (!location) throw new Error('Drive did not return an upload URL.');

      const put = await doFetch(location, {
        method: 'PUT',
        headers: { 'content-type': 'application/octet-stream', 'content-length': String(buf.length) },
        body: buf,
        signal: AbortSignal.timeout(600000),         // a 400 MB model over a shop's uplink
      });
      if (put.status < 200 || put.status >= 300) throw new Error(`Drive upload ${put.status}`);
      return true;
    },

    /** Buffer, or null when nothing carries that key. */
    async get(key) {
      const f = await findByKey(key);
      if (!f) return null;
      const r = await api(`${API}/files/${f.id}?alt=media`);
      if (r.status === 404) return null;
      if (r.status < 200 || r.status >= 300) throw new Error(`Drive get ${r.status}`);
      return Buffer.from(await r.arrayBuffer());
    },

    /**
     * Size and checksum, in the shape the S3 client's head() returns.
     *
     * Drive's md5Checksum is exactly what an S3 etag is for a single-part
     * upload, so print-library-tier's etagVerdict() verifies a Drive upload
     * without knowing it is talking to Drive.
     */
    async head(key) {
      const f = await findByKey(key);
      if (!f) return null;
      return { size: Number(f.size) || 0, etag: str(f.md5Checksum) };
    },

    /** Best-effort, and to the trash rather than gone: Drive has an undo, so use it. */
    async del(key) {
      try {
        const f = await findByKey(key);
        if (!f) return;
        await api(`${API}/files/${f.id}`, {
          method: 'PATCH',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ trashed: true }),
        });
      } catch (_) { /* best-effort, like the S3 client's */ }
    },

    /**
     * The files whose key starts with `keyPrefix` and whose name contains
     * `nameContains`: `[{ key, size, modified }]`. Searched by name (Drive
     * cannot search a property by prefix) and then held to the key, because a
     * file's key is a property anyone with the folder can set.
     */
    async list(keyPrefix, nameContains) {
      const out = [];
      const q = `name contains '${str(nameContains).replace(/'/g, "\\'")}' and trashed=false`;
      let page = '';
      for (let i = 0; i < 50; i++) {
        const r = await json(`${API}/files?q=${encodeURIComponent(q)}&fields=nextPageToken,files(id,size,modifiedTime,appProperties)&pageSize=1000${page ? `&pageToken=${encodeURIComponent(page)}` : ''}`);
        for (const f of r.files || []) {
          const k = str(f.appProperties && f.appProperties.khaytKey);
          if (k && k.startsWith(str(keyPrefix))) out.push({ key: k, size: Number(f.size) || 0, modified: f.modifiedTime || null });
        }
        if (!r.nextPageToken) break;
        page = r.nextPageToken;
      }
      return out;
    },

    /** Who is connected, and how full their Drive is. */
    async about() {
      const r = await json(`${API}/about?fields=user(emailAddress),storageQuota(limit,usage)`);
      const q = r.storageQuota || {};
      return {
        email: str(r.user && r.user.emailAddress),
        usage: Number(q.usage) || 0,
        // Unlimited plans report no limit at all, which is not the same as zero.
        limit: q.limit == null ? null : Number(q.limit),
      };
    },
  };
}

module.exports = {
  SCOPE, AUTH_URL, TOKEN_URL,
  pkcePair, authUrl, exchangeCode, refreshToken, isConfigured, createDrive,
};
