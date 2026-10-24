/**
 * What each Khayt Cloud plan card offers this shop's owner.
 *
 * The owner chose (2026-10-24) that the desktop lets the shop owner pick a
 * plan in Cloud settings: free during the beta, the real price shown, and
 * nothing charged. The rule is lib/cloud-plan-picker.js; the server
 * (khayt-cloud choosePlan) refuses the same cases, so the card never offers
 * a button the server would turn down.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const P = require('../lib/cloud-plan-picker.js');

const CAT = (open) => ({
  plans: [{ name: 'free' }, { name: 'maker' }, { name: 'creator' }, { name: 'studio' }],
  defaultPlan: 'free',
  beta: { freeUpgrades: open, endsAt: null, graceDays: 30 },
});
const on = (plan, extra) => ({ billingEnabled: true, plan, status: 'active', active: true, ...extra });
const acts = (cat, b, owner = true) => P.planActions(cat, b, { owner }).map((a) => a.action);

test('a free shop: upgrades open → each paid plan offers an upgrade', () => {
  assert.deepEqual(acts(CAT(true), on('free')), ['current', 'upgrade', 'upgrade', 'upgrade']);
});

test('upgrades not open yet (the server today) → "opens soon", nothing to click', () => {
  assert.deepEqual(acts(CAT(false), on('free')), ['current', 'soon', 'soon', 'soon']);
});

test('on a beta upgrade: back to Free is always offered, other plans per the beta', () => {
  assert.deepEqual(acts(CAT(true), on('maker', { status: 'trialing' })), ['downgrade', 'current', 'upgrade', 'upgrade']);
  assert.deepEqual(acts(CAT(false), on('maker', { status: 'trialing' })), ['downgrade', 'current', 'soon', 'soon']);
});

test('a shop really paying changes its plan where it bought it (the server says paid-plan)', () => {
  assert.deepEqual(acts(CAT(true), on('creator')), ['downgrade', 'paid', 'current', 'paid']);
});

test('not the owner, billing off, or no answer yet → no buttons', () => {
  assert.deepEqual(acts(CAT(true), on('free'), false), ['current', 'none', 'none', 'none']);
  assert.deepEqual(acts(CAT(true), { billingEnabled: false }), ['none', 'none', 'none', 'none']);
  assert.deepEqual(acts(CAT(true), null), ['none', 'none', 'none', 'none']);
  assert.deepEqual(P.planActions(null, on('free'), { owner: true }), []);
});

test('every server refusal has its own words, and the rest a general line', () => {
  for (const r of ['owner-only', 'billing-off', 'unknown-plan', 'no-account', 'paid-plan', 'upgrades-closed', 'beta-over']) {
    assert.match(P.refusalKey(r), /^cplan\.refused\.[a-z_]+$/);
    assert.notEqual(P.refusalKey(r), 'cplan.refused.other');
  }
  assert.equal(P.refusalKey('teapot'), 'cplan.refused.other');
  assert.equal(P.refusalKey(undefined), 'cplan.refused.other');
  const en = fs.readFileSync(path.join(__dirname, '../renderer/locales/en.js'), 'utf8');
  for (const k of [...Object.values(P.REFUSAL_KEYS), 'cplan.refused.other']) assert.ok(en.includes(`"${k}":`), k);
});

test('sizes as the server counts them (binary)', () => {
  assert.equal(P.sizeText(2147483648), '2 GB');
  assert.equal(P.sizeText(161061273600), '150 GB');
  assert.equal(P.sizeText(1099511627776), '1 TB');
  assert.equal(P.sizeText(0), '');
});

test('wired: Settings asks the server, and the picker is loaded', () => {
  const root = path.join(__dirname, '..');
  const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');
  assert.match(read('renderer/settings.js'), /KhaytCloudPlanPicker\.planActions\(cat, billing, \{ owner \}\)/);
  assert.match(read('renderer/settings.js'), /hubAPI\.cloudSetPlan\(/);
  assert.match(read('preload.js'), /cloudSetPlan: \(opts\) => ipcRenderer\.invoke\('hub:cloud-set-plan'/);
  assert.match(read('main.js'), /ipcMain\.handle\('hub:cloud-set-plan'[\s\S]{0,200}cloudToken\(token, url\)/);
  assert.ok(read('renderer/index.html').includes('<script src="../lib/cloud-plan-picker.js"></script>'));
});
