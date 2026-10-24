/**
 * While the Mac keeps the library in the Khayt Vault, the desktop uses no
 * other remote for it.
 *
 * Copying new files to a bucket or Drive beside the vault splits the library;
 * turning the vault off from here makes the Mac fall back and lose sight of it.
 * So main has no remote while vault.enabled is true (older files are still
 * brought back: printLibRemotesFor asks bucket and Drive even when off), and
 * Settings keeps both switches off. The panel itself: test:e2e:cloudstorage.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

test('printLibRemote is null while the vault is on', () => {
  const src = read('main.js');
  const fn = src.slice(src.indexOf('function printLibRemote() {'), src.indexOf('function printLibVaultOn()'));
  assert.match(fn, /if \(printLibVaultOn\(\)\) return null;\s*return printLibS3\(\) \|\| printLibDrive\(\);/);
  assert.match(src, /function printLibVaultOn\(\) \{[\s\S]{0,120}v\.enabled === true/);
  // Bring-back still asks the old remotes.
  const remotes = src.slice(src.indexOf('function printLibRemotesFor('));
  assert.match(remotes.slice(0, 600), /printLibDrive\(\{ evenIfOff: true \}\)[\s\S]*printLibS3\(\{ evenIfOff: true \}\)/);
});

test('Settings cannot switch the bucket or Drive on beside the vault', () => {
  const src = read('renderer/settings.js');
  assert.match(src, /enabled: !plibVaultIsOn\(\) && !!\$\('#set_plibS3On'\)\?\.checked/);
  assert.match(src, /enabled: !plibVaultIsOn\(\) && !!\$\('#set_plibGDriveOn'\)\?\.checked/);
  assert.match(read('renderer/index.html'), /id="plibVaultNote"[^>]*data-i18n="set\.plib_vault_lock"/);
});
