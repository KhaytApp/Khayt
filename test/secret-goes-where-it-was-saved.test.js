'use strict';
// A saved secret goes only where it was saved to go (lib/secret-destination.js).
// The window holds the mask; main fills the real value in. It used to take the
// destination from the window as well, so a script there could send the mask
// plus its own address and be handed the shop's cloud token, accounting secret,
// SMTP password or webhook signature.
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { createStoreIo, STORE_SECRET_MASK } = require('../lib/store-io');
const { safeJsonParse } = require('../lib/safe-json');
const D = require('../lib/secret-destination');

let tmpDir;
beforeEach(() => { tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-secret-dest-')); });
afterEach(() => { fs.rmSync(tmpDir, { recursive: true, force: true }); });

function ioWithStore(store) {
  const io = createStoreIo({
    app: { getPath: () => tmpDir },
    fs,
    safeStorage: { isEncryptionAvailable: () => false, encryptString: (s) => Buffer.from(s), decryptString: (b) => b.toString() },
    safeJsonParse,
    crypto,
  });
  fs.writeFileSync(io.dataFilePath(), JSON.stringify(store));
  return io;
}

const saved = {
  settings: {
    cloud: { url: 'https://cloud.khaytapp.com/', token: 'real-cloud-token' },
    accountingSync: { webhookUrl: 'https://hooks.example.com/acct', secret: 'real-acct-secret' },
    emailConfig: { smtpHost: 'smtp.shop.sa', smtpPort: 465, smtpPassword: 'real-smtp-pass' },
  },
};
const cloudOf = (io, url) => io.resolveStoreSecretFor(STORE_SECRET_MASK, d => d.settings.cloud?.token,
  D.originKey(url), d => D.originKey(d.settings.cloud?.url));

test('the saved cloud token goes to the saved server', () => {
  const io = ioWithStore(saved);
  assert.equal(cloudOf(io, 'https://cloud.khaytapp.com'), 'real-cloud-token');
  assert.equal(cloudOf(io, 'https://CLOUD.khaytapp.com/v1/'), 'real-cloud-token');
});

test('the saved cloud token is refused for any other server', () => {
  const io = ioWithStore(saved);
  for (const url of ['https://evil.example', 'http://cloud.khaytapp.com', 'https://cloud.khaytapp.com.evil.example',
    'https://cloud.khaytapp.com:8443', '', 'not a url']) {
    assert.throws(() => cloudOf(io, url), /different address/, url);
  }
});

test('an empty token from the window is the saved one too, so it is bound the same way', () => {
  const io = ioWithStore(saved);
  assert.throws(() => io.resolveStoreSecretFor('', d => d.settings.cloud.token,
    D.originKey('https://evil.example'), d => D.originKey(d.settings.cloud.url)), /different address/);
});

test('a secret the window typed itself is not bound: it already knows it', () => {
  const io = ioWithStore(saved);
  assert.equal(io.resolveStoreSecretFor('typed-key', d => d.settings.cloud.token,
    D.originKey('https://anywhere.example'), d => D.originKey(d.settings.cloud.url)), 'typed-key');
});

test('nothing saved means nothing to bind', () => {
  const io = ioWithStore({ settings: {} });
  assert.equal(cloudOf(io, 'https://evil.example'), '');
});

test('a saved secret with no saved destination is refused', () => {
  const io = ioWithStore({ settings: { cloud: { token: 'orphan' } } });
  assert.throws(() => cloudOf(io, 'https://cloud.khaytapp.com'), /different address/);
});

test('the accounting secret is bound to the whole webhook URL', () => {
  const io = ioWithStore(saved);
  const acct = (url) => io.resolveStoreSecretFor(STORE_SECRET_MASK, d => d.settings.accountingSync.secret,
    D.urlKey(url), d => D.urlKey(d.settings.accountingSync.webhookUrl));
  assert.equal(acct('https://hooks.example.com/acct/'), 'real-acct-secret');
  assert.throws(() => acct('https://hooks.example.com/other'), /different address/);
  assert.throws(() => acct('https://evil.example/acct'), /different address/);
});

test('the SMTP password logs in only to the saved server and port', () => {
  const io = ioWithStore(saved);
  const smtp = (host, port) => io.resolveStoreSecretFor(STORE_SECRET_MASK, d => d.settings.emailConfig.smtpPassword,
    D.smtpKey(host, port), d => D.smtpKey(d.settings.emailConfig.smtpHost, d.settings.emailConfig.smtpPort));
  assert.equal(smtp('SMTP.shop.sa', '465'), 'real-smtp-pass');
  assert.throws(() => smtp('smtp.shop.sa', 587), /different address/);
  assert.throws(() => smtp('mail.evil.example', 465), /different address/);
});

test('keys: no key matches nothing, and an unset SMTP port is 587', () => {
  assert.equal(D.sameDestination('', ''), false);
  assert.equal(D.smtpKey('h', undefined), D.smtpKey('h', 587));
  assert.equal(D.urlKey('https://a.example/x/'), D.urlKey('https://A.example/x'));
  assert.notEqual(D.urlKey('https://a.example/x?k=1'), D.urlKey('https://a.example/x?k=2'));
});

// Wiring: the handlers that take a destination from the window use the bound
// resolver. A plain resolveStoreSecret for these secrets would reopen the hole.
test('main.js binds every secret whose destination the window names', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  for (const field of ['cloud?.token', 'accountingSync?.secret', 'eventWebhooks?.secret', 'emailConfig?.smtpPassword']) {
    const plain = src.split('\n').filter(l => l.includes('resolveStoreSecret(') && l.includes(`settings?.${field}`));
    // The lead-time publisher reads both the token and the URL from the store itself.
    const allowed = plain.filter(l => !/resolveStoreSecret\(cloud\.token,/.test(l));
    assert.deepEqual(allowed, [], `${field} resolved without its destination`);
  }
  assert.equal((src.match(/cloudToken\((?:token|authToken), url\)/g) || []).length >= 24, true);
  for (const h of ['hub:accounting-push', 'hub:webhook-post', 'hub:fire-webhook']) {
    const body = src.slice(src.indexOf(`ipcMain.handle('${h}'`)).slice(0, 2500);
    assert.match(body, /resolveStoreSecretFor\(/, h);
  }
  const sms = src.slice(src.indexOf("ipcMain.handle('hub:send-sms'")).slice(0, 1500);
  assert.match(sms, /provider === 'webhook'[\s\S]*resolveStoreSecretFor\([\s\S]*smsConfig\?\.url/);
});

// The window can also SAVE a new destination, and a save puts masked secrets
// back from disk. Moving a destination while its secret is masked drops it.
test('saving a new cloud server with the token still masked drops the token', () => {
  const io = ioWithStore(saved);
  const out = io.mergeStoreSecretsFromDisk({ settings: { ...saved.settings,
    cloud: { url: 'https://evil.example', token: STORE_SECRET_MASK } } });
  assert.equal(out.settings.cloud.token, '');
});

test('saving anything else keeps every saved secret', () => {
  const io = ioWithStore(saved);
  const out = io.mergeStoreSecretsFromDisk({ settings: {
    cloud: { url: 'https://cloud.khaytapp.com', token: STORE_SECRET_MASK },
    accountingSync: { webhookUrl: 'https://hooks.example.com/acct/', secret: STORE_SECRET_MASK },
    emailConfig: { smtpHost: 'smtp.shop.sa', smtpPort: '465', smtpPassword: STORE_SECRET_MASK },
  } });
  assert.equal(out.settings.cloud.token, 'real-cloud-token');
  assert.equal(out.settings.accountingSync.secret, 'real-acct-secret');
  assert.equal(out.settings.emailConfig.smtpPassword, 'real-smtp-pass');
});

test('moving the accounting webhook or the SMTP server drops their masked secrets', () => {
  const io = ioWithStore(saved);
  const out = io.mergeStoreSecretsFromDisk({ settings: {
    cloud: saved.settings.cloud,
    accountingSync: { webhookUrl: 'https://evil.example/acct', secret: STORE_SECRET_MASK },
    emailConfig: { smtpHost: 'mail.evil.example', smtpPort: 465 },
  } });
  assert.equal(out.settings.accountingSync.secret, '');
  assert.equal(out.settings.emailConfig.smtpPassword, '');
});

test('a new destination with a newly typed secret keeps the typed one', () => {
  const io = ioWithStore(saved);
  const out = io.mergeStoreSecretsFromDisk({ settings: { ...saved.settings,
    cloud: { url: 'https://other.khayt.example', token: 'fresh-login-token' } } });
  assert.equal(out.settings.cloud.token, 'fresh-login-token');
});

test('every bound section is one whose secret is masked for the window', () => {
  const { SECRET_PATHS } = require('../lib/store-secret-paths');
  for (const b of D.BOUND_SECRETS) for (const f of b.secrets) {
    assert.ok(SECRET_PATHS.includes(`settings.${b.section}.${f}`), `${b.section}.${f}`);
  }
});
