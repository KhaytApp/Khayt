'use strict';

/**
 * Bed Ready data-dir independence.
 *
 * Bed Ready historically shared Khayt's Electron userData directory: app.name derives from package.json
 * ("khayt"), so app.getPath('userData') is …/khayt for BOTH flavors — meaning existing Bed Ready installs
 * (beta.1–5) have all their data under …/khayt, and a machine running both products would clobber itself.
 *
 * To make Bed Ready fully independent on disk (its own …/BedReady dir) WITHOUT losing that data and WITHOUT
 * disturbing a co-installed Khayt, we do a one-time **copy** migration on first launch of the new build,
 * then point userData at the new dir. Copy (not move) so Khayt keeps its data on a dual-install; the stale
 * shared copy is harmless. The migration is atomic (copy to a temp dir, then rename) so a partial/aborted
 * copy never becomes the live dir, and it fails safe (keeps using the shared dir) on any error.
 *
 * Main-process, Node-only. Pure w.r.t. its argument (takes the appData dir), so it is unit-testable.
 */
const fs = require('fs');
const path = require('path');

const BR_DIRNAME = 'BedReady';   // Bed Ready's own userData dir name (no space, matches BedReady-* artifacts)
const LEGACY_DIRNAME = 'khayt';  // the shared dir app.name still derives to

function hasEntries(dir) {
  try { return fs.existsSync(dir) && fs.readdirSync(dir).length > 0; } catch { return false; }
}

/**
 * Resolve Bed Ready's own userData dir under `appDataDir`, migrating once from the legacy shared
 * "khayt" dir when needed. Always returns an existing directory suitable for app.setPath('userData', …).
 *
 * - new dir already exists  → use it (already independent)
 * - legacy dir has data     → copy it in (minus the large, regenerable `backups/`), atomically promote
 * - neither                 → fresh install: create + use the new dir
 * - migration error         → fail safe: keep using the legacy shared dir (never lose access to data)
 */
function migrateAndResolveUserData(appDataDir) {
  const brDir = path.join(appDataDir, BR_DIRNAME);
  if (fs.existsSync(brDir)) return brDir;

  const legacy = path.join(appDataDir, LEGACY_DIRNAME);
  if (hasEntries(legacy)) {
    const tmp = brDir + '.migrating';
    try {
      fs.rmSync(tmp, { recursive: true, force: true });
      // Skip `backups/` — large, and regenerated from the (copied) live store; keeps first-launch fast.
      fs.cpSync(legacy, tmp, { recursive: true, filter: (src) => path.basename(src) !== 'backups' });
      fs.renameSync(tmp, brDir); // atomic: a partial copy never goes live
      return brDir;
    } catch {
      try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* ignore */ }
      return legacy; // fail safe — keep the shared dir rather than start empty or lose data
    }
  }

  try { fs.mkdirSync(brDir, { recursive: true }); } catch { /* Electron will create on demand */ }
  return brDir;
}

module.exports = { migrateAndResolveUserData, hasEntries, BR_DIRNAME, LEGACY_DIRNAME };
