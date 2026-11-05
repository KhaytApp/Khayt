'use strict';

/**
 * A minimal S3-compatible client — enough to PUT, GET, HEAD and DELETE one
 * object on S3, Cloudflare R2, Backblaze B2, Hostinger object storage, or
 * anything else that speaks SigV4. No SDK, no dependencies, native crypto.
 *
 * Ported from khayt-cloud's src/s3.js, which offloads the encrypted store blob
 * out of MySQL. Two deliberate differences:
 *
 *   - CommonJS, because this app is not ESM.
 *   - Bodies are BUFFERS, not strings. The cloud one moves JSON; this one moves
 *     3MF and STL files, and round-tripping binary through a JS string corrupts
 *     it silently — the file arrives, the byte count is close, and the mesh will
 *     not parse.
 *
 * The signer is byte-for-byte the same, so AWS's own published SigV4 test vector
 * still validates it (see test/s3-client.test.js). That vector is the whole
 * reason to hand-roll this rather than trust a signature nobody can check
 * without a live bucket and a failed upload.
 */

const crypto = require('crypto');

const sha256hex = (data) => crypto.createHash('sha256').update(data).digest('hex');
const hmac = (key, data) => crypto.createHmac('sha256', key).update(data).digest();
const EMPTY_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/** RFC 3986 — encodeURIComponent leaves !*'() alone; AWS wants them escaped. */
function enc(s) {
  return encodeURIComponent(s).replace(/[!*'()]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
}

function signingKey(secret, date, region, service) {
  return hmac(hmac(hmac(hmac('AWS4' + secret, date), region), service), 'aws4_request');
}

/** Build a SigV4 Authorization header. Pure — amzDate is passed in, so it is testable. */
function signRequest({ method, url, headers, payloadHash, region, service, accessKeyId, secretAccessKey, amzDate }) {
  const u = new URL(url);
  const canonicalUri = u.pathname || '/';
  const query = [...u.searchParams.entries()].map(([k, v]) => [enc(k), enc(v)])
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : (a[1] < b[1] ? -1 : 1)));
  const canonicalQuery = query.map(([k, v]) => `${k}=${v}`).join('&');
  const hdrs = Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v).trim().replace(/\s+/g, ' ')])
    .sort((a, b) => (a[0] < b[0] ? -1 : 1));
  const signedHeaders = hdrs.map(([k]) => k).join(';');
  const canonicalHeaders = hdrs.map(([k, v]) => `${k}:${v}\n`).join('');
  const canonicalRequest = [method, canonicalUri, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].join('\n');
  const date = amzDate.slice(0, 8);
  const scope = `${date}/${region}/${service}/aws4_request`;
  const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256hex(canonicalRequest)].join('\n');
  const sig = crypto.createHmac('sha256', signingKey(secretAccessKey, date, region, service)).update(stringToSign).digest('hex');
  return `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${sig}`;
}

/** Is this config complete enough to talk to a bucket at all? */
function isConfigured(cfg) {
  const c = cfg || {};
  return !!(String(c.endpoint || '').trim() && String(c.bucket || '').trim()
    && String(c.accessKeyId || '').trim() && String(c.secretAccessKey || '').trim());
}

/**
 * The object key a library file lives under.
 *
 * Prefixed so one bucket can hold more than this, and so a shop pointing two
 * machines at the same bucket does not have to invent a convention.
 */
function objectKey(prefix, id, filename) {
  const clean = String(prefix || '').replace(/^\/+|\/+$/g, '');
  const parts = [clean, 'print-files', String(id || ''), String(filename || '')].filter(Boolean);
  return parts.join('/');
}

/**
 * Path-style client bound to one bucket.
 * @param {{endpoint,region,bucket,accessKeyId,secretAccessKey}} cfg
 * @param {{fetch?: Function, now?: Function}} [deps]  injected so tests need no network
 */
function createS3(cfg, deps = {}) {
  const doFetch = deps.fetch || globalThis.fetch;
  const now = deps.now || (() => new Date().toISOString().replace(/[:-]/g, '').replace(/\.\d{3}/, ''));
  const base = String(cfg.endpoint || '').replace(/\/+$/, '');
  const region = cfg.region || 'auto';

  async function req(method, key, body) {
    const url = `${base}/${cfg.bucket}/${key}`;
    const u = new URL(url);
    const amzDate = now();
    const payloadHash = body ? sha256hex(body) : EMPTY_SHA256;
    const headers = { host: u.host, 'x-amz-content-sha256': payloadHash, 'x-amz-date': amzDate };
    if (body) headers['content-type'] = 'application/octet-stream';
    headers.authorization = signRequest({
      method, url, headers, payloadHash, region, service: 's3',
      accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey, amzDate,
    });
    return doFetch(url, { method, headers, body: body || undefined, signal: AbortSignal.timeout(120000) });
  }

  const ok = (r) => r.status >= 200 && r.status < 300;

  return {
    async put(key, buf) {
      const r = await req('PUT', key, buf);
      if (!ok(r)) throw new Error(`S3 put ${r.status}`);
      return true;
    },
    /** Buffer, or null when the object is not there. */
    async get(key) {
      const r = await req('GET', key);
      if (r.status === 404) return null;
      if (!ok(r)) throw new Error(`S3 get ${r.status}`);
      return Buffer.from(await r.arrayBuffer());
    },
    /**
     * `null` when the object is not there.
     *
     * The etag comes back as well as the size because tiering deletes the local
     * copy once the bucket has the file, and a size match is not proof: a
     * truncated-then-padded upload, or somebody else's object of the same length
     * under a colliding key, both pass it. For a single-part PUT — which is all
     * this client does — S3 and every compatible provider set the etag to the
     * hex MD5 of the content, so comparing it against a locally computed MD5 is
     * a real content check that costs no download.
     *
     * Multipart uploads use a `<hash>-<parts>` form instead. We never make one,
     * but a file put there by some other tool might be, so the caller has to
     * handle an etag it cannot interpret rather than assume it matches.
     */
    async head(key) {
      const r = await req('HEAD', key);
      if (r.status === 404) return null;
      if (!ok(r)) throw new Error(`S3 head ${r.status}`);
      return {
        size: Number(r.headers.get('content-length')) || 0,
        etag: String(r.headers.get('etag') || '').replace(/^"|"$/g, ''),
      };
    },
    async del(key) { try { await req('DELETE', key); } catch (_) { /* best-effort */ } },
    /**
     * Every object under a prefix: `[{ key, size, modified }]`. ListObjectsV2,
     * following continuation tokens, as the Mac's S3.list does — the off-site
     * backups read it to find what to restore and what to prune.
     */
    async list(prefix) {
      const out = [];
      let token = null;
      for (let page = 0; page < 100; page++) {
        const q = new URLSearchParams({ 'list-type': '2', prefix: String(prefix || '') });
        if (token) q.set('continuation-token', token);
        const url = `${base}/${cfg.bucket}?${q.toString()}`;
        const u = new URL(url);
        const amzDate = now();
        const headers = { host: u.host, 'x-amz-content-sha256': EMPTY_SHA256, 'x-amz-date': amzDate };
        headers.authorization = signRequest({
          method: 'GET', url, headers, payloadHash: EMPTY_SHA256, region, service: 's3',
          accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey, amzDate,
        });
        const r = await doFetch(url, { method: 'GET', headers, signal: AbortSignal.timeout(60000) });
        if (!ok(r)) throw new Error(`S3 list ${r.status}`);
        const parsed = parseListBucket(await r.text());
        out.push(...parsed.items);
        if (!parsed.truncated || !parsed.next) break;
        token = parsed.next;
      }
      return out;
    },
  };
}

/** `ListBucketResult` XML → `{ items: [{ key, size, modified }], truncated, next }`. Pure. */
function parseListBucket(xml) {
  const text = String(xml || '');
  const unxml = (v) => String(v).replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
  const tag = (src, name) => { const m = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(src); return m ? unxml(m[1]) : ''; };
  const items = [];
  for (const m of text.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)) {
    const k = tag(m[1], 'Key');
    if (!k) continue;
    items.push({ key: k, size: Number(tag(m[1], 'Size')) || 0, modified: tag(m[1], 'LastModified') || null });
  }
  return { items, truncated: /<IsTruncated>true<\/IsTruncated>/.test(text), next: tag(text, 'NextContinuationToken') || null };
}

module.exports = { signRequest, createS3, isConfigured, objectKey, parseListBucket };
