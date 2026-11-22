'use strict';

/**
 * What Khayt remembers between MakerRun library syncs.
 *
 * Three things, all of them cheap and none of them secret — a cursor, the last
 * listing, and a note of which file bytes are already on disk. Kept beside the
 * account file in userData rather than in the shop's store, because it is cache
 * about somebody's MakerRun account and not data about their business: deleting
 * it must cost a re-sync and nothing else.
 *
 * ── WHY A CURSOR ALONE IS NOT ENOUGH ───────────────────────────────────────
 *
 * `GET /api/library?since=` narrows the answer to designs whose listing or file
 * changed after that instant, "plus anything newly saved". It cannot report an
 * UNSAVE: removing a design from a library changes no row it would return. So a
 * client that merged `?since=` results into a cached list would show a design
 * the user had removed, indefinitely, with nothing to correct it.
 *
 * That is why the cursor is used as a PROBE and not as a delta feed — see
 * `syncLibrary` in makerrun-library.js. `filtered && count === 0` is the one
 * answer it can give that is safe to act on alone: nothing changed, so the cache
 * is still right. Any other answer triggers an authoritative full fetch, which
 * reflects removals because it is the whole list.
 *
 * The saving is real anyway, because the common case IS "nothing changed": the
 * probe costs one small response and no signed URLs, against a full listing that
 * presigns a URL per design.
 */

const fs = require('fs');
const path = require('path');

const FILE = 'makerrun-sync.json';

/** Bump when the shape changes; an older file is discarded rather than migrated. */
const VERSION = 1;

const fileFor = (userDataDir) => path.join(userDataDir, FILE);

const EMPTY = { version: VERSION, syncedAt: null, items: [], files: {} };

/**
 * Read the sync state, or an empty one.
 *
 * Fails soft on purpose. Every field here is reconstructible by syncing again,
 * so a corrupt or half-written file must cost a full sync and never an error a
 * shop has to read — the cache is an optimisation and an optimisation that can
 * break the feature is not one.
 */
function read(userDataDir) {
  try {
    const raw = JSON.parse(fs.readFileSync(fileFor(userDataDir), 'utf8'));
    if (!raw || raw.version !== VERSION) return { ...EMPTY };
    return {
      version: VERSION,
      syncedAt: typeof raw.syncedAt === 'string' ? raw.syncedAt : null,
      items: Array.isArray(raw.items) ? raw.items : [],
      files: (raw.files && typeof raw.files === 'object' && !Array.isArray(raw.files)) ? raw.files : {},
    };
  } catch (_) {
    return { ...EMPTY };
  }
}

function write(userDataDir, state) {
  const out = { ...EMPTY, ...state, version: VERSION };
  fs.writeFileSync(fileFor(userDataDir), JSON.stringify(out), 'utf8');
  return out;
}

function clear(userDataDir) {
  try { fs.unlinkSync(fileFor(userDataDir)); } catch (_) { /* already gone */ }
}

/**
 * The key a downloaded file is remembered under.
 *
 * `designId` rather than the slug or the path: a design can be retitled, which
 * moves its slug and therefore its filename, and neither of those changes the
 * bytes. Keying on anything that a rename moves would make every retitle look
 * like a new file and re-download it — which is the behaviour being removed.
 */
const keyFor = (item) => String((item && (item.designId || item.slug)) || '').trim();

/**
 * Do we already hold this design's exact bytes?
 *
 * Both halves have to agree AND the file has to still be there. A manifest entry
 * whose file somebody has since deleted is a promise the cache cannot keep, and
 * believing it would leave the shop with a library entry and no file — worse
 * than re-downloading, because it looks like it worked.
 *
 * A missing checksum is NOT a match. The API returns `checksum: null` for a
 * gated design deliberately (an eTag fingerprints bytes behind the vault), and
 * for anything else null means "could not be determined" — neither is a reason
 * to skip a download, and treating absence as agreement is how a stale file
 * survives for ever.
 */
function alreadyHave(state, item, existsSync = fs.existsSync) {
  const rec = state && state.files && state.files[keyFor(item)];
  if (!rec || !item) return null;
  if (!item.checksum || !rec.checksum) return null;
  if (rec.checksum !== item.checksum) return null;
  // Same digest under a different algorithm is not the same claim.
  if ((rec.checksumAlgo || null) !== (item.checksumAlgo || null)) return null;
  // The bytes' own timestamp, when both sides carry one.
  if (item.fileUpdatedAt && rec.fileUpdatedAt && item.fileUpdatedAt !== rec.fileUpdatedAt) return null;
  if (!rec.path || !existsSync(rec.path)) return null;
  return rec.path;
}

/** Record that `filePath` holds exactly the bytes this item described. */
function remember(state, item, filePath) {
  const key = keyFor(item);
  if (!key || !filePath) return state;
  return {
    ...state,
    files: {
      ...state.files,
      [key]: {
        path: filePath,
        checksum: item.checksum || null,
        checksumAlgo: item.checksumAlgo || null,
        fileUpdatedAt: item.fileUpdatedAt || null,
        sizeBytes: Number.isFinite(item.sizeBytes) ? item.sizeBytes : null,
      },
    },
  };
}

module.exports = { read, write, clear, fileFor, alreadyHave, remember, keyFor, FILE, VERSION, EMPTY };
