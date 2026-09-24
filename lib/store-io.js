'use strict';

const path = require('path');
// The one list of which store fields hold credentials. See the module header
// for why it is not written out by hand here any more.
const { SECRET_PATHS, forEachSecret } = require('./store-secret-paths.js');

// The largest store we will read or write, in bytes. Every safety net — the daily
// backup, the iCloud copy, a restore point, the pre-update snapshot — must accept a
// store at least this big, or it quietly stops covering the people with the most to
// lose. Shared so the two numbers cannot drift apart again.
const MAX_STORE_BYTES = 50_000_000;

/**
 * Top-level store keys the MAIN process owns.
 *
 * These are written by main (the printer poll timer) and are NEVER present in
 * a renderer snapshot — the renderer has never seen them, because
 * normalizeStoreSnapshot is an allowlist of ARRAY_COLLECTIONS and strips them
 * on load. So `hub:save-store` normalised the renderer's snapshot, wrote it,
 * and DELETED the key from disk. Every renderer save — which is every edit —
 * destroyed the printer completion history the poll timer had just persisted,
 * so `rehydrateCompletions` found nothing at the next launch and a job's real
 * filament weight and duration were gone.
 *
 * The unit tests round-tripped completionsToPersist → restoreCompletions
 * perfectly the whole time. The module was right; nothing kept its output.
 *
 * Re-attached from disk on save, for the same reason and by the same route as
 * the masked secrets below: the renderer cannot send back what it never had.
 */
const MAIN_OWNED_KEYS = ['printerCompletions'];

const STORE_SECRET_MASK = '__KHAYT_MASKED__';

/**
 * Store encrypt/decrypt, disk read/write, secret merge/mask for hub + LAN.
 * @param {{ app: import('electron').App, fs: typeof import('fs'), safeStorage: import('electron').SafeStorage, safeJsonParse: Function, crypto: typeof import('crypto'), onStoreUpdated?: (data: object) => void }} deps
 */
function createStoreIo({ app, fs, safeStorage, safeJsonParse, crypto, onStoreUpdated, getStore }) {
  function dataFilePath() {
    return path.join(app.getPath('userData'), 'khayt-store.json');
  }

  function encryptStoreField(val) {
    if (!val || typeof val !== 'string' || !safeStorage.isEncryptionAvailable()) return val;
    if (val.startsWith('__enc__') || val === STORE_SECRET_MASK) return val;
    return '__enc__' + safeStorage.encryptString(val).toString('base64');
  }

  function decryptStoreField(val) {
    if (!val || typeof val !== 'string' || !val.startsWith('__enc__')) return val;
    if (!safeStorage.isEncryptionAvailable()) return val;
    try { return safeStorage.decryptString(Buffer.from(val.slice(7), 'base64')); }
    catch { return val; }
  }

  function encryptForDisk(data) {
    const d = JSON.parse(JSON.stringify(data));
    forEachSecret(d, (value, set) => set(encryptStoreField(value)));
    return d;
  }
  /**
   * Would encryptForDisk actually reach the OS keychain for this store? True iff
   * some secret field holds a plaintext value it would encrypt — the same
   * condition encryptStoreField uses (truthy string, not already `__enc__`, not
   * the mask). Mirrors encryptForDisk's field list.
   *
   * Used to decide when to show the one-time keychain explanation: it must
   * precede the first REAL keychain touch, and the store LOAD never decrypts, so
   * the old "explain before load" gate blocked boot for an access that happens
   * on save/restore instead.
   *
   * Drift is bounded on purpose: if a secret field is added to encryptForDisk
   * but not here, the only effect is the explanation may not pre-empt that one
   * field's first encrypt — never a leak or a crash, since encryptForDisk is the
   * untouched source of truth for what actually gets encrypted. store-io.test.js
   * pins the two together.
   */
  function hasPlaintextSecrets(data) {
    if (!data || !safeStorage.isEncryptionAvailable()) return false;
    let found = false;
    forEachSecret(data, (value) => {
      if (found || typeof value !== 'string') return;
      if (!value.startsWith('__enc__') && value !== STORE_SECRET_MASK) found = true;
    });
    return found;
  }
  function isStoreSecretMasked(val) {
    return val === STORE_SECRET_MASK;
  }

  function decryptStoreSecrets(data) {
    if (!data) return data;
    // In place, unlike encryptForDisk: callers pass a copy they own and expect
    // the same object back.
    forEachSecret(data, (value, set) => set(decryptStoreField(value)));
    return data;
  }
  function maskStoreSecretsForRenderer(data) {
    if (!data) return data;
    // Same list as encryptForDisk, and that is the point: a secret the renderer
    // is handed in the clear is a secret in a devtools console, a screenshot and
    // a bug report. Being on one list and not the other was the bug.
    forEachSecret(data, (value, set) => set(STORE_SECRET_MASK));
    return data;
  }
  function readStoreRawFromDisk() {
    const fp = dataFilePath();
    if (!fs.existsSync(fp)) return null;
    try {
      const stat = fs.statSync(fp);
      if (stat.size > MAX_STORE_BYTES) return null;
      return safeJsonParse(fs.readFileSync(fp, 'utf8'));
    } catch { return null; }
  }

  function readStoreDecryptedFromDisk() {
    const raw = readStoreRawFromDisk();
    if (!raw) return null;
    return decryptStoreSecrets(JSON.parse(JSON.stringify(raw)));
  }


  function mergeStoreSecretsFromDisk(incoming) {
    const out = JSON.parse(JSON.stringify(incoming || {}));
    const disk = readStoreDecryptedFromDisk();
    if (!disk) return out;
    for (const key of MAIN_OWNED_KEYS) {
      if (out[key] === undefined && disk[key] !== undefined) out[key] = disk[key];
    }
    const pick = (getIn, setOut, getDisk) => {
      const inVal = getIn(out);
      if (!isStoreSecretMasked(inVal) && inVal) return;
      const diskVal = getDisk(disk);
      if (diskVal) setOut(out, diskVal);
    };
    pick(
      d => d?.settings?.printLibrary?.s3?.secretAccessKey,
      (d, v) => {
        if (!d.settings) d.settings = {};
        if (!d.settings.printLibrary) d.settings.printLibrary = {};
        if (!d.settings.printLibrary.s3) d.settings.printLibrary.s3 = {};
        d.settings.printLibrary.s3.secretAccessKey = v;
      },
      d => d?.settings?.printLibrary?.s3?.secretAccessKey,
    );
    // Same reason as the bucket secret above: the renderer only ever holds a
    // mask, so without this, saving any unrelated setting writes the mask over
    // the real token and silently disconnects the shop's Drive.
    for (const key of ['refreshToken', 'clientSecret']) {
      pick(
        d => d?.settings?.printLibrary?.gdrive?.[key],
        (d, v) => {
          if (!d.settings) d.settings = {};
          if (!d.settings.printLibrary) d.settings.printLibrary = {};
          if (!d.settings.printLibrary.gdrive) d.settings.printLibrary.gdrive = {};
          d.settings.printLibrary.gdrive[key] = v;
        },
        d => d?.settings?.printLibrary?.gdrive?.[key],
      );
    }
    pick(
      d => d?.settings?.emailConfig?.apiKey,
      (d, v) => { if (!d.settings) d.settings = {}; if (!d.settings.emailConfig) d.settings.emailConfig = {}; d.settings.emailConfig.apiKey = v; },
      d => d?.settings?.emailConfig?.apiKey
    );
    pick(
      d => d?.settings?.emailConfig?.smtpPassword,
      (d, v) => { if (!d.settings) d.settings = {}; if (!d.settings.emailConfig) d.settings.emailConfig = {}; d.settings.emailConfig.smtpPassword = v; },
      d => d?.settings?.emailConfig?.smtpPassword
    );
    if (Array.isArray(out.machines)) {
      const diskById = new Map(
        (disk.machines || []).filter((m) => m && m.id).map((m) => [m.id, m]),
      );
      // Every machine credential: the printer's key and access code, and the
      // smart plug's token and password. A masked value coming back from the
      // renderer is put back from disk; forgetting one here means saving ANY
      // setting writes the mask over it and destroys it.
      const MACHINE_SECRETS = [
        ['printerApi', 'apiKey'], ['printerApi', 'accessCode'],
        ['smartPlug', 'token'], ['smartPlug', 'password'],
      ];
      out.machines = out.machines.map((m) => {
        if (!MACHINE_SECRETS.some(([g, f]) => isStoreSecretMasked(m?.[g]?.[f]))) return m;
        const diskM = m?.id ? diskById.get(m.id) : null;
        let next = m;
        for (const [group, field] of MACHINE_SECRETS) {
          const stored = diskM?.[group]?.[field];
          if (isStoreSecretMasked(next?.[group]?.[field]) && stored) {
            next = { ...next, [group]: { ...(next[group] || {}), [field]: stored } };
          }
        }
        return next;
      });
    }
    pick(
      d => d?.settings?.zatcaPhase2?.csid,
      (d, v) => { if (!d.settings) d.settings = {}; if (!d.settings.zatcaPhase2) d.settings.zatcaPhase2 = {}; d.settings.zatcaPhase2.csid = v; },
      d => d?.settings?.zatcaPhase2?.csid
    );
    pick(
      d => d?.settings?.zatcaPhase2?.pcsid,
      (d, v) => { if (!d.settings) d.settings = {}; if (!d.settings.zatcaPhase2) d.settings.zatcaPhase2 = {}; d.settings.zatcaPhase2.pcsid = v; },
      d => d?.settings?.zatcaPhase2?.pcsid
    );
    const mergeBnpl = (provider, key) => pick(
      d => d?.settings?.bnpl?.[provider]?.[key],
      (d, v) => { if (!d.settings) d.settings = {}; if (!d.settings.bnpl) d.settings.bnpl = {}; if (!d.settings.bnpl[provider]) d.settings.bnpl[provider] = {}; d.settings.bnpl[provider][key] = v; },
      d => d?.settings?.bnpl?.[provider]?.[key]
    );
    mergeBnpl('tabby', 'apiKey');
    mergeBnpl('tamara', 'apiKey');
    mergeBnpl('tamara', 'notificationToken');
    mergeBnpl('stripe', 'apiKey');
    pick(
      d => d?.settings?.telegram?.botToken,
      (d, v) => { if (!d.settings) d.settings = {}; if (!d.settings.telegram) d.settings.telegram = {}; d.settings.telegram.botToken = v; },
      d => d?.settings?.telegram?.botToken
    );
    pick(
      d => d?.settings?.webhooks?.secret,
      (d, v) => { if (!d.settings) d.settings = {}; if (!d.settings.webhooks) d.settings.webhooks = {}; d.settings.webhooks.secret = v; },
      d => d?.settings?.webhooks?.secret
    );
    ['webhookToken', 'sallaWebhookSecret', 'zidWebhookSecret', 'pin', 'intakeToken', 'intakePin', 'calendarToken'].forEach(field => {
      pick(
        d => d?.settings?.lanApi?.[field],
        (d, v) => { if (!d.settings) d.settings = {}; if (!d.settings.lanApi) d.settings.lanApi = {}; d.settings.lanApi[field] = v; },
        d => d?.settings?.lanApi?.[field]
      );
    });

    // BACKSTOP — the list above is hand-maintained and had drifted out of sync with the
    // mask list, so smsConfig.{authToken,token,appSid,secret}, accountingSync.secret,
    // ai.apiKey and cloud.token were masked on load and never restored on save: one
    // load→save round-trip wrote the literal mask to disk and destroyed the credential
    // irrecoverably. That silently broke SMS, accounting sync, AI assist and — worst —
    // the Khayt Cloud token, i.e. the owner's off-site backup.
    //
    // Rather than adding four more entries that can drift again, walk the settings tree:
    // ANY value still equal to the mask is restored from its counterpart on disk. New
    // secret fields are covered automatically.
    restoreMaskedFromDisk(out.settings, disk && disk.settings);
    return out;
  }

  /**
   * Recursively replace every masked value in `target` with the value at the same path in
   * `source`. Only ever copies over a mask, so real user edits are never clobbered.
   */
  function restoreMaskedFromDisk(target, source, depth) {
    const d = depth || 0;
    if (d > 8 || !target || !source || typeof target !== 'object' || typeof source !== 'object') return;
    for (const key of Object.keys(target)) {
      const tv = target[key];
      const sv = source[key];
      if (isStoreSecretMasked(tv)) {
        if (typeof sv === 'string' && sv && !isStoreSecretMasked(sv)) target[key] = sv;
      } else if (tv && typeof tv === 'object' && !Array.isArray(tv)) {
        restoreMaskedFromDisk(tv, sv, d + 1);
      }
    }
  }

  /**
   * Atomic, durable store write. Writes a temp file and fsyncs it before swapping, so a
   * crash/power-loss can't leave a half-written store, then rolls the current good file to
   * `.prev` (a cheap rename, not a copy) so there's always a one-generation rollback. The
   * `.prev` backup is best-effort; the write itself always completes.
   */
  // Serializes ALL store writes. The renderer had its own save chain, but nothing
  // serialized renderer-vs-LAN or LAN-vs-LAN, and the 15 LAN HTTP handlers write
  // unserialized. Two overlapping writes shared one hardcoded temp path, so writer B
  // opened the same file at position 0 while A was still streaming into it; B renamed it
  // into place, then A — still holding a live fd on the file now living at the primary
  // path — kept writing, and A's own rename moved that mixed garbage onto .prev. Result:
  // primary gone, .prev corrupt, and recoverStoreRaw reporting "no store" — which the app
  // reads as a FRESH INSTALL and greets the owner with the setup wizard.
  let _writeChain = Promise.resolve();
  let _tmpCounter = 0;

  async function atomicWriteStore(serialized) {
    // Chain before awaiting so concurrent callers queue in arrival order rather than
    // racing. Errors are contained so one failed write can't poison the chain.
    const run = _writeChain.then(() => atomicWriteStoreUnsafe(serialized));
    _writeChain = run.catch(() => {});
    return run;
  }

  /**
   * Read-modify-write the whole store, atomically with respect to every other write.
   *
   * Every caller that changes one key of the store used to do this by hand:
   *
   *     const next = { ...STORE() };      // read the in-memory copy
   *     next.printLog = [order, ...];     // change one key
   *     await persistLanStoreUpdate(next);
   *
   * The read and the enqueue sit in one synchronous block, so no interleaving is
   * possible there — but `onStoreUpdated` only refreshes the in-memory copy AFTER
   * the awaited write lands. A second caller arriving while the first write is
   * still in flight reads the store as it was BEFORE the first change, and its
   * write — queued behind, so it lands last — puts that state back.
   *
   * Two tablets on the shop floor inside one write cycle: the order tablet A had
   * just logged was gone from disk, after the server had already answered 201.
   * Reproduced before this existed.
   *
   * Taking the read INSIDE the chain closes it. By the time the mutator runs,
   * every earlier write has completed and published its result, so it always sees
   * the newest store. `mutate` receives the current store and returns the next
   * one; it must not be async, so the read and the write cannot be pulled apart
   * again by a future edit.
   */
  async function updateStoreOnDisk(mutate) {
    if (typeof mutate !== 'function') throw new TypeError('updateStoreOnDisk needs a mutator');
    const run = _writeChain.then(async () => {
      // readStoreDecryptedFromDisk, never readStoreRawFromDisk: the raw form is
      // already encrypted, and re-encrypting it would double-wrap every secret.
      const current = (typeof getStore === 'function' ? getStore() : null) || readStoreDecryptedFromDisk() || {};
      const next = mutate(current);
      if (!next || typeof next !== 'object') throw new Error('mutator returned no store');
      const serialized = JSON.stringify(encryptForDisk(next));
      if (serialized.length > MAX_STORE_BYTES) throw new Error('Store too large');
      await atomicWriteStoreUnsafe(serialized);
      if (onStoreUpdated) onStoreUpdated(next);
      return next;
    });
    _writeChain = run.then(() => {}, () => {});
    return run;
  }

  async function atomicWriteStoreUnsafe(serialized) {
    const fp = dataFilePath();
    // Unique per write: even if a temp file is orphaned by a crash, no other writer can
    // ever be handed the same path to cross-write.
    const tmp = `${fp}.tmp.${process.pid}.${++_tmpCounter}`;
    const fh = await fs.promises.open(tmp, 'w');
    try { await fh.writeFile(serialized, 'utf8'); await fh.sync(); }
    finally { await fh.close(); }
    try { if (fs.existsSync(fp)) await fs.promises.rename(fp, fp + '.prev'); } catch (_) { /* rollback copy is best-effort */ }
    try {
      await fs.promises.rename(tmp, fp);
    } catch (e) {
      // Never leave a stray temp behind if the swap fails.
      try { await fs.promises.unlink(tmp); } catch (_) { /* already gone */ }
      throw e;
    }
  }

  /**
   * Read the best available on-disk store, recovering transparently from a crash:
   *  - primary `khayt-store.json` if it parses;
   *  - else quarantine an unreadable primary (renamed to `.corrupt-<ts>.json`, never
   *    overwritten, so it can be recovered by hand) and fall back to the NEWEST of a
   *    completed-but-unswapped `.tmp` (crash between the two renames) and the previous
   *    generation `.prev`.
   *
   * Ranking by mtime is the whole point. A write killed between `writeFile` and the
   * swap orphans its temp file permanently — nothing has ever cleaned one up — and
   * every later save renames a DIFFERENT temp into place, so the orphan just sits
   * there. Preferring any `.tmp` over `.prev` meant one interrupted write in July
   * outranked yesterday's good save in September, and the shop was handed back a
   * two-month-old store under the words "Recovered your data".
   *
   * Both real cases fall out of the ordering. In a genuine crash the temp holds the
   * newest bytes and `.prev` inherits the mtime of the save before it, so the temp
   * wins. Against a stale orphan `.prev` is newer, so it wins.
   *
   * Restores the chosen fallback to the primary path so the app continues normally.
   * @returns {{ data, source: 'primary'|'tmp'|'prev'|null, existed, quarantined, writtenAt: number|null }}
   *   `writtenAt` is the mtime of the copy that was used, so the app can tell the shop
   *   how old the thing it just handed back actually is.
   */
  function recoverStoreRaw(maxBytes = MAX_STORE_BYTES) {
    const fp = dataFilePath();
    const prev = fp + '.prev';
    /** 0 for anything unreadable, so it sorts last rather than throwing. */
    const mtimeOf = (p) => { try { return fs.statSync(p).mtimeMs; } catch (_) { return 0; } };
    // Temp files are now uniquely named (fp.tmp.<pid>.<n>); the bare fp.tmp is still
    // checked so a store left behind by an older build is still recoverable. Newest
    // first — the most recent interrupted write is the closest to the owner's work.
    const tmpCandidates = (() => {
      const out = [];
      try {
        const dir = path.dirname(fp);
        const base = path.basename(fp);
        for (const name of fs.readdirSync(dir)) {
          if (name === base + '.tmp' || name.startsWith(base + '.tmp.')) {
            const full = path.join(dir, name);
            out.push({ full, mtime: mtimeOf(full) });
          }
        }
      } catch (_) { /* unreadable dir → no candidates */ }
      return out.sort((a, b) => b.mtime - a.mtime).map(x => x.full);
    })();
    const tryRead = (p) => {
      try {
        if (!fs.existsSync(p)) return null;
        const st = fs.statSync(p);
        if (st.size < 2 || st.size > maxBytes) return null;
        const parsed = safeJsonParse(fs.readFileSync(p, 'utf8'));
        return (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) ? parsed : null;
      } catch (_) { return null; }
    };
    // A store "existed" if ANY generation is on disk — not just the primary. If an
    // interrupted write left the primary missing while .prev/.tmp survive, reporting
    // existed:false makes the app treat a working shop as a fresh install: setup wizard,
    // empty store, and the next save overwrites the very backup that still held the data.
    const primaryExists = fs.existsSync(fp);
    const existed = primaryExists || fs.existsSync(prev) || tmpCandidates.length > 0;
    const primary = tryRead(fp);
    if (primary) return { data: primary, source: 'primary', existed: true, quarantined: null, writtenAt: mtimeOf(fp) };
    let quarantined = null;
    if (primaryExists) {
      try { quarantined = fp.replace(/\.json$/i, '') + '.corrupt-' + Date.now() + '.json'; fs.renameSync(fp, quarantined); }
      catch (_) { quarantined = null; }
    }
    // Newest first across BOTH kinds. Ties go to the temp: it is the write that was
    // trying to land, so it is at least as new as the generation it was replacing.
    const fallbacks = tmpCandidates.map((full) => ({ full, source: 'tmp', mtime: mtimeOf(full) }));
    if (fs.existsSync(prev)) fallbacks.push({ full: prev, source: 'prev', mtime: mtimeOf(prev) });
    fallbacks.sort((a, b) => (b.mtime - a.mtime) || (a.source === 'tmp' ? -1 : 1));

    for (const cand of fallbacks) {
      const data = tryRead(cand.full);
      if (!data) continue;
      try { fs.copyFileSync(cand.full, fp); } catch (_) { /* best effort */ }
      return { data, source: cand.source, existed, quarantined, writtenAt: cand.mtime || null };
    }
    return { data: null, source: null, existed, quarantined, writtenAt: null };
  }

  async function writeStoreToDisk(data) {
    const serialized = JSON.stringify(encryptForDisk(data));
    if (serialized.length > MAX_STORE_BYTES) throw new Error('Store too large');
    await atomicWriteStore(serialized);
    if (onStoreUpdated) onStoreUpdated(data);
  }

  function syncLanServerStoreFromDisk() {
    const disk = readStoreDecryptedFromDisk();
    if (disk && onStoreUpdated) onStoreUpdated(disk);
  }

  function migrateLanApiSecrets(store) {
    if (!store?.settings) return;
    if (!store.settings.lanApi) store.settings.lanApi = {};
    const la = store.settings.lanApi;
    if (store.settings.sallaWebhookSecret && !la.sallaWebhookSecret) {
      la.sallaWebhookSecret = store.settings.sallaWebhookSecret;
    }
    if (store.settings.zidWebhookSecret && !la.zidWebhookSecret) {
      la.zidWebhookSecret = store.settings.zidWebhookSecret;
    }
  }

  function ensureLanIntakeToken(store) {
    if (!store.settings) store.settings = {};
    if (!store.settings.lanApi) store.settings.lanApi = {};
    const existing = store.settings.lanApi.intakeToken;
    if (existing && !isStoreSecretMasked(existing)) return { token: existing, generated: false };
    const token = crypto.randomBytes(16).toString('hex');
    store.settings.lanApi.intakeToken = token;
    return { token, generated: true };
  }

  function ensureLanIntakePin(store) {
    if (!store.settings) store.settings = {};
    if (!store.settings.lanApi) store.settings.lanApi = {};
    const existing = store.settings.lanApi.intakePin;
    if (existing && !isStoreSecretMasked(existing)) return { pin: existing, generated: false };
    const pin = String(crypto.randomInt(100000, 1000000));
    store.settings.lanApi.intakePin = pin;
    return { pin, generated: true };
  }

  function ensureLanCalendarToken(store) {
    if (!store.settings) store.settings = {};
    if (!store.settings.lanApi) store.settings.lanApi = {};
    const existing = store.settings.lanApi.calendarToken;
    if (existing && !isStoreSecretMasked(existing)) return { token: existing, generated: false };
    const token = crypto.randomBytes(16).toString('hex');
    store.settings.lanApi.calendarToken = token;
    return { token, generated: true };
  }

  function isEncryptionAvailable() {
    return !!safeStorage.isEncryptionAvailable();
  }

  async function persistLanStoreUpdate(storeData) {
    const serialized = JSON.stringify(encryptForDisk(storeData));
    if (serialized.length > MAX_STORE_BYTES) throw new Error('Store too large');
    await atomicWriteStore(serialized);
    if (onStoreUpdated) onStoreUpdated(storeData);
  }

  function resolveStoreSecret(incoming, getter) {
    if (incoming && !isStoreSecretMasked(incoming)) return incoming;
    const disk = readStoreDecryptedFromDisk();
    return disk ? getter(disk) || '' : '';
  }

  return {
    STORE_SECRET_MASK,
    dataFilePath,
    encryptStoreField,
    decryptStoreField,
    encryptForDisk,
    SECRET_PATHS,
    hasPlaintextSecrets,
    isStoreSecretMasked,
    decryptStoreSecrets,
    maskStoreSecretsForRenderer,
    readStoreRawFromDisk,
    readStoreDecryptedFromDisk,
    mergeStoreSecretsFromDisk,
    writeStoreToDisk,
    atomicWriteStore,
    recoverStoreRaw,
    syncLanServerStoreFromDisk,
    migrateLanApiSecrets,
    ensureLanIntakeToken,
    ensureLanIntakePin,
    ensureLanCalendarToken,
    isEncryptionAvailable,
    persistLanStoreUpdate,
    updateStoreOnDisk,
    resolveStoreSecret,
  };
}

module.exports = { createStoreIo, STORE_SECRET_MASK, MAX_STORE_BYTES, MAIN_OWNED_KEYS };
