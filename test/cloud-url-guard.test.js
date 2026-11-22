const { test } = require('node:test');
const assert = require('node:assert/strict');
const { validateCloudBaseUrl } = require('../lib/cloud-client.js');

/**
 * The cloud base URL is a user setting that reached fetch unchecked, and the
 * first thing sent to it is an email and password. The printer path in this
 * codebase validates its host, its port and its redirects; this one did none of
 * that.
 */

const rejects = (url, why) => assert.throws(() => validateCloudBaseUrl(url), undefined, why);

test('the shipped default is accepted', () => {
  assert.equal(validateCloudBaseUrl('https://cloud.khaytapp.com'), 'https://cloud.khaytapp.com');
});

test('a trailing slash is normalised away, not doubled into the path', () => {
  assert.equal(validateCloudBaseUrl('https://cloud.khaytapp.com/'), 'https://cloud.khaytapp.com');
});

test('plain http over the internet is refused — it would leak the password', () => {
  rejects('http://cloud.khaytapp.com', 'public http accepted');
  rejects('http://example.com:8080', 'public http with port accepted');
});

test('but self-hosting on the bench still works', () => {
  // A shop running its own server locally is a real case; refusing it would
  // break them for no security gain.
  for (const u of ['http://localhost:8080', 'http://127.0.0.1:3000',
                   'http://192.168.1.50', 'http://10.0.0.5:9000', 'http://172.16.4.4']) {
    assert.ok(validateCloudBaseUrl(u).startsWith('http://'), `${u} was refused`);
  }
});

test('https is always fine, including on a LAN', () => {
  assert.equal(validateCloudBaseUrl('https://192.168.1.50:8443'), 'https://192.168.1.50:8443');
});

test('credentials embedded in the URL are refused', () => {
  // These would be sent to — and very likely logged by — the far end.
  rejects('https://user:hunter2@evil.example.com', 'userinfo accepted');
  rejects('https://user@evil.example.com', 'username accepted');
});

test('the cloud metadata endpoint is never a Khayt server', () => {
  rejects('http://169.254.169.254/latest/meta-data', 'metadata endpoint accepted');
  rejects('https://169.254.169.254', 'metadata endpoint accepted over https');
});

test('non-http schemes are refused', () => {
  for (const u of ['file:///etc/passwd', 'ftp://example.com', 'javascript:alert(1)', 'data:text/plain,x']) {
    rejects(u, `${u} accepted`);
  }
});

test('junk is refused rather than concatenated into a request', () => {
  for (const u of ['', null, undefined, 'not a url', '//example.com', 'cloud.khaytapp.com']) {
    rejects(u, `${JSON.stringify(u)} accepted`);
  }
});

test('the transport pins redirects so a login cannot be bounced', () => {
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'cloud-client.js'), 'utf8');
  assert.match(src, /redirect: 'manual'/, 'redirects are followed by default');
  assert.match(src, /refusing to follow/, 'a redirect is not surfaced as an error');
});
