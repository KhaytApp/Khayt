const { test } = require('node:test');
const assert = require('node:assert/strict');
const { setMacVersion } = require('../scripts/mac-site-version.js');

/* A named version on a download page is a claim, and this repo's history is
 * claims that stopped being true and stayed. `check-release-claims.js` exists
 * because four files disagreed about the current release at once. So the
 * release lane writes this one. */

const LINE = '<div class="b" dir="ltr" data-mac-version>4.0.0-alpha.1 · macOS 26+ · notarized</div>';

test('it replaces the version and keeps the prose around it', () => {
  const out = setMacVersion(LINE, '4.0.0-alpha.2');
  assert.match(out, /4\.0\.0-alpha\.2 · macOS 26\+ · notarized/);
  assert.ok(!out.includes('alpha.1'));
  // The attributes survive — dir="ltr" is what stops Arabic reordering the
  // version string, and losing it would be invisible in English.
  assert.match(out, /dir="ltr"/);
});

test('it finds the line by its MARKER, never by the version it is replacing', () => {
  // Searching a page for the number you are about to change is how
  // update_version.py came to rewrite the wrong product's version.
  const other = '<p>Khayt 3.7.0 for Windows</p>' + LINE;
  const out = setMacVersion(other, '4.1.0');
  assert.match(out, /Khayt 3\.7\.0 for Windows/, 'it touched something else');
  assert.match(out, /data-mac-version>4\.1\.0 /);
});

test('a page with no marker is an error, not a silent no-op', () => {
  // Silently doing nothing is how a page goes stale while its updater reports
  // success every time.
  assert.throws(() => setMacVersion('<div class="b">4.0.0</div>', '4.1.0'), /data-mac-version/);
});

test('it refuses a version that is not one', () => {
  for (const v of ['', 'latest', 'v4.0.0', '4.0', null]) {
    assert.throws(() => setMacVersion(LINE, v), /not a semver/, String(v));
  }
});

test('running it twice changes nothing the second time', () => {
  const once = setMacVersion(LINE, '4.2.0');
  assert.equal(setMacVersion(once, '4.2.0'), once);
});
