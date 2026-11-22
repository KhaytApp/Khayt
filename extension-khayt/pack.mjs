// Package "Save to Khayt" for each browser, from the one source in this folder.
//
//   node extension-khayt/pack.mjs                 # all three, into extension-khayt/dist/
//   node extension-khayt/pack.mjs safari <dir>    # the Safari resources only, into <dir>
//
// ONE SOURCE, THREE MANIFESTS. The code is identical everywhere; only how the
// background is declared differs, and what each store insists on:
//
//   chrome   — `background.service_worker`. Also Edge and Brave, unchanged.
//   firefox  — `background.scripts` (an event page) and a gecko id, which AMO
//              requires before it will sign anything.
//   safari   — `background.scripts` with `persistent: false`, which Safari
//              requires for MV3; copied by `mac/make-app.sh` into
//              Khayt.app/Contents/PlugIns/KhaytSafari.appex/Contents/Resources,
//              where Safari reads a web extension from.
//
// Nothing is minified or bundled: a reviewer reads exactly what runs. Nothing
// here publishes anything — see README.md for the store steps.
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));

/** What ships. Tests, this script and the package file do not. */
export const FILES = ['popup.html', 'popup.css', 'popup.js', 'background.js', 'src', 'icons', '_locales'];

/** The gecko id AMO signs under. Turki's to confirm before the first upload. */
export const GECKO_ID = 'save@khaytapp.com';

/**
 * Chrome's and Firefox's extra permissions, for the download from a page just
 * saved: `downloads` to see it finish (its path, address and referrer — nothing
 * is read from the file), `storage` for `storage.session`, where the last ten
 * minutes' saves are remembered until the browser quits.
 */
export const SAFARI_LEAVES_OUT = ['downloads', 'storage'];

export function manifestFor(browser) {
  const m = JSON.parse(readFileSync(join(here, 'manifest.json'), 'utf8'));
  if (browser === 'firefox') {
    delete m.minimum_chrome_version;
    m.background = { scripts: ['background.js'] };
    m.browser_specific_settings = {
      gecko: {
        id: GECKO_ID,
        strict_min_version: '128.0',
        // Page details go to the Khayt app on this computer and nowhere else:
        // nothing is collected by or sent to the developer.
        data_collection_permissions: { required: ['none'] },
      },
    };
  } else if (browser === 'safari') {
    delete m.minimum_chrome_version;
    m.background = { scripts: ['background.js'], persistent: false };
    // Safari has no downloads API — the app watches ~/Downloads for a few
    // minutes after a save instead — so it asks for neither of these.
    m.permissions = m.permissions.filter((p) => !SAFARI_LEAVES_OUT.includes(p));
  }
  return m;
}

export function stage(browser, out) {
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  for (const f of FILES) cpSync(join(here, f), join(out, f), { recursive: true });
  writeFileSync(join(out, 'manifest.json'), JSON.stringify(manifestFor(browser), null, 2) + '\n');
  return out;
}

function zip(dir, file) {
  rmSync(file, { force: true });
  // `zip -X` leaves out the Mac's extended attributes, which the stores reject.
  execFileSync('zip', ['-qrX', file, '.'], { cwd: dir });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [what, target] = process.argv.slice(2);
  if (what === 'safari') {
    if (!target) { console.error('usage: pack.mjs safari <dir>'); process.exit(2); }
    stage('safari', resolve(target));
    console.log(`  safari extension: ${resolve(target)}`);
  } else {
    const dist = join(here, 'dist');
    mkdirSync(dist, { recursive: true });
    for (const b of ['chrome', 'firefox', 'safari']) {
      const dir = stage(b, join(dist, b));
      if (b !== 'safari') zip(dir, join(dist, `khayt-${b}.zip`));
    }
    console.log(`  packages: ${dist}`);
    if (!existsSync(join(dist, 'khayt-chrome.zip'))) process.exit(1);
  }
}
