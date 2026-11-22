/**
 * A signature nobody can check is a signature you find out about from a failed
 * upload, weeks later, with no idea which of six inputs is wrong.
 *
 * So the signer is held to AWS's own published SigV4 test vector. That vector is
 * the whole reason to hand-roll this rather than pull in an SDK: it can be
 * proven right here, with no bucket, no credentials and no network.
 *
 * The rest covers what changed in porting it out of khayt-cloud, where it moves
 * JSON: this one moves 3MF and STL files, and a binary body round-tripped
 * through a JS string corrupts silently — the upload succeeds, the size looks
 * about right, and the mesh will not parse.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { signRequest, createS3, isConfigured, objectKey } = require('../lib/s3-client.js');

test('SigV4 reproduces the AWS get-vanilla published signature', () => {
  const auth = signRequest({
    method: 'GET',
    url: 'https://example.amazonaws.com/',
    headers: { Host: 'example.amazonaws.com', 'X-Amz-Date': '20150830T123600Z' },
    payloadHash: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    region: 'us-east-1',
    service: 'service',
    accessKeyId: 'AKIDEXAMPLE',
    secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
    amzDate: '20150830T123600Z',
  });
  assert.equal(
    auth,
    'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, '
    + 'SignedHeaders=host;x-amz-date, '
    + 'Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
  );
});

test('the query string is signed', () => {
  const base = {
    method: 'GET', headers: { Host: 'example.amazonaws.com', 'X-Amz-Date': '20150830T123600Z' },
    payloadHash: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    region: 'us-east-1', service: 'service', accessKeyId: 'AKIDEXAMPLE',
    secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY', amzDate: '20150830T123600Z',
  };
  assert.notEqual(
    signRequest({ ...base, url: 'https://example.amazonaws.com/' }),
    signRequest({ ...base, url: 'https://example.amazonaws.com/?Param1=value1' }),
  );
});

/** A bucket that remembers what it was given, so the client can be driven without a network. */
function fakeBucket() {
  const objects = new Map();
  const seen = [];
  const fetch = async (url, opts) => {
    const key = new URL(url).pathname.replace(/^\/[^/]+\//, '');   // strip /bucket/
    seen.push({ method: opts.method, key, auth: opts.headers.authorization, headers: opts.headers });
    if (opts.method === 'PUT') { objects.set(key, Buffer.from(opts.body)); return { status: 200, headers: new Map() }; }
    if (opts.method === 'GET') {
      const v = objects.get(key);
      if (!v) return { status: 404 };
      return { status: 200, arrayBuffer: async () => v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength) };
    }
    if (opts.method === 'HEAD') {
      const v = objects.get(key);
      if (!v) return { status: 404 };
      // Real buckets quote the etag. Tiering compares it against a local MD5 to
      // decide whether deleting the local copy is safe, so the quoting is not a
      // cosmetic detail — left on, every comparison fails and nothing is ever
      // evicted; stripped in the wrong place, every comparison passes.
      const etag = `"${crypto.createHash('md5').update(v).digest('hex')}"`;
      const hdrs = { 'content-length': String(v.length), etag };
      return { status: 200, headers: { get: (h) => (hdrs[String(h).toLowerCase()] ?? null) } };
    }
    if (opts.method === 'DELETE') { objects.delete(key); return { status: 204, headers: new Map() }; }
    return { status: 405 };
  };
  return { fetch, objects, seen };
}

const CFG = {
  endpoint: 'https://acct.r2.cloudflarestorage.com', region: 'auto',
  bucket: 'khayt', accessKeyId: 'AKIDEXAMPLE', secretAccessKey: 'secret',
};

test('binary survives the round trip byte for byte', () => {
  // The reason this port exists. Every byte value 0-255 twice over, plus the
  // sequences a text codec mangles: a lone surrogate half and an invalid UTF-8
  // continuation. A string-based client returns these subtly changed.
  const bucket = fakeBucket();
  const s3 = createS3(CFG, { fetch: bucket.fetch, now: () => '20150830T123600Z' });
  const payload = Buffer.concat([
    Buffer.from(Array.from({ length: 256 }, (_, i) => i)),
    Buffer.from([0xed, 0xa0, 0x80, 0xff, 0xfe, 0x00, 0x80]),
    crypto.randomBytes(4096),
  ]);
  return s3.put('k/model.3mf', payload)
    .then(() => s3.get('k/model.3mf'))
    .then((back) => {
      assert.ok(Buffer.isBuffer(back), 'a Buffer must come back, not a string');
      assert.equal(back.length, payload.length, 'the byte count changed in transit');
      assert.ok(back.equals(payload), 'the bytes changed in transit — a text codec touched them');
    });
});

test('a missing object is absent, not an error', async () => {
  const bucket = fakeBucket();
  const s3 = createS3(CFG, { fetch: bucket.fetch, now: () => '20150830T123600Z' });
  assert.equal(await s3.get('nothing/here'), null);
  assert.equal(await s3.head('nothing/here'), null);
});

test('head reports a size and an unquoted etag, and delete removes', async () => {
  const bucket = fakeBucket();
  const s3 = createS3(CFG, { fetch: bucket.fetch, now: () => '20150830T123600Z' });
  const body = Buffer.alloc(1234, 7);
  await s3.put('k/a.stl', body);
  // The etag is what makes eviction safe: for the single-part uploads this
  // client makes, it is the MD5 of the content, so it proves the bucket holds
  // these bytes and not merely this many bytes.
  assert.deepEqual(await s3.head('k/a.stl'), {
    size: 1234,
    etag: crypto.createHash('md5').update(body).digest('hex'),
  });
  await s3.del('k/a.stl');
  assert.equal(await s3.get('k/a.stl'), null);
});

test('a refused upload is reported, not swallowed', async () => {
  // A backup that reports success when the bucket said no is worse than none.
  const s3 = createS3(CFG, { fetch: async () => ({ status: 403 }), now: () => '20150830T123600Z' });
  await assert.rejects(() => s3.put('k/x', Buffer.from('hi')), /S3 put 403/);
});

test('every request is signed, and the body is part of the signature', async () => {
  const bucket = fakeBucket();
  const s3 = createS3(CFG, { fetch: bucket.fetch, now: () => '20150830T123600Z' });
  await s3.put('k/one', Buffer.from('aaa'));
  await s3.put('k/two', Buffer.from('bbb'));
  assert.ok(bucket.seen.every((r) => /^AWS4-HMAC-SHA256 /.test(r.auth)), 'an unsigned request went out');
  assert.notEqual(bucket.seen[0].auth, bucket.seen[1].auth,
    'two different uploads signed identically — the payload is not being hashed');
  assert.match(bucket.seen[0].headers['x-amz-content-sha256'], /^[0-9a-f]{64}$/);
});

test('a half-filled configuration is not a configuration', () => {
  assert.equal(isConfigured(CFG), true);
  assert.equal(isConfigured({}), false);
  assert.equal(isConfigured(null), false);
  for (const missing of ['endpoint', 'bucket', 'accessKeyId', 'secretAccessKey']) {
    assert.equal(isConfigured({ ...CFG, [missing]: '' }), false, `${missing} missing should not count as configured`);
    assert.equal(isConfigured({ ...CFG, [missing]: '   ' }), false, `${missing} blank should not count as configured`);
  }
  // region is the one thing with a sane default.
  assert.equal(isConfigured({ ...CFG, region: '' }), true);
});

test('keys are namespaced so one bucket can hold more than this', () => {
  assert.equal(objectKey('', 'PF-a', 'model.3mf'), 'print-files/PF-a/model.3mf');
  assert.equal(objectKey('shop1', 'PF-a', 'model.3mf'), 'shop1/print-files/PF-a/model.3mf');
  assert.equal(objectKey('/shop1/', 'PF-a', 'x'), 'shop1/print-files/PF-a/x', 'stray slashes would double up');
});
