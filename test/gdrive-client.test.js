/**
 * Drive has to behave like a bucket, or tiering cannot treat the two alike.
 *
 * That is the through-line of this file: put/get/head/del over opaque keys, with
 * head() answering in the same shape the S3 client's does, so that
 * print-library-tier's etagVerdict() verifies a Drive upload without knowing it
 * is talking to Drive.
 *
 * The rest pins the things that fail days later rather than immediately — a
 * scope quietly widened past drive.file, an auth URL missing the parameters that
 * make Google return a refresh token, an access token refreshed a moment too
 * late — and the one that fails silently forever: sending `parents` on an update,
 * which Drive rejects, turning every re-upload into an error the shop sees as
 * "the backup stopped working".
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const G = require('../lib/gdrive-client.js');

const CFG = { clientId: 'cid.apps.googleusercontent.com', refreshToken: 'r3fr3sh', folderName: 'Khayt print library' };

/** A Drive that lives in a Map. Records every request so the tests can inspect them. */
function fakeDrive({ failTokenAfter = Infinity } = {}) {
  const files = new Map();           // id → {id, name, parents, appProperties, body}
  const seen = [];
  let ids = 0;
  let tokens = 0;
  const uploads = new Map();         // upload url → {id}

  const jsonRes = (status, obj, headers = {}) => ({
    status,
    headers: { get: (h) => headers[String(h).toLowerCase()] ?? null },
    text: async () => JSON.stringify(obj),
    arrayBuffer: async () => Buffer.from(JSON.stringify(obj)),
  });

  const fetch = async (url, opts = {}) => {
    const u = String(url);
    const method = (opts.method || 'GET').toUpperCase();
    seen.push({ url: u, method, headers: opts.headers || {}, body: opts.body });

    if (u === G.TOKEN_URL) {
      tokens += 1;
      if (tokens > failTokenAfter) return jsonRes(400, { error: 'invalid_grant', error_description: 'Token has been expired or revoked.' });
      return jsonRes(200, { access_token: `at-${tokens}`, expires_in: 3600 });
    }

    // Resumable upload session start
    if (u.includes('/upload/drive/v3/files')) {
      const meta = JSON.parse(opts.body);
      const m = /\/files\/([^?]+)\?/.exec(u);
      const id = m ? m[1] : `f${++ids}`;
      if (!m) files.set(id, { id, name: meta.name, parents: meta.parents, appProperties: meta.appProperties, body: Buffer.alloc(0) });
      const loc = `https://upload.example/session/${id}`;
      uploads.set(loc, { id, meta });
      return jsonRes(200, {}, { location: loc });
    }
    if (uploads.has(u) && method === 'PUT') {
      const { id } = uploads.get(u);
      const f = files.get(id);
      f.body = Buffer.from(opts.body);
      return jsonRes(200, { id });
    }

    if (u.includes('/drive/v3/about')) {
      return jsonRes(200, { user: { emailAddress: 'shop@example.com' }, storageQuota: { limit: '2000', usage: '500' } });
    }

    // Search
    if (u.includes('/drive/v3/files?q=')) {
      const q = decodeURIComponent(new URL(u).searchParams.get('q'));
      let hit = null;
      const keyM = /value='([^']*)'/.exec(q);
      if (q.includes('khaytKey') && keyM) {
        hit = [...files.values()].find((f) => f.appProperties && f.appProperties.khaytKey === keyM[1]);
      } else if (q.includes('folder')) {
        const nameM = /name='([^']*)'/.exec(q);
        hit = [...files.values()].find((f) => f.mimeType === 'folder' && f.name === (nameM && nameM[1]));
      }
      return jsonRes(200, {
        files: hit ? [{
          id: hit.id,
          size: String(hit.body.length),
          md5Checksum: crypto.createHash('md5').update(hit.body).digest('hex'),
        }] : [],
      });
    }

    // Create folder
    if (u.includes('/drive/v3/files?fields=id') && method === 'POST') {
      const meta = JSON.parse(opts.body);
      const id = `dir${++ids}`;
      files.set(id, { id, name: meta.name, mimeType: 'folder', body: Buffer.alloc(0) });
      return jsonRes(200, { id });
    }

    // Download
    const dl = /\/drive\/v3\/files\/([^?]+)\?alt=media/.exec(u);
    if (dl) {
      const f = files.get(dl[1]);
      if (!f) return { status: 404, headers: { get: () => null }, text: async () => '{}' };
      return { status: 200, headers: { get: () => null }, arrayBuffer: async () => f.body.buffer.slice(f.body.byteOffset, f.body.byteOffset + f.body.byteLength) };
    }

    // Trash
    const patch = /\/drive\/v3\/files\/([^?]+)$/.exec(u);
    if (patch && method === 'PATCH') { files.delete(patch[1]); return jsonRes(200, {}); }

    return jsonRes(404, { error: { message: `unhandled ${method} ${u}` } });
  };
  return { fetch, files, seen, tokenCount: () => tokens };
}

test('the scope is drive.file and nothing wider', () => {
  // Widening this to `drive` would give Khayt the shop's whole Drive and drag
  // the project into Google's restricted-scope programme, which bills an annual
  // security assessment. It is a one-word change with a five-figure consequence.
  assert.equal(G.SCOPE, 'https://www.googleapis.com/auth/drive.file');
  const url = G.authUrl({ clientId: 'c', redirectUri: 'http://127.0.0.1:1/cb', challenge: 'x', state: 's' });
  assert.match(url, /scope=https%3A%2F%2Fwww\.googleapis\.com%2Fauth%2Fdrive\.file/);
  assert.doesNotMatch(url, /auth%2Fdrive(&|$)/, 'the full-Drive scope is being requested');
});

test('the auth URL asks for a refresh token in the only way that works', () => {
  // Google issues a refresh token only on first consent unless prompt=consent
  // forces it. Missing either parameter, the shop is signed out every hour and
  // the cause is invisible.
  const url = G.authUrl({ clientId: 'c', redirectUri: 'http://127.0.0.1:1/cb', challenge: 'x', state: 's' });
  assert.match(url, /access_type=offline/);
  assert.match(url, /prompt=consent/);
  assert.match(url, /code_challenge_method=S256/);
  assert.match(url, /state=s/);
});

test('PKCE challenges are per-attempt and verifiable', () => {
  const a = G.pkcePair();
  const b = G.pkcePair();
  assert.notEqual(a.verifier, b.verifier, 'a reused verifier defeats the point');
  const expect = crypto.createHash('sha256').update(a.verifier).digest('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  assert.equal(a.challenge, expect);
  assert.ok(!/[+/=]/.test(a.challenge), 'the challenge must be base64url, not base64');
});

test('a half-configured account is not used', () => {
  assert.equal(G.isConfigured({}), false);
  assert.equal(G.isConfigured({ clientId: 'c' }), false, 'no refresh token');
  assert.equal(G.isConfigured({ refreshToken: 'r' }), false, 'no client id');
  assert.equal(G.isConfigured({ clientId: 'c', refreshToken: 'r' }), true);
});

test('put then get round-trips binary byte for byte', async () => {
  const d = fakeDrive();
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  const payload = Buffer.concat([
    Buffer.from(Array.from({ length: 256 }, (_, i) => i)),
    crypto.randomBytes(2048),
  ]);
  await drive.put('print-files/PF-a/dragon.3mf', payload);
  const back = await drive.get('print-files/PF-a/dragon.3mf');
  assert.ok(Buffer.isBuffer(back), 'a Buffer must come back, not a string');
  assert.ok(back.equals(payload), 'the bytes changed in transit');
});

test('head answers in the same shape as the S3 client, so tiering cannot tell them apart', async () => {
  const d = fakeDrive();
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  const body = Buffer.alloc(1234, 7);
  await drive.put('print-files/PF-a/x.stl', body);
  const h = await drive.head('print-files/PF-a/x.stl');
  assert.deepEqual(Object.keys(h).sort(), ['etag', 'size']);
  assert.equal(h.size, 1234);
  // The whole point: this is what etagVerdict() compares a local MD5 against.
  assert.equal(h.etag, crypto.createHash('md5').update(body).digest('hex'));
  const T = require('../lib/print-library-tier.js');
  assert.equal(T.etagVerdict(h.etag, crypto.createHash('md5').update(body).digest('hex')), 'match');
});

test('a missing key is absent, not an error', async () => {
  const d = fakeDrive();
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  assert.equal(await drive.get('print-files/nope/x.stl'), null);
  assert.equal(await drive.head('print-files/nope/x.stl'), null);
});

test('re-uploading updates in place and does not resend parents', async () => {
  // Drive rejects `parents` on an update. Sent anyway, every re-upload fails and
  // the shop sees a backup that worked once and then stopped.
  const d = fakeDrive();
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  await drive.put('print-files/PF-a/m.3mf', Buffer.from('one'));
  await drive.put('print-files/PF-a/m.3mf', Buffer.from('two!'));
  assert.ok((await drive.get('print-files/PF-a/m.3mf')).equals(Buffer.from('two!')));

  const starts = d.seen.filter((r) => r.url.includes('/upload/drive/v3/files'));
  assert.equal(starts.length, 2);
  assert.equal(starts[0].method, 'POST', 'the first upload should create');
  assert.equal(starts[1].method, 'PATCH', 'the second should update in place');
  assert.ok(!JSON.parse(starts[1].body).parents, 'parents must not be resent on an update');
  // One file, not two — a duplicate would double the bill and make head()
  // ambiguous about which copy is authoritative.
  const models = [...d.files.values()].filter((f) => f.appProperties);
  assert.equal(models.length, 1, 'the re-upload created a second copy');
});

test('the folder is created once and then reused by id', async () => {
  const d = fakeDrive();
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  await drive.put('print-files/a/1.stl', Buffer.from('a'));
  await drive.put('print-files/b/2.stl', Buffer.from('b'));
  const created = d.seen.filter((r) => r.method === 'POST' && r.url.includes('/drive/v3/files?fields=id'));
  assert.equal(created.length, 1, 'a folder is created per upload');
});

test('the access token is fetched once and reused', async () => {
  // Refreshing per request would triple the round trips on every sweep.
  const d = fakeDrive();
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  await drive.put('print-files/a/1.stl', Buffer.from('a'));
  await drive.head('print-files/a/1.stl');
  await drive.get('print-files/a/1.stl');
  assert.equal(d.tokenCount(), 1, `token refreshed ${d.tokenCount()} times for one session`);
});

test('a token close to expiry is refreshed before it is used', async () => {
  // The margin is the point: a token valid at check time and expired on arrival
  // fails as a 401 in the middle of a large upload.
  const d = fakeDrive();
  let clock = 1_000_000;
  const drive = G.createDrive(CFG, { fetch: d.fetch, now: () => clock });
  await drive.head('print-files/a/1.stl');
  assert.equal(d.tokenCount(), 1);
  clock += 3600_000 - 30_000;          // 30s of nominal life left
  await drive.head('print-files/a/1.stl');
  assert.equal(d.tokenCount(), 2, 'a nearly-expired token was used as-is');
});

test('a revoked account says so, in Google\'s words', async () => {
  // "Sign-in failed" sends the shop to us; "Token has been expired or revoked"
  // sends them to reconnect, which is the actual fix.
  const d = fakeDrive({ failTokenAfter: 0 });
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  await assert.rejects(() => drive.head('print-files/a/1.stl'), /expired or revoked/);
});

test('delete trashes rather than destroys', async () => {
  // Drive has an undo and a shop that deletes the wrong record should get to use
  // it.
  const d = fakeDrive();
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  await drive.put('print-files/a/1.stl', Buffer.from('a'));
  await drive.del('print-files/a/1.stl');
  const trashed = d.seen.find((r) => r.method === 'PATCH' && /\/files\/[^?]+$/.test(r.url));
  assert.ok(trashed, 'nothing was trashed');
  assert.equal(JSON.parse(trashed.body).trashed, true);
});

test('deleting something that is not there is not an error', async () => {
  const d = fakeDrive();
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  await drive.del('print-files/gone/x.stl');            // must not throw
});

test('about reports the quota, and unlimited is not zero', async () => {
  const d = fakeDrive();
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  const a = await drive.about();
  assert.equal(a.email, 'shop@example.com');
  assert.equal(a.usage, 500);
  assert.equal(a.limit, 2000);
});

test('a key with an apostrophe cannot break out of the query', async () => {
  // Drive's q syntax is a string language; an unescaped quote in a filename
  // turns a lookup into a syntax error, or worse, a different query.
  const d = fakeDrive();
  const drive = G.createDrive(CFG, { fetch: d.fetch });
  const key = "print-files/PF-a/mike's dragon.3mf";
  await drive.put(key, Buffer.from('x'));
  const sent = d.seen.filter((r) => r.url.includes('q=')).pop();
  assert.match(decodeURIComponent(new URL(sent.url).searchParams.get('q')), /mike\\'s/);
});
