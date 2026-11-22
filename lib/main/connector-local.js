'use strict';
/**
 * This computer's own slicer settings, kept in userData and never in the
 * book (the Mac keeps the same in UserDefaults and its login Keychain):
 *
 *   connectorPrices      "Show prices in OrcaSlicer" (the Mac's
 *                        `connectorPrices`), default OFF. Even on, a plugin
 *                        sees nothing until the shop grants that device a
 *                        price (lib/lan-devices.js setPriceGrant).
 *   slicerUploadAccept   "Accept files from slicers (OctoPrint upload)" (the
 *                        Mac's `mac.slicerUploadAccept`), default OFF. Off,
 *                        GET /api/version and POST /api/files/local are 404.
 *   the OctoPrint key    32 upper-case hex characters (the Mac's SlicerKey),
 *                        minted on first use, sealed with the OS keychain
 *                        (safeStorage) where there is one. Not in the book, so
 *                        it never travels in a backup or to a phone.
 *
 * A file that cannot be read is read as all OFF: nothing here may switch a
 * door open by failing.
 *
 * Main process only (node:fs, node:crypto).
 */
const crypto = require('crypto');

const SEALED_MAGIC = 'khayt-sealed:';
const KEY_RE = /^[0-9A-F]{32}$/;

/** OctoPrint's own shape: 32 upper-case hex characters, 128 random bits. */
const mintKey = () => crypto.randomBytes(16).toString('hex').toUpperCase();

/**
 * @param {object} o
 * @param {object} o.fs
 * @param {string} o.settingsPath   JSON {connectorPrices, slicerUploadAccept}
 * @param {string} o.keyPath        the OctoPrint key
 * @param {function} [o.seal]       string -> Buffer|null
 * @param {function} [o.unseal]     Buffer -> string
 */
function createConnectorLocal({ fs, settingsPath, keyPath, seal = null, unseal = null }) {
  let cachedKey = null;

  function read() {
    try {
      const j = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
      return j && typeof j === 'object' && !Array.isArray(j) ? j : {};
    } catch (_) { return {}; }
  }
  function write(next) {
    const tmp = settingsPath + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(next), { mode: 0o600 });
    fs.renameSync(tmp, settingsPath);
  }
  const flag = (name) => read()[name] === true;
  function setFlag(name, on) { const cur = read(); cur[name] = on === true; write(cur); return cur[name]; }

  function storeKey(key) {
    const sealed = seal ? seal(key) : null;
    const body = sealed ? SEALED_MAGIC + sealed.toString('base64') : key;
    fs.writeFileSync(keyPath + '.tmp', body, { mode: 0o600 });
    fs.renameSync(keyPath + '.tmp', keyPath);
    cachedKey = key;
    return key;
  }
  /** The key, made the first time it is asked for; null when it cannot be read or kept. */
  function currentKey() {
    if (cachedKey) return cachedKey;
    let raw = null;
    try { raw = fs.readFileSync(keyPath, 'utf8'); } catch (e) { if (!e || e.code !== 'ENOENT') return null; }
    if (raw != null) {
      let k = null;
      try { k = raw.startsWith(SEALED_MAGIC) ? (unseal ? unseal(Buffer.from(raw.slice(SEALED_MAGIC.length), 'base64')) : null) : raw; }
      catch (_) { k = null; }
      // Sealed and the keychain cannot open it now: not replaced, refused.
      if (!k) return null;
      k = String(k).trim();
      if (KEY_RE.test(k)) { cachedKey = k; return k; }
    }
    try { return storeKey(mintKey()); } catch (_) { return null; }
  }

  return {
    pricesOn: () => flag('connectorPrices'),
    setPrices: (on) => setFlag('connectorPrices', on),
    acceptingUploads: () => flag('slicerUploadAccept'),
    setAcceptingUploads: (on) => setFlag('slicerUploadAccept', on),
    currentKey,
    /** The key the server checks: only while uploads are switched on. */
    activeKey: () => (flag('slicerUploadAccept') ? currentKey() : null),
    regenerateKey: () => { try { return storeKey(mintKey()); } catch (_) { return null; } },
  };
}

module.exports = { createConnectorLocal, mintKey, KEY_RE };
