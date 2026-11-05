'use strict';
/**
 * A copy of the shop's book that lives somewhere other than this computer.
 *
 * The desktop's daily backups sit beside the book, on the same disk: they undo
 * a bad afternoon and do nothing for a stolen, dead or flooded laptop. This is
 * the other half, and it is the Mac's `OffsiteBackup` (KhaytCore, Swift) in
 * JavaScript, written to the SAME FILES: a backup made by either app restores
 * on the other.
 *
 * ── NOTHING LEAVES UNENCRYPTED ──────────────────────────────────────────
 *
 * The book is sealed with the shop's Khayt Cloud data key — the same
 * AES-256-GCM + gzip blob `lib/sync-crypto.js` `encryptStore` writes and the
 * Mac's `SyncCrypto.sealBytes` writes — so it opens on a NEW computer from the
 * shop's passphrase. With no key there is no upload: `seal` refuses by name
 * rather than falling back to plain text.
 *
 * ── THE FILE ────────────────────────────────────────────────────────────
 *
 * `khayt-book-YYYY-MM-DD.khaytbak`, one a day (a second run the same day
 * replaces the first), holding `{ blob, createdAt, format, v }` with sorted
 * keys, as the Mac's JSONEncoder(.sortedKeys) writes it. At a bucket or a
 * Drive it sits under `[prefix]/khayt-offsite-backups/`; in a folder, at the
 * folder's top.
 *
 * Seal, upload, PROVE (download it again: byte-identical, and it opens), and
 * only then prune — so a failed night never costs an old backup.
 *
 * Node only (crypto, zlib). The schedule, the settings and the screen are the
 * app's (lib/main/offsite-backup.js).
 */
const crypto = require('crypto');
const zlib = require('zlib');

const FOLDER = 'khayt-offsite-backups';
const STEM = 'khayt-book-';
const EXT = 'khaytbak';
const FORMAT = 'khayt-offsite-backup';
const VERSION = 1;
/** The store blob's version and compression marker — sync-crypto's. */
const BLOB_V = 1;
const BLOB_Z = 'gzip';
const ONE_DAY_MS = 24 * 60 * 60 * 1000;

class OffsiteError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const fail = {
  noKey: () => new OffsiteError('noKey', 'there is no Khayt Cloud key on this computer to encrypt the backup with — unlock Khayt Cloud first'),
  notABackup: () => new OffsiteError('notABackup', 'that file is not a Khayt off-site backup'),
  tooNew: (v) => new OffsiteError('tooNew', `that backup was written by a newer Khayt (format ${v})`),
  missing: (name) => new OffsiteError('missing', `${name} is not at the destination`),
  readBackDiffers: () => new OffsiteError('readBackDiffers', 'the copy read back from the destination is not the one sent'),
  wrongKey: () => new OffsiteError('wrongKey', "the backup would not open with this shop's key"),
};

// ── Names ─────────────────────────────────────────────────────────────────

function filename(day) { return STEM + day + '.' + EXT; }

/** The day a backup is for, or null when the name is not one of ours. */
function dayOf(name) {
  const s = String(name || '');
  if (!s.startsWith(STEM) || !s.endsWith('.' + EXT)) return null;
  const day = s.slice(STEM.length, s.length - EXT.length - 1);
  return /^\d{4}-\d{2}-\d{2}$/.test(day) ? day : null;
}

function keyFolder(prefix) {
  const clean = String(prefix || '').replace(/^[\/ ]+|[\/ ]+$/g, '');
  return [clean, FOLDER].filter(Boolean).join('/');
}
function key(prefix, name) { return keyFolder(prefix) + '/' + name; }

/** The name a listed key stands for, or null for one not directly inside
 *  `folder` (outside it, nested, empty, or with `..` in it). */
function listedName(k, folder) {
  const s = String(k || '');
  if (!s.startsWith(folder)) return null;
  const name = s.slice(folder.length);
  if (!name || name.includes('/') || name.includes('\\') || name.includes('..')) return null;
  return name;
}

// ── Keeping 30 dailies and 12 monthlies ──────────────────────────────────

/** Which backups to delete: all but the newest `keepDaily`, and then the
 *  newest of each month for `keepMonthly` months older than those. Names that
 *  are not ours are never returned. */
function toPrune(names, keepDaily = 30, keepMonthly = 12) {
  const dated = (names || []).map((n) => ({ name: n, day: dayOf(n) })).filter((x) => x.day)
    .sort((a, b) => (a.day < b.day ? 1 : a.day > b.day ? -1 : 0));
  const dailies = dated.slice(0, Math.max(0, keepDaily));
  const keep = new Set(dailies.map((x) => x.name));
  const months = [];
  for (const entry of dated.slice(dailies.length)) {
    const month = entry.day.slice(0, 7);
    if (months.includes(month)) continue;
    months.push(month);
    if (months.length > keepMonthly) break;
    keep.add(entry.name);
  }
  return dated.filter((x) => !keep.has(x.name)).map((x) => x.name).sort();
}

// ── The sealed file ──────────────────────────────────────────────────────

/** Recursively sorted keys, as Swift's `.sortedKeys` writes them. */
function sortedJson(v) {
  if (Array.isArray(v)) return '[' + v.map(sortedJson).join(',') + ']';
  if (v && typeof v === 'object') {
    return '{' + Object.keys(v).sort().filter((k) => v[k] !== undefined)
      .map((k) => JSON.stringify(k) + ':' + sortedJson(v[k])).join(',') + '}';
  }
  return JSON.stringify(v);
}

/** Seal the book's bytes exactly as they are on disk. */
function seal(book, dek, createdAt) {
  if (!dek || !dek.length) throw fail.noKey();
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', Buffer.from(dek), iv);
  const ct = Buffer.concat([cipher.update(zlib.gzipSync(Buffer.from(book))), cipher.final()]);
  const blob = { v: BLOB_V, z: BLOB_Z, iv: iv.toString('base64'), ct: ct.toString('base64'), tag: cipher.getAuthTag().toString('base64') };
  return Buffer.from(sortedJson({ format: FORMAT, v: VERSION, createdAt: String(createdAt), blob }), 'utf8');
}

/** The book's bytes back out of a sealed file. */
function open(sealed, dek) {
  if (!dek || !dek.length) throw fail.noKey();
  let env;
  try { env = JSON.parse(Buffer.from(sealed).toString('utf8')); } catch (_) { throw fail.notABackup(); }
  if (!env || env.format !== FORMAT || !env.blob) throw fail.notABackup();
  if (Number(env.v) > VERSION) throw fail.tooNew(env.v);
  let plain;
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', Buffer.from(dek), Buffer.from(env.blob.iv, 'base64'));
    d.setAuthTag(Buffer.from(env.blob.tag, 'base64'));
    plain = Buffer.concat([d.update(Buffer.from(env.blob.ct, 'base64')), d.final()]);
  } catch (_) { throw fail.wrongKey(); }
  return env.blob.z === BLOB_Z ? zlib.gunzipSync(plain) : plain;
}

// ── One night's run ──────────────────────────────────────────────────────

/** Seal, upload, prove, then prune. */
async function run({ book, dek, day, createdAt, destination, keepDaily = 30, keepMonthly = 12 }) {
  const sealed = seal(book, dek, createdAt);
  const name = filename(day);
  await destination.put(name, sealed);
  const back = await destination.get(name);
  if (!back) throw fail.missing(name);
  if (!Buffer.from(back).equals(sealed) || !open(back, dek).equals(Buffer.from(book))) throw fail.readBackDiffers();
  const pruned = [];
  let pruneFailures = 0;
  const present = (await destination.list()).map((e) => e.name);
  for (const old of toPrune(present, keepDaily, keepMonthly)) {
    if (old === name) continue;
    try { await destination.delete(old); pruned.push(old); } catch (_) { pruneFailures += 1; }
  }
  return { name, bytes: sealed.length, pruned, pruneFailures };
}

/** Ours only, newest first. */
async function available(destination) {
  return (await destination.list()).filter((e) => dayOf(e.name))
    .sort((a, b) => (dayOf(a.name) < dayOf(b.name) ? 1 : -1));
}

async function fetchBook(name, destination, dek) {
  if (!dek || !dek.length) throw fail.noKey();
  if (!dayOf(name)) throw fail.notABackup();
  const sealed = await destination.get(name);
  if (!sealed) throw fail.missing(name);
  return open(sealed, dek);
}

// ── Status ───────────────────────────────────────────────────────────────

function succeeded(outcome, now) {
  return { lastAt: new Date(now).toISOString(), lastBytes: outcome.bytes, lastName: outcome.name, failingSince: null, lastError: null };
}
/** A failure keeps the FIRST failure's time, so "failing for two days" counts
 *  from when it started. */
function failed(status, why, now) {
  const s = status || {};
  return { ...s, failingSince: s.failingSince || new Date(now).toISOString(), lastError: String(why) };
}
function isDue(status, now) {
  const last = Date.parse((status && status.lastAt) || '');
  return !Number.isFinite(last) || (now - last) >= ONE_DAY_MS;
}
function isOverdue(status, now, after = 2 * ONE_DAY_MS) {
  const since = Date.parse((status && status.failingSince) || '');
  return Number.isFinite(since) && (now - since) > after;
}

// ── Destinations: put / get / list / delete over plain names ─────────────

/** A bucket (lib/s3-client.js), under `[prefix]/khayt-offsite-backups/`. */
function bucketDestination(s3, prefix) {
  const folder = keyFolder(prefix) + '/';
  return {
    put: (name, data) => s3.put(key(prefix, name), data),
    get: (name) => s3.get(key(prefix, name)),
    delete: (name) => s3.del(key(prefix, name)),
    list: async () => (await s3.list(folder)).map((it) => {
      const name = listedName(it.key, folder);
      return name ? { name, bytes: it.size, modified: it.modified || null } : null;
    }).filter(Boolean),
  };
}

/** Google Drive (lib/gdrive-client.js), each file tagged with its key. */
function driveDestination(drive, prefix) {
  const folder = keyFolder(prefix) + '/';
  return {
    put: (name, data) => drive.put(key(prefix, name), data),
    get: (name) => drive.get(key(prefix, name)),
    delete: (name) => drive.del(key(prefix, name)),
    list: async () => (await drive.list(folder, STEM)).map((it) => {
      const name = listedName(it.key, folder);
      return name ? { name, bytes: it.size, modified: it.modified || null } : null;
    }).filter(Boolean),
  };
}

/** A folder something else carries away (Dropbox, OneDrive, a network share).
 *  Basename only, so a name with `../` never reaches outside it; written via a
 *  temp file and a rename, so a sync client never uploads half a file. */
function folderDestination(root, fs = require('fs'), path = require('path')) {
  const at = (name) => path.join(root, path.basename(String(name)));
  return {
    async put(name, data) {
      fs.mkdirSync(root, { recursive: true });
      const tmp = at(name) + '.tmp-' + process.pid;
      fs.writeFileSync(tmp, data);
      fs.renameSync(tmp, at(name));
    },
    async get(name) { return fs.existsSync(at(name)) ? fs.readFileSync(at(name)) : null; },
    async delete(name) { if (fs.existsSync(at(name))) fs.unlinkSync(at(name)); },
    async list() {
      if (!fs.existsSync(root)) return [];
      return fs.readdirSync(root).map((file) => {
        try {
          const st = fs.statSync(path.join(root, file));
          return st.isFile() ? { name: file, bytes: st.size, modified: st.mtime.toISOString() } : null;
        } catch (_) { return null; }
      }).filter(Boolean);
    },
  };
}

module.exports = {
  FOLDER, STEM, EXT, FORMAT, VERSION, ONE_DAY_MS, OffsiteError,
  filename, dayOf, keyFolder, key, listedName, toPrune, sortedJson,
  seal, open, run, available, fetchBook,
  succeeded, failed, isDue, isOverdue,
  bucketDestination, driveDestination, folderDestination,
};
