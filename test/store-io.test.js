const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { createStoreIo, STORE_SECRET_MASK } = require('../lib/store-io');
const { safeJsonParse } = require('../lib/safe-json');

let tmpDir;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-store-io-'));
});

afterEach(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

function makeStoreIo({ encryption = false } = {}) {
  const safeStorage = {
    isEncryptionAvailable: () => encryption,
    encryptString: (plain) => Buffer.from(`test:${plain}`, 'utf8'),
    decryptString: (buf) => {
      const s = buf.toString('utf8');
      return s.startsWith('test:') ? s.slice(5) : '';
    },
  };
  return createStoreIo({
    app: { getPath: () => tmpDir },
    fs,
    safeStorage,
    safeJsonParse,
    crypto,
  });
}

test('isStoreSecretMasked recognises mask token', () => {
  const { isStoreSecretMasked } = makeStoreIo();
  assert.equal(isStoreSecretMasked(STORE_SECRET_MASK), true);
  assert.equal(isStoreSecretMasked('real-key'), false);
  assert.equal(isStoreSecretMasked(''), false);
});

test('ensureLanCalendarToken generates and reuses calendar token', () => {
  const { ensureLanCalendarToken } = makeStoreIo();
  const store = { settings: { lanApi: {} } };
  const first = ensureLanCalendarToken(store);
  assert.equal(first.generated, true);
  assert.ok(first.token.length >= 16);
  const second = ensureLanCalendarToken(store);
  assert.equal(second.generated, false);
  assert.equal(second.token, first.token);
});

test('maskStoreSecretsForRenderer masks accessCode-only printer configs', () => {
  const { maskStoreSecretsForRenderer } = makeStoreIo();
  const data = {
    machines: [{ id: 'm2', printerApi: { accessCode: 'code-only' } }],
  };
  maskStoreSecretsForRenderer(data);
  assert.equal(data.machines[0].printerApi.accessCode, STORE_SECRET_MASK);
});

test('maskStoreSecretsForRenderer replaces sensitive fields', () => {
  const { maskStoreSecretsForRenderer } = makeStoreIo();
  const data = {
    settings: {
      emailConfig: { apiKey: 'smtp-secret' },
      telegram: { botToken: 'tg-token' },
      lanApi: { pin: '1234', intakeToken: 'abc' },
    },
    machines: [{ id: 'm1', printerApi: { apiKey: 'pk', accessCode: 'ac' } }],
  };
  maskStoreSecretsForRenderer(data);
  assert.equal(data.settings.emailConfig.apiKey, STORE_SECRET_MASK);
  assert.equal(data.settings.telegram.botToken, STORE_SECRET_MASK);
  assert.equal(data.settings.lanApi.pin, STORE_SECRET_MASK);
  assert.equal(data.machines[0].printerApi.apiKey, STORE_SECRET_MASK);
  assert.equal(data.machines[0].printerApi.accessCode, STORE_SECRET_MASK);
});

test('encryptForDisk prefixes secrets when encryption is available', () => {
  const { encryptForDisk } = makeStoreIo({ encryption: true });
  const out = encryptForDisk({
    settings: { emailConfig: { apiKey: 'plain-key' } },
  });
  assert.match(out.settings.emailConfig.apiKey, /^__enc__/);
});

test('mergeStoreSecretsFromDisk keeps disk value when renderer sends mask', async () => {
  const io = makeStoreIo({ encryption: false });
  const diskStore = {
    settings: { emailConfig: { apiKey: 'disk-smtp-key' } },
    machines: [{ id: 'm1', printerApi: { apiKey: 'disk-printer-key' } }],
  };
  await fs.promises.writeFile(
    io.dataFilePath(),
    JSON.stringify(io.encryptForDisk(diskStore)),
    'utf8'
  );
  const incoming = {
    settings: { emailConfig: { apiKey: STORE_SECRET_MASK } },
    machines: [{ id: 'm1', printerApi: { apiKey: STORE_SECRET_MASK } }],
  };
  const merged = io.mergeStoreSecretsFromDisk(incoming);
  assert.equal(merged.settings.emailConfig.apiKey, 'disk-smtp-key');
  assert.equal(merged.machines[0].printerApi.apiKey, 'disk-printer-key');
});

test('mergeStoreSecretsFromDisk does not merge machine secrets by array index', async () => {
  const io = makeStoreIo({ encryption: false });
  const diskStore = {
    machines: [
      { id: 'a', printerApi: { apiKey: 'key-a' } },
      { id: 'b', printerApi: { apiKey: 'key-b' } },
    ],
  };
  await fs.promises.writeFile(
    io.dataFilePath(),
    JSON.stringify(io.encryptForDisk(diskStore)),
    'utf8'
  );
  const incoming = {
    machines: [
      { id: 'b', printerApi: { apiKey: STORE_SECRET_MASK } },
      { id: 'a', printerApi: { apiKey: STORE_SECRET_MASK } },
    ],
  };
  const merged = io.mergeStoreSecretsFromDisk(incoming);
  assert.equal(merged.machines[0].printerApi.apiKey, 'key-b');
  assert.equal(merged.machines[1].printerApi.apiKey, 'key-a');
});

test('mergeStoreSecretsFromDisk keeps renderer value when not masked', async () => {
  const io = makeStoreIo({ encryption: false });
  const diskStore = { settings: { emailConfig: { apiKey: 'old-key' } } };
  await fs.promises.writeFile(
    io.dataFilePath(),
    JSON.stringify(io.encryptForDisk(diskStore)),
    'utf8'
  );
  const merged = io.mergeStoreSecretsFromDisk({
    settings: { emailConfig: { apiKey: 'new-key' } },
  });
  assert.equal(merged.settings.emailConfig.apiKey, 'new-key');
});

test('writeStoreToDisk and readStoreDecryptedFromDisk round-trip', async () => {
  const io = makeStoreIo({ encryption: true });
  let updated = null;
  const ioWithHook = createStoreIo({
    app: { getPath: () => tmpDir },
    fs,
    safeStorage: {
      isEncryptionAvailable: () => true,
      encryptString: (p) => Buffer.from(`test:${p}`, 'utf8'),
      decryptString: (buf) => buf.toString('utf8').slice(5),
    },
    safeJsonParse,
    crypto,
    onStoreUpdated: (d) => { updated = d; },
  });
  const store = {
    settings: { telegram: { botToken: 'my-bot' } },
    printLog: [],
  };
  await ioWithHook.writeStoreToDisk(store);
  assert.equal(updated?.settings?.telegram?.botToken, 'my-bot');
  const fromDisk = ioWithHook.readStoreDecryptedFromDisk();
  assert.equal(fromDisk.settings.telegram.botToken, 'my-bot');
});

test('migrateLanApiSecrets copies legacy webhook fields into lanApi', () => {
  const { migrateLanApiSecrets } = makeStoreIo();
  const store = {
    settings: {
      sallaWebhookSecret: 'salla-sec',
      zidWebhookSecret: 'zid-sec',
      lanApi: {},
    },
  };
  migrateLanApiSecrets(store);
  assert.equal(store.settings.lanApi.sallaWebhookSecret, 'salla-sec');
  assert.equal(store.settings.lanApi.zidWebhookSecret, 'zid-sec');
});

test('ensureLanIntakeToken generates token when missing', () => {
  const { ensureLanIntakeToken } = makeStoreIo();
  const store = { settings: { lanApi: {} } };
  const r = ensureLanIntakeToken(store);
  assert.equal(r.generated, true);
  assert.match(r.token, /^[a-f0-9]{32}$/);
  assert.equal(store.settings.lanApi.intakeToken, r.token);
});

test('ensureLanIntakeToken does not replace existing token', () => {
  const { ensureLanIntakeToken } = makeStoreIo();
  const store = { settings: { lanApi: { intakeToken: 'existing' } } };
  const r = ensureLanIntakeToken(store);
  assert.equal(r.generated, false);
  assert.equal(r.token, 'existing');
});

test('resolveStoreSecret returns incoming when not masked', async () => {
  const { resolveStoreSecret } = makeStoreIo();
  const v = resolveStoreSecret('live-key', () => 'disk-key');
  assert.equal(v, 'live-key');
});

test('resolveStoreSecret reads from disk when masked', async () => {
  const io = makeStoreIo({ encryption: false });
  await fs.promises.writeFile(
    io.dataFilePath(),
    JSON.stringify({
      settings: { telegram: { botToken: 'disk-bot' } },
    }),
    'utf8'
  );
  const v = io.resolveStoreSecret(STORE_SECRET_MASK, d => d?.settings?.telegram?.botToken);
  assert.equal(v, 'disk-bot');
});

// --- Atomic/durable write + crash recovery (Beat B data-safety) ---

test('atomicWriteStore writes the store and keeps a one-generation .prev rollback', async () => {
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  await io.atomicWriteStore(JSON.stringify({ v: 1 }));
  assert.equal(safeJsonParse(fs.readFileSync(fp, 'utf8')).v, 1);
  assert.equal(fs.existsSync(fp + '.prev'), false); // nothing to roll back on the first write
  await io.atomicWriteStore(JSON.stringify({ v: 2 }));
  assert.equal(safeJsonParse(fs.readFileSync(fp, 'utf8')).v, 2);
  assert.equal(safeJsonParse(fs.readFileSync(fp + '.prev', 'utf8')).v, 1); // previous generation preserved
});

test('recoverStoreRaw reads a valid primary', () => {
  const io = makeStoreIo();
  fs.writeFileSync(io.dataFilePath(), JSON.stringify({ printLog: [{ id: 'O' }] }));
  const r = io.recoverStoreRaw();
  assert.equal(r.source, 'primary');
  assert.equal(r.data.printLog[0].id, 'O');
});

test('recoverStoreRaw quarantines a corrupt primary and restores from .prev', () => {
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  fs.writeFileSync(fp + '.prev', JSON.stringify({ good: true }));
  fs.writeFileSync(fp, '{ this is not valid json');
  const r = io.recoverStoreRaw();
  assert.equal(r.source, 'prev');
  assert.equal(r.data.good, true);
  assert.ok(r.quarantined && fs.existsSync(r.quarantined), 'corrupt primary preserved aside');
  assert.equal(fs.readFileSync(r.quarantined, 'utf8'), '{ this is not valid json');
  assert.ok(fs.existsSync(fp), 'primary restored from prev');
});

test('recoverStoreRaw recovers from a completed .tmp when the primary is missing', () => {
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  fs.writeFileSync(fp + '.tmp', JSON.stringify({ fromTmp: 1 }));
  const r = io.recoverStoreRaw();
  assert.equal(r.source, 'tmp');
  assert.equal(r.data.fromTmp, 1);
  assert.ok(fs.existsSync(fp), 'tmp promoted to primary');
});

/* ── Crash recovery from a UNIQUELY-NAMED temp ─────────────────────────────
 * The test above covers the legacy bare `fp.tmp`. Every write this build makes
 * uses `fp.tmp.<pid>.<n>` (unique so concurrent writers cannot cross-write), so
 * the uniquely-named form is what a real interrupted write leaves behind today.
 *
 * That is not hypothetical: #495 was a redundant post-flush save killed by
 * app.quit() between atomicWriteStore's two renames — primary already moved to
 * .prev, new temp not yet swapped in. On disk that is exactly: no primary, a
 * good .prev, and an orphaned .tmp.<pid>.<n>. Recovery from that shape is the
 * difference between a shop losing a session and not noticing anything. */

test('recoverStoreRaw recovers from a uniquely-named temp (what a real crash leaves)', () => {
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  fs.writeFileSync(`${fp}.tmp.12345.1`, JSON.stringify({ fromUniqueTmp: 1 }));
  const r = io.recoverStoreRaw();
  assert.equal(r.source, 'tmp');
  assert.equal(r.data.fromUniqueTmp, 1);
  assert.ok(fs.existsSync(fp), 'the recovered temp is promoted to primary');
});

test('the exact #495 shape recovers: no primary, good .prev, orphaned unique temp', () => {
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  // atomicWriteStore got as far as renaming the primary away, then died.
  fs.writeFileSync(fp + '.prev', JSON.stringify({ gen: 'previous', printLog: [] }));
  fs.writeFileSync(`${fp}.tmp.999.7`, JSON.stringify({ gen: 'interrupted', printLog: [] }));
  const r = io.recoverStoreRaw();
  assert.ok(r.data, 'a shop in this state must not be treated as a fresh install');
  assert.equal(r.existed, true, 'existed:false here would trigger the setup wizard and overwrite the backup');
  // The interrupted write is NEWER and complete, so it is the closest to the owner's work.
  assert.equal(r.data.gen, 'interrupted');
  assert.ok(fs.existsSync(fp), 'primary restored');
});

test('the newest orphaned temp wins when several survive', () => {
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  fs.writeFileSync(`${fp}.tmp.1.1`, JSON.stringify({ which: 'older' }));
  fs.utimesSync(`${fp}.tmp.1.1`, new Date(1000), new Date(1000));
  fs.writeFileSync(`${fp}.tmp.1.2`, JSON.stringify({ which: 'newer' }));
  fs.utimesSync(`${fp}.tmp.1.2`, new Date(90000), new Date(90000));
  const r = io.recoverStoreRaw();
  assert.equal(r.data.which, 'newer', 'the most recent interrupted write is closest to the owner\'s work');
});

test('a stale orphaned temp does not outrank a fresh .prev', () => {
  // A write killed between writeFile and the swap orphans its temp file for good —
  // nothing has ever cleaned one up, and every later save renames a DIFFERENT temp
  // into place. Recovery preferred any temp over .prev, so an interrupted write from
  // July outranked yesterday's save, and the shop was handed back a two-month-old
  // store under the words "Recovered your data from a backup".
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  const july = new Date(Date.now() - 60 * 24 * 3600 * 1000);
  fs.writeFileSync(`${fp}.tmp.999.1`, JSON.stringify({ gen: 'july-orphan', printLog: [] }));
  fs.utimesSync(`${fp}.tmp.999.1`, july, july);
  fs.writeFileSync(fp + '.prev', JSON.stringify({ gen: 'yesterday', printLog: [] }));
  fs.writeFileSync(fp, '{ truncated');            // a bad shutdown corrupted the primary
  const r = io.recoverStoreRaw();
  assert.equal(r.data.gen, 'yesterday', 'two months of work was thrown away for a stale temp');
  assert.equal(r.source, 'prev');
});

test('a genuine crash still prefers the temp that was trying to land', () => {
  // The other direction, and the one that must not regress: in a real crash the temp
  // holds the newest bytes and .prev inherits the mtime of the save before it.
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  const tenMinAgo = new Date(Date.now() - 600 * 1000);
  fs.writeFileSync(fp + '.prev', JSON.stringify({ gen: 'previous', printLog: [] }));
  fs.utimesSync(fp + '.prev', tenMinAgo, tenMinAgo);
  fs.writeFileSync(`${fp}.tmp.123.1`, JSON.stringify({ gen: 'interrupted', printLog: [] }));
  const r = io.recoverStoreRaw();
  assert.equal(r.data.gen, 'interrupted');
  assert.equal(r.source, 'tmp');
});

test('a stale orphan is skipped even when the fresher .prev is the only good copy', () => {
  // Same ranking, but the newest candidate is unreadable: it must fall THROUGH to the
  // next by age, not back to "any temp".
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  const july = new Date(Date.now() - 60 * 24 * 3600 * 1000);
  fs.writeFileSync(`${fp}.tmp.999.1`, JSON.stringify({ gen: 'july-orphan', printLog: [] }));
  fs.utimesSync(`${fp}.tmp.999.1`, july, july);
  fs.writeFileSync(`${fp}.tmp.999.2`, '{"printLog":[{"id":"O-1","note":"xxx');  // newest, truncated
  fs.writeFileSync(fp + '.prev', JSON.stringify({ gen: 'yesterday', printLog: [] }));
  const yday = new Date(Date.now() - 24 * 3600 * 1000);
  fs.utimesSync(fp + '.prev', yday, yday);
  const r = io.recoverStoreRaw();
  assert.equal(r.data.gen, 'yesterday', 'fell back to the oldest temp instead of the newer .prev');
});

test('a truncated temp is skipped in favour of a good .prev', () => {
  // A write killed mid-fwrite leaves unparseable JSON. Preferring it over an
  // intact backup would turn a recoverable crash into real data loss.
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  fs.writeFileSync(fp + '.prev', JSON.stringify({ gen: 'previous', printLog: [] }));
  fs.writeFileSync(`${fp}.tmp.5.1`, '{"printLog":[{"id":"O-1","note":"xxx');  // truncated
  const r = io.recoverStoreRaw();
  assert.equal(r.data.gen, 'previous', 'must fall through the unparseable temp to the backup');
  assert.equal(r.existed, true);
});

test('an empty temp does not mask a good .prev', () => {
  // fs.open(w) creates a zero-byte file before any bytes are written; a crash
  // in that instant leaves a 0-byte temp that must not be mistaken for data.
  // Note: two mechanisms enforce this (the st.size < 2 guard and the JSON parse
  // failing). Mutation-testing showed removing the size guard alone does not
  // fail this test — the parse path still catches it. Kept because the OUTCOME
  // is what matters and would regress if either path changed.
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  fs.writeFileSync(fp + '.prev', JSON.stringify({ gen: 'previous', printLog: [] }));
  fs.writeFileSync(`${fp}.tmp.5.1`, '');
  const r = io.recoverStoreRaw();
  assert.equal(r.data.gen, 'previous');
});

test('recoverStoreRaw reports a fresh install when nothing is on disk', () => {
  const io = makeStoreIo();
  const r = io.recoverStoreRaw();
  assert.equal(r.data, null);
  assert.equal(r.existed, false);
});

/* ── Data-integrity regressions ─────────────────────────────────────────────
 * Each of these reproduces a defect that could destroy a shop's data. */

test('CONCURRENT WRITES: overlapping saves must not destroy the store', async () => {
  // Every writer used one hardcoded temp path (fp + '.tmp') with no lock. Two overlapping
  // writes cross-wrote the same file; the loser's rename then moved the mixed garbage onto
  // .prev, leaving NO primary and a corrupt backup.
  const io = makeStoreIo();
  const big = { who: 'A', printLog: Array.from({ length: 8000 }, (_, i) => ({ id: 'O-' + i, note: 'x'.repeat(60) })) };
  const small = { who: 'B', printLog: [] };

  await Promise.all([
    io.writeStoreToDisk(big),
    io.writeStoreToDisk(small),
  ]);

  const rec = io.recoverStoreRaw();
  assert.ok(rec.data, 'store must still be readable after concurrent writes');
  assert.equal(rec.source, 'primary', 'primary must exist, not be recovered from a backup');
  assert.ok(['A', 'B'].includes(rec.data.who), 'must be one writer’s COMPLETE payload, not a blend');
  assert.equal(rec.existed, true);
});

test('CONCURRENT WRITES: every queued write completes in order, none silently vanish', async () => {
  const io = makeStoreIo();
  await Promise.all([1, 2, 3, 4, 5].map(n => io.writeStoreToDisk({ who: 'w' + n, printLog: [] })));
  const rec = io.recoverStoreRaw();
  // The last write to be queued wins; what matters is that the file is one intact payload.
  assert.equal(rec.data.who, 'w5', 'writes must land in arrival order');
});

test('temp files are uniquely named so writers cannot cross-write', async () => {
  const io = makeStoreIo();
  await io.writeStoreToDisk({ who: 'A', printLog: [] });
  const strays = fs.readdirSync(tmpDir).filter(f => f.includes('.tmp'));
  assert.deepEqual(strays, [], 'a completed write must leave no temp file behind');
});

test('a surviving backup is never mistaken for a fresh install', () => {
  // recoverStoreRaw reported existed:false when the primary was missing, even with a
  // .prev on disk. main.js turned that into null, and the renderer read null as a genuine
  // first run: setup wizard, empty store, and the next save overwrote the last good copy.
  const io = makeStoreIo();
  const fp = path.join(tmpDir, fs.readdirSync(tmpDir).find(f => f.endsWith('.json')) || 'khayt-store.json');
  fs.writeFileSync(fp, JSON.stringify({ who: 'GOOD', printLog: [{ id: 'O-1' }] }), 'utf8');
  fs.renameSync(fp, fp + '.prev');            // interrupted write: primary gone, .prev good
  assert.equal(fs.existsSync(fp), false);

  const rec = io.recoverStoreRaw();
  assert.equal(rec.existed, true, 'a shop with a backup on disk is NOT a fresh install');
  assert.equal(rec.source, 'prev');
  assert.equal(rec.data.who, 'GOOD');
});

test('SECRETS: a load→save round-trip never writes the mask over a real credential', () => {
  // The mask list and the restore list were hand-maintained and had drifted: five
  // credential groups — including the Khayt Cloud token, i.e. the off-site backup —
  // were masked on load and never restored, so one round-trip destroyed them.
  const io = makeStoreIo();
  const real = {
    settings: {
      emailConfig: { apiKey: 'EMAIL-REAL' },
      smsConfig: { authToken: 'TWILIO-REAL', token: 'WA-REAL', appSid: 'SID-REAL', secret: 'HOOK-REAL' },
      accountingSync: { secret: 'ACCT-REAL' },
      ai: { apiKey: 'sk-ant-REAL' },
      cloud: { token: 'CLOUD-REAL' },
      telegram: { botToken: 'TG-REAL' },
      lanApi: { pin: 'PIN-REAL' },
    },
  };
  return (async () => {
    await io.writeStoreToDisk(real);
    const masked = io.maskStoreSecretsForRenderer(io.readStoreDecryptedFromDisk());
    // The renderer hands the masked object straight back on the next save.
    const merged = io.mergeStoreSecretsFromDisk(masked);
    const s = merged.settings;
    for (const [path_, val] of [
      ['emailConfig.apiKey', s.emailConfig.apiKey],
      ['smsConfig.authToken', s.smsConfig.authToken],
      ['smsConfig.token', s.smsConfig.token],
      ['smsConfig.appSid', s.smsConfig.appSid],
      ['smsConfig.secret', s.smsConfig.secret],
      ['accountingSync.secret', s.accountingSync.secret],
      ['ai.apiKey', s.ai.apiKey],
      ['cloud.token', s.cloud.token],
      ['telegram.botToken', s.telegram.botToken],
      ['lanApi.pin', s.lanApi.pin],
    ]) {
      assert.notEqual(val, STORE_SECRET_MASK, `CREDENTIAL DESTROYED: ${path_}`);
      assert.ok(val && val.endsWith('REAL'), `${path_} should be the real value, got ${val}`);
    }
  })();
});

test('SECRETS: a genuine user edit still overwrites the stored credential', async () => {
  // The mask backstop must only ever replace a mask — never clobber a real change.
  const io = makeStoreIo();
  await io.writeStoreToDisk({ settings: { ai: { apiKey: 'OLD-KEY' }, cloud: { token: 'OLD-TOKEN' } } });
  const merged = io.mergeStoreSecretsFromDisk({
    settings: { ai: { apiKey: 'NEW-KEY' }, cloud: { token: STORE_SECRET_MASK } },
  });
  assert.equal(merged.settings.ai.apiKey, 'NEW-KEY', 'a real edit must win');
  assert.equal(merged.settings.cloud.token, 'OLD-TOKEN', 'an untouched (masked) field is restored');
});

/* ── hasPlaintextSecrets — gates the keychain explanation ──────────
   The store LOAD masks and never decrypts, so the one-time keychain dialog was
   blocking boot for an access that only happens on save (encrypt) / restore
   (decrypt). This predicate decides when the encrypt path will really reach the
   keychain. */

test('hasPlaintextSecrets is false when encryption is unavailable', () => {
  const io = makeStoreIo({ encryption: false });
  assert.equal(io.hasPlaintextSecrets({ settings: { emailConfig: { apiKey: 'sk-live' } } }), false);
});

test('hasPlaintextSecrets is false for an empty store or no secrets', () => {
  const io = makeStoreIo({ encryption: true });
  assert.equal(io.hasPlaintextSecrets(null), false);
  assert.equal(io.hasPlaintextSecrets({}), false);
  assert.equal(io.hasPlaintextSecrets({ settings: { shopName: 'X' }, machines: [{ id: 'M1' }] }), false);
});

test('hasPlaintextSecrets ignores already-encrypted and masked values', () => {
  const io = makeStoreIo({ encryption: true });
  assert.equal(io.hasPlaintextSecrets({ settings: { emailConfig: { apiKey: '__enc__abc' } } }), false);
  assert.equal(io.hasPlaintextSecrets({ settings: { emailConfig: { apiKey: STORE_SECRET_MASK } } }), false);
});

test('hasPlaintextSecrets detects a plaintext secret in each family', () => {
  const io = makeStoreIo({ encryption: true });
  const cases = [
    { settings: { emailConfig: { apiKey: 'x' } } },
    { settings: { emailConfig: { smtpPassword: 'x' } } },
    { settings: { smsConfig: { authToken: 'x' } } },
    { settings: { accountingSync: { secret: 'x' } } },
    { machines: [{ id: 'M', printerApi: { apiKey: 'x' } }] },
    { machines: [{ id: 'M', printerApi: { accessCode: 'x' } }] },
    { settings: { zatcaPhase2: { csid: 'x' } } },
    { settings: { bnpl: { tamara: { notificationToken: 'x' } } } },
    { settings: { telegram: { botToken: 'x' } } },
    { settings: { lanApi: { pin: 'x' } } },
    { settings: { webhooks: { secret: 'x' } } },
    { settings: { eventWebhooks: { secret: 'x' } } },
    { settings: { ai: { apiKey: 'x' } } },
    { settings: { cloud: { token: 'x' } } },
  ];
  for (const c of cases) {
    assert.equal(io.hasPlaintextSecrets(c), true, `should detect: ${JSON.stringify(c)}`);
  }
});

test('hasPlaintextSecrets stays in lockstep with encryptForDisk', () => {
  // The safety net for drift: whenever encryptForDisk would change the store
  // (i.e. actually reach the keychain), the predicate must have said so, and
  // vice-versa. If a secret field is added to one and not the other, this fails.
  const io = makeStoreIo({ encryption: true });
  const full = {
    settings: {
      emailConfig: { apiKey: 'a', smtpPassword: 'b' },
      smsConfig: { authToken: 'c', token: 'd', appSid: 'e', secret: 'f' },
      accountingSync: { secret: 'g' },
      zatcaPhase2: { csid: 'h', pcsid: 'i' },
      bnpl: { tabby: { apiKey: 'j' }, tamara: { apiKey: 'k', notificationToken: 'l' }, stripe: { apiKey: 'm' } },
      telegram: { botToken: 'n' },
      lanApi: { webhookToken: 'o', sallaWebhookSecret: 'p', zidWebhookSecret: 'q', pin: 'r', intakeToken: 's', intakePin: 't', calendarToken: 'u' },
      webhooks: { secret: 'v' }, eventWebhooks: { secret: 'w' },
      ai: { apiKey: 'x' }, cloud: { token: 'y' },
    },
    machines: [{ id: 'M', printerApi: { apiKey: 'z', accessCode: 'z2' } }],
  };
  const changed = (d) => JSON.stringify(io.encryptForDisk(d)) !== JSON.stringify(d);
  assert.equal(io.hasPlaintextSecrets(full), changed(full), 'full store: predicate must match encryptForDisk');
  const empty = { settings: { shopName: 'X' }, machines: [{ id: 'M1' }] };
  assert.equal(io.hasPlaintextSecrets(empty), changed(empty), 'empty store: predicate must match encryptForDisk');
});

/* ------------------------------------------------------------------
 * Two writers, one store.
 *
 * Every caller that changes one key read the in-memory store, changed it, and
 * wrote the whole thing back. The read and the enqueue sit in one synchronous
 * block, so nothing can interleave THERE — but `onStoreUpdated` only refreshes
 * the in-memory copy after the awaited write LANDS. A second caller arriving
 * while the first write is still in flight reads the store as it was before the
 * first change, and its write, queued behind, puts that state back.
 *
 * Two tablets on the shop floor inside one write cycle: the order tablet A had
 * just logged was gone from disk, after the server had answered 201.
 * ------------------------------------------------------------------ */

test('two writes in flight: the old read-modify-write loses one', async () => {
  // The bug, driven against the primitive it replaced, so the fix is measured
  // against something real rather than asserted.
  const io = makeStoreIo();
  let mem = { printLog: [], expenses: [] };
  await io.persistLanStoreUpdate(mem);
  mem = io.recoverStoreRaw().data;

  const a = { ...mem, printLog: [{ id: 'O-A' }, ...mem.printLog] };
  const pa = io.persistLanStoreUpdate(a);
  await new Promise((r) => setImmediate(r));      // B arrives while A is in flight
  const b = { ...mem, expenses: [{ id: 'E-B' }, ...mem.expenses] };
  await Promise.all([pa, io.persistLanStoreUpdate(b)]);

  const onDisk = io.recoverStoreRaw().data;
  assert.equal(onDisk.printLog.length, 0, 'setup: the old path is expected to lose A');
  assert.equal(onDisk.expenses.length, 1);
});

test('updateStoreOnDisk: two writes in flight both survive', async () => {
  const tmp2 = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-store-io-race-'));
  let mem = {};
  const io = createStoreIo({
    app: { getPath: () => tmp2 },
    fs,
    safeStorage: { isEncryptionAvailable: () => false },
    safeJsonParse,
    crypto,
    onStoreUpdated: (d) => { mem = d; },
    getStore: () => mem,
  });
  try {
    mem = { printLog: [], expenses: [] };
    await io.persistLanStoreUpdate(mem);

    const pa = io.updateStoreOnDisk((cur) => ({ ...cur, printLog: [{ id: 'O-A' }, ...(cur.printLog || [])] }));
    await new Promise((r) => setImmediate(r));
    const pb = io.updateStoreOnDisk((cur) => ({ ...cur, expenses: [{ id: 'E-B' }, ...(cur.expenses || [])] }));
    await Promise.all([pa, pb]);

    const onDisk = io.recoverStoreRaw().data;
    assert.deepEqual(onDisk.printLog, [{ id: 'O-A' }], 'the order was lost — the read is not inside the chain');
    assert.deepEqual(onDisk.expenses, [{ id: 'E-B' }]);
  } finally { fs.rmSync(tmp2, { recursive: true, force: true }); }
});

test('updateStoreOnDisk: many concurrent appends all land', async () => {
  const tmp2 = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-store-io-many-'));
  let mem = { printLog: [] };
  const io = createStoreIo({
    app: { getPath: () => tmp2 }, fs,
    safeStorage: { isEncryptionAvailable: () => false },
    safeJsonParse, crypto,
    onStoreUpdated: (d) => { mem = d; },
    getStore: () => mem,
  });
  try {
    await io.persistLanStoreUpdate(mem);
    await Promise.all(Array.from({ length: 25 }, (_, i) =>
      io.updateStoreOnDisk((cur) => ({ ...cur, printLog: [...(cur.printLog || []), { id: `O-${i}` }] }))));
    const ids = io.recoverStoreRaw().data.printLog.map((o) => o.id).sort();
    assert.equal(ids.length, 25, `${25 - ids.length} of 25 orders were lost`);
  } finally { fs.rmSync(tmp2, { recursive: true, force: true }); }
});

test('updateStoreOnDisk: a failing mutator does not poison the chain', async () => {
  const tmp2 = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-store-io-poison-'));
  let mem = { printLog: [] };
  const io = createStoreIo({
    app: { getPath: () => tmp2 }, fs,
    safeStorage: { isEncryptionAvailable: () => false },
    safeJsonParse, crypto,
    onStoreUpdated: (d) => { mem = d; },
    getStore: () => mem,
  });
  try {
    await io.persistLanStoreUpdate(mem);
    await assert.rejects(() => io.updateStoreOnDisk(() => { throw new Error('boom'); }));
    await io.updateStoreOnDisk((cur) => ({ ...cur, printLog: [{ id: 'after' }] }));
    assert.deepEqual(io.recoverStoreRaw().data.printLog, [{ id: 'after' }],
      'one bad write stopped every write after it');
  } finally { fs.rmSync(tmp2, { recursive: true, force: true }); }
});

test('updateStoreOnDisk: the mutator sees decrypted secrets, not ciphertext', async () => {
  // readStoreRawFromDisk returns the ENCRYPTED form. Falling back to it would
  // hand the mutator ciphertext and then re-encrypt it, double-wrapping every
  // secret in the store.
  const tmp2 = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-store-io-sec-'));
  const io = createStoreIo({
    app: { getPath: () => tmp2 }, fs,
    safeStorage: {
      isEncryptionAvailable: () => true,
      encryptString: (plain) => Buffer.from(`test:${plain}`, 'utf8'),
      decryptString: (buf) => { const v = buf.toString('utf8'); return v.startsWith('test:') ? v.slice(5) : ''; },
    },
    safeJsonParse, crypto,
    // No getStore: force the disk-read path, which is where the trap is.
  });
  try {
    await io.writeStoreToDisk({ settings: { lanApi: { pin: '4321' } }, printLog: [] });
    let sawPin = null;
    await io.updateStoreOnDisk((cur) => { sawPin = cur.settings.lanApi.pin; return { ...cur, printLog: [{ id: 'x' }] }; });
    assert.equal(sawPin, '4321', 'the mutator was handed ciphertext');
    assert.equal(io.readStoreDecryptedFromDisk().settings.lanApi.pin, '4321', 'the pin was double-encrypted');
  } finally { fs.rmSync(tmp2, { recursive: true, force: true }); }
});

/* ------------------------------------------------------------------
 * Keys the main process owns must survive a renderer save.
 *
 * normalizeStoreSnapshot is an allowlist of ARRAY_COLLECTIONS (+ settings,
 * version, exportedAt). `printerCompletions` is written by the printer poll
 * timer in the main process and is NOT in it, so:
 *
 *   1. the poll timer writes the completion history to disk;
 *   2. the renderer never receives it, because load normalises it away;
 *   3. hub:save-store normalises the renderer's snapshot and writes THAT,
 *      deleting the key from disk.
 *
 * Every renderer save is every edit, so the history never survived a session.
 * rehydrateCompletions found nothing at the next launch, and a finished job's
 * real filament weight and duration were gone.
 *
 * printer-poll-cache.test.js round-tripped completionsToPersist →
 * restoreCompletions perfectly the whole time. The module was right; nothing
 * kept its output. Same shape as #578.
 * ------------------------------------------------------------------ */

/** The save path as hub:save-store runs it: normalise, merge from disk, write. */
async function rendererSave(io, snapshot) {
  const { normalizeStoreSnapshot } = require('../lib/store-validate.js');
  const { normalized } = normalizeStoreSnapshot(snapshot);
  await io.writeStoreToDisk(io.mergeStoreSecretsFromDisk(normalized));
}

test('a renderer save does not delete the printer completion history', async () => {
  const io = makeStoreIo();
  await io.writeStoreToDisk({
    printLog: [], settings: {},
    printerCompletions: { 'PRN-1': { completions: [{ at: 1, filename: 'bracket.gcode', actuals: { filamentGrams: 222 } }] } },
  });
  // The renderer's snapshot has never contained this key — it cannot send it back.
  await rendererSave(io, { printLog: [], settings: {}, version: 10 });

  const disk = io.recoverStoreRaw().data;
  assert.ok(disk.printerCompletions, 'the completion history was deleted by an ordinary save');
  assert.equal(disk.printerCompletions['PRN-1'].completions[0].actuals.filamentGrams, 222);
});

test('the renderer still wins when it does send one of those keys', async () => {
  const io = makeStoreIo();
  await io.writeStoreToDisk({ printLog: [], settings: {}, printerCompletions: { old: 1 } });
  await io.writeStoreToDisk(io.mergeStoreSecretsFromDisk({ printLog: [], settings: {}, printerCompletions: { fresh: 1 } }));
  assert.deepEqual(io.recoverStoreRaw().data.printerCompletions, { fresh: 1 },
    'a value the caller supplied was overwritten by the one on disk');
});

test('every main-owned key is one normalize would otherwise drop', () => {
  // If a key ever joins ARRAY_COLLECTIONS, it stops needing this rescue, and
  // leaving it here would pin a stale disk copy over the renderer's.
  const { MAIN_OWNED_KEYS } = require('../lib/store-io.js');
  const { ARRAY_COLLECTIONS } = require('../lib/store-validate.js');
  assert.ok(MAIN_OWNED_KEYS.length > 0);
  for (const k of MAIN_OWNED_KEYS) {
    assert.ok(!ARRAY_COLLECTIONS.includes(k), `${k} is a normal collection now — take it off MAIN_OWNED_KEYS`);
    assert.ok(!['settings', 'version', 'exportedAt'].includes(k), `${k} already survives normalize`);
  }
});

test('the key main.js writes is the key that is rescued', () => {
  // The bug is re-introduced by adding a second store key in main.js and not
  // listing it. Read the constant out of the source and require it to be listed.
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const { MAIN_OWNED_KEYS } = require('../lib/store-io.js');
  const m = src.match(/const COMPLETIONS_KEY = '([^']+)'/);
  assert.ok(m, 'COMPLETIONS_KEY is gone from main.js');
  assert.ok(MAIN_OWNED_KEYS.includes(m[1]),
    `main.js persists "${m[1]}" but MAIN_OWNED_KEYS does not rescue it — every save will delete it`);
});

test('the book and its .prev are owner-only (0600) after a save', { skip: process.platform === 'win32' }, async () => {
  const io = makeStoreIo();
  const fp = io.dataFilePath();
  fs.mkdirSync(path.dirname(fp), { recursive: true });
  // A book written by an older Khayt, readable by everyone on the computer.
  fs.writeFileSync(fp, JSON.stringify({ printLog: [] }), { mode: 0o644 });
  fs.chmodSync(fp, 0o644);
  await io.atomicWriteStore(JSON.stringify({ printLog: [{ id: 'O-1' }] }));
  const mode = (f) => fs.statSync(f).mode & 0o777;
  assert.equal(mode(fp), 0o600, 'the book');
  assert.equal(mode(fp + '.prev'), 0o600, 'the older book, now one save back');
  await io.atomicWriteStore(JSON.stringify({ printLog: [] }));
  assert.equal(mode(fp), 0o600);
  assert.equal(mode(fp + '.prev'), 0o600);
});
