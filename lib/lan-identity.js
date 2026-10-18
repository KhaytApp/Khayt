'use strict';
/**
 * The LAN server's identity: an Ed25519 key that lets a paired iPhone tell this
 * computer from a device that copied its Bonjour name, BEFORE it sends the PIN.
 *
 * The phone learns the public key once, over the PIN-gated GET /api/identity.
 * Later, before trusting a server that answers to the same name, it sends a
 * fresh nonce to the open GET /api/proof and checks the signature against the
 * key it kept. An impostor has the name but not the private key.
 *
 * The same two routes as the Mac's (#1942), byte for byte: the signed message
 * is the ASCII bytes of 'khayt-proof:' + the nonce in lower case, and the
 * public key is the raw 32 bytes, base64. What it must NEVER be is an HMAC
 * keyed by the PIN: on an open route that hands anyone a value to brute-force
 * the PIN against offline.
 *
 * The private key is made once per computer and kept in userData, sealed with
 * the OS keychain (safeStorage) where there is one. It is machine-local on
 * purpose — it is not in the book, so a backup restored elsewhere or a second
 * computer on the same cloud does not claim to be this one.
 *
 * Main process only (node:crypto).
 */
const crypto = require('crypto');

const PROOF_PREFIX = 'khayt-proof:';
const NONCE_RE = /^[0-9a-fA-F]{32,128}$/;
const SEALED_MAGIC = 'khayt-sealed:';

function createLanIdentity({ fs, keyPath, seal = null, unseal = null }) {
  let privateKey = null;
  let publicRaw = null;

  function load() {
    if (privateKey) return;
    let raw = null;
    try { raw = fs.readFileSync(keyPath, 'utf8'); }
    catch (e) { if (!e || e.code !== 'ENOENT') throw e; }
    if (raw != null) {
      // A key that is there but cannot be opened (the keychain locked or
      // refusing for a moment) is NOT replaced: a new key would make every
      // paired phone treat this computer as an impostor. The request fails and
      // the next one tries again.
      const pem = raw.startsWith(SEALED_MAGIC)
        ? (unseal ? unseal(Buffer.from(raw.slice(SEALED_MAGIC.length), 'base64')) : null)
        : raw;
      if (!pem) throw new Error('LAN identity key is sealed and the keychain is unavailable');
      const key = crypto.createPrivateKey(pem);
      if (key.asymmetricKeyType !== 'ed25519') throw new Error('LAN identity key is not Ed25519');
      privateKey = key;
    }
    if (!privateKey) {
      // The first time on this computer: make one.
      const pair = crypto.generateKeyPairSync('ed25519');
      privateKey = pair.privateKey;
      const out = privateKey.export({ type: 'pkcs8', format: 'pem' });
      // `seal` returns null when this computer has no keychain to seal with
      // (Linux without a secret service); the file is then owner-only.
      const sealed = seal ? seal(out) : null;
      const body = sealed ? SEALED_MAGIC + sealed.toString('base64') : out;
      const tmp = `${keyPath}.tmp`;
      fs.writeFileSync(tmp, body, { mode: 0o600 });
      fs.renameSync(tmp, keyPath);
    }
    const spki = crypto.createPublicKey(privateKey).export({ type: 'spki', format: 'der' });
    publicRaw = spki.subarray(spki.length - 32);
  }

  /** { alg, publicKey } for GET /api/identity. */
  function identity() {
    load();
    return { alg: 'ed25519', publicKey: publicRaw.toString('base64') };
  }

  /** { alg, sig } for GET /api/proof, or null when the nonce is not 32–128 hex. */
  function proof(nonce) {
    const n = String(nonce == null ? '' : nonce);
    if (!NONCE_RE.test(n)) return null;
    load();
    const sig = crypto.sign(null, Buffer.from(PROOF_PREFIX + n.toLowerCase(), 'ascii'), privateKey);
    return { alg: 'ed25519', sig: sig.toString('base64') };
  }

  return { identity, proof };
}

/** Check a proof the way the phone does — for tests and for anyone reading this. */
function verifyProof(publicKeyB64, nonce, sigB64) {
  const raw = Buffer.from(String(publicKeyB64 || ''), 'base64');
  if (raw.length !== 32) return false;
  const spkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
  const key = crypto.createPublicKey({ key: Buffer.concat([spkiPrefix, raw]), format: 'der', type: 'spki' });
  return crypto.verify(null, Buffer.from(PROOF_PREFIX + String(nonce).toLowerCase(), 'ascii'), key,
    Buffer.from(String(sigB64 || ''), 'base64'));
}

module.exports = { createLanIdentity, verifyProof, PROOF_PREFIX, NONCE_RE };
