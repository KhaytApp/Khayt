/**
 * A cloud endpoint the app cannot reach is an endpoint that does not exist.
 *
 * /v1/shops/{id}/slug shipped in khayt-cloud with a schema, a resolver, grace
 * periods and a contract test — and NOTHING in the desktop app called it. A shop
 * could not claim a name without issuing an HTTP request by hand. That is the
 * same "built and never plugged in" this repo has caught repeatedly, one layer
 * further out: not a function missing from an export list, but a whole feature
 * missing its consumer.
 *
 * The chain is four files long — cloud-client → main IPC → preload → renderer —
 * and a break anywhere in it is silent. Each link is asserted separately,
 * because "the app calls it somewhere" is not the same as "the button works".
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const read = (...p) => fs.readFileSync(path.join(ROOT, ...p), 'utf8');

test('every cloud client call is exported, bridged, and used', () => {
  const client = read('lib', 'cloud-client.js');
  const main = read('main.js');
  const preload = read('preload.js');
  const renderer = fs.readdirSync(path.join(ROOT, 'renderer'))
    .filter((f) => f.endsWith('.js')).map((f) => read('renderer', f)).join('\n');

  // The pair added for shop names, and the chain each one has to complete.
  for (const [fn, channel, bridge] of [
    ['getShopSlug', 'hub:cloud-get-slug', 'cloudGetSlug'],
    ['setShopSlug', 'hub:cloud-set-slug', 'cloudSetSlug'],
  ]) {
    assert.match(client, new RegExp(`async function ${fn}\\b`), `cloud-client must define ${fn}`);
    assert.match(client, new RegExp(`^\\s{2}${fn},$`, 'm'), `${fn} must be exported, or main.js cannot call it`);
    assert.match(main, new RegExp(`ipcMain\\.handle\\('${channel}'`), `main.js must handle ${channel}`);
    assert.match(main, new RegExp(`cloudClient\\.${fn}\\(`), `${channel} must actually call ${fn}`);
    assert.match(preload, new RegExp(`${bridge}:.*'${channel}'`), `preload must bridge ${channel}`);
    assert.match(renderer, new RegExp(`hubAPI\\.${bridge}\\(`), `something in the renderer must call ${bridge} — an endpoint with no caller is not a feature`);
  }
});

test('the shop-name field exists and reports what the server said', () => {
  const s = read('renderer', 'settings.js');
  assert.match(s, /id="cloudSlug"/, 'the owner needs somewhere to type it');
  assert.match(s, /id="btnCloudSlug"/);
  assert.match(s, /hubAPI\.cloudGetSlug/, 'the field must show the name already claimed');
  assert.match(s, /hubAPI\.cloudSetSlug/);
  // The server owns the rules — reserved words, what is taken — so its message
  // is the one shown rather than a second copy of the rules living here.
  assert.match(s, /say\(r\?\.error \|\|/, 'the server\'s own reason must reach the user');
});

test('only the owner is offered it', () => {
  // A member of a team must not be able to rename the shop's public address.
  const s = read('renderer', 'settings.js');
  const block = s.slice(s.indexOf('id="cloudSlug"') - 900, s.indexOf('id="cloudSlug"'));
  assert.match(block, /=== 'owner'/, 'the field is inside an owner-only branch');
});
