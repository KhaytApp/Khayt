'use strict';
/**
 * The Electron fuses both installers are built with (package.json build.electronFuses,
 * which electron-builder flips after afterPack and before signing).
 *
 * Without them a packaged Khayt could be started as a plain Node.js runtime
 * (ELECTRON_RUN_AS_NODE), have code injected through NODE_OPTIONS, or run an
 * app.asar somebody edited — each of which runs with Khayt's identity and so
 * with its keychain item, where every shop credential is sealed.
 *
 * Bed Ready spreads Khayt's `build` block (electron-builder.bedready.js), so it
 * gets the same fuses; its own afterPack (the flavor marker) runs before they
 * are flipped and is untouched.
 *
 * EnableNodeCliInspectArguments is deliberately LEFT ON. scripts/verify-release.mjs
 * — the release gate that installs and opens the packaged app before it goes
 * public — drives it with Playwright, and Playwright's electron.launch always
 * passes `--inspect=0` and waits for the inspector. Turning that fuse off makes
 * every release fail its own launch check. Turn it off only together with a
 * release check that does not need the inspector.
 *
 * None of this touches the E2E suites: they run the unpackaged `electron .` from
 * node_modules, whose binary is never flipped.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');

const root = path.join(__dirname, '..');
const khayt = require(path.join(root, 'package.json')).build;
const bedready = require(path.join(root, 'electron-builder.bedready.js'));

const EXPECTED = {
  runAsNode: false,
  enableNodeOptionsEnvironmentVariable: false,
  enableEmbeddedAsarIntegrityValidation: true,
  onlyLoadAppFromAsar: true,
  enableCookieEncryption: true,
};

for (const [name, cfg] of [['Khayt', khayt], ['Bed Ready', bedready]]) {
  test(`${name} is built with the hardening fuses`, () => {
    assert.ok(cfg.electronFuses, `${name} has no electronFuses`);
    for (const [fuse, want] of Object.entries(EXPECTED)) {
      assert.equal(cfg.electronFuses[fuse], want, `${name}: ${fuse} should be ${want}`);
    }
    // Asar integrity and "only from asar" both need the app packed into one.
    assert.notEqual(cfg.asar, false, `${name}: asar is off, so the integrity fuses would brick the app`);
  });

  test(`${name} leaves the inspector fuse alone, for the release launch check`, () => {
    assert.notEqual(cfg.electronFuses.enableNodeCliInspectArguments, false,
      'scripts/verify-release.mjs launches the packaged app through Playwright, which needs --inspect');
  });
}

test("Bed Ready's flavor marker hook is still there", () => {
  assert.equal(typeof bedready.afterPack, 'function');
});
