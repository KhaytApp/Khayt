/**
 * The signup links on the provider dropdown, rendered against the real
 * index.html rather than asserted as source text.
 *
 * The failure this guards is invisible by construction. Every other field in
 * this form is copied off a provider dashboard, so a shop that has no account
 * yet cannot fill in one of them — the link is the only control on the page it
 * can use. And if the anchor stops rendering, nothing breaks and nothing logs:
 * the shop sees the same unfillable form the links were added to fix, and the
 * only symptom is a signup that never happens.
 *
 * The other half is the referral disclosure. lib/storage-providers.js has a
 * slot for affiliate links and ships it empty; whether a link is disclosed as
 * commercial is decided here, in the renderer, so this is where it has to be
 * pinned. A referral that resolves without its disclosure is an undisclosed
 * paid link in a settings page, which is worse than having no slot at all.
 */
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { setupDom } = require('./helpers/dom.js');
const SP = require('../lib/storage-providers.js');

let dom;
let opened;

/**
 * Boot the settings panel with main's real provider table behind IPC, so a
 * provider that main can offer but the renderer cannot draw fails here.
 */
async function bootSettings() {
  dom.loadI18n();
  dom.seedState();
  // Free globals settings.js reads from sibling renderer files. In the browser
  // they share a scope; under Node's per-module scope the test supplies them.
  global.secretFieldPlaceholder = () => '';
  opened = [];
  global.window.hubAPI = {
    storageProviders: async () => ({
      providers: SP.list(),
      pricedOn: SP.PRICED_ON,
      current: '',
      vars: {},
      endpoint: '',
    }),
    storageResolveEndpoint: async (id, vars) => SP.resolveEndpoint(id, vars),
    printLibStatus: async () => null,
    openExternal: (url) => { opened.push(url); return Promise.resolve({ ok: true }); },
  };
  delete require.cache[require.resolve('../renderer/settings.js')];
  const api = require('../renderer/settings.js');
  await api.renderPrintLibLocation();
  return api;
}

const link = () => ({
  el: $('#plibS3Signup'),
  shown: $('#plibS3Signup').style.display !== 'none',
  text: $('#plibS3Signup').textContent || '',
  url: $('#plibS3Signup').dataset.url || '',
  title: $('#plibS3Signup').getAttribute('title') || '',
  disclosed: $('#plibS3SignupRef').style.display !== 'none',
  disclosure: $('#plibS3SignupRef').textContent || '',
});

async function pick(api, id) {
  $('#set_plibS3Provider').value = id;
  api.onPrintLibProviderChange();
  // onPrintLibProviderChange kicks off the endpoint preview, which is async.
  await new Promise((r) => setTimeout(r, 0));
}

beforeEach(() => { dom = setupDom(); });
afterEach(() => { dom.teardown(); });

test('every provider that has a signup page draws its link', async () => {
  const api = await bootSettings();
  for (const p of SP.list()) {
    await pick(api, p.id);
    const l = link();
    if (!p.signup) {
      assert.equal(l.shown, false, `${p.id} has no signup page but drew a link`);
      continue;
    }
    assert.equal(l.shown, true, `${p.id} has a signup page but drew no link`);
    assert.equal(l.url, p.signup, `${p.id}: wrong link target`);
    assert.ok(l.text.trim(), `${p.id}: the link rendered with no text`);
    // Hovering answers "where does this go" without clicking, which is the
    // question a referral link makes worth answering.
    assert.equal(l.title, p.signup, `${p.id}: the hover destination is wrong`);
  }
});

test('the link names the provider, so it is obvious where it goes', async () => {
  const api = await bootSettings();
  await pick(api, 'r2');
  assert.match(link().text, /Cloudflare R2/);
  await pick(api, 'aws');
  assert.match(link().text, /Amazon S3/);
});

test('a self-hosted option offers a download, not an account', async () => {
  // "Create an account at MinIO / NAS (self-hosted)" is wrong twice over: there
  // is no account, and the label reads as a service the shop would be billed for.
  const api = await bootSettings();
  await pick(api, 'minio');
  const l = link();
  assert.equal(l.shown, true);
  assert.doesNotMatch(l.text, /account/i);
  assert.match(l.text, /download/i);
});

test('"Other" draws no link and leaves none behind', async () => {
  // The stale-link case: pick R2, then Other. A link that only hides but keeps
  // its href sends a shop that has picked "Other" to Cloudflare.
  const api = await bootSettings();
  await pick(api, 'r2');
  assert.equal(link().shown, true);
  await pick(api, 'custom');
  const l = link();
  assert.equal(l.shown, false, '"Other" drew a signup link');
  assert.equal(l.url, '', '"Other" kept the previous provider\'s URL');
  assert.equal(l.title, '', '"Other" kept the previous provider\'s hover text');
});

test('clicking opens the provider in the real browser, not in the app window', async () => {
  // Navigating the app's own window to an external page would carry hubAPI with
  // it; main blocks that, so a link that tried would simply be dead.
  const api = await bootSettings();
  await pick(api, 'b2');
  const before = $('#plibS3Signup').getAttribute('href');
  $('#plibS3Signup').dispatchEvent(new window.Event('click', { bubbles: true, cancelable: true }));
  assert.deepEqual(opened, [SP.byId('b2').signup]);
  assert.equal(before, '#', 'the anchor must not carry a real href for the click to preventDefault');
});

test('switching provider repeatedly opens one page per click, not one per switch', async () => {
  // renderPrintLibProviderFields re-runs on every change; a listener added each
  // time would open the page as many times as the shop had browsed the list.
  const api = await bootSettings();
  for (const id of ['r2', 'b2', 'aws', 'r2']) await pick(api, id);
  $('#plibS3Signup').dispatchEvent(new window.Event('click', { bubbles: true, cancelable: true }));
  assert.equal(opened.length, 1, `one click opened ${opened.length} pages`);
});

test('no referral configured means nothing claims one', async () => {
  const api = await bootSettings();
  for (const id of ['r2', 'b2', 'aws']) {
    await pick(api, id);
    assert.equal(link().disclosed, false, `${id} disclosed a referral that does not exist`);
  }
});

test('a configured referral is disclosed where it is clicked', async () => {
  SP.REFERRALS.b2 = 'https://www.backblaze.com/sign-up/cloud-storage?ref=test';
  try {
    const api = await bootSettings();
    await pick(api, 'b2');
    const l = link();
    assert.equal(l.url, SP.REFERRALS.b2, 'the referral link was not used');
    assert.equal(l.disclosed, true, 'a paid link rendered with no disclosure');
    assert.ok(l.disclosure.trim(), 'the disclosure rendered empty');
    // And it must not bleed onto the next provider.
    await pick(api, 'r2');
    assert.equal(link().disclosed, false, 'the disclosure stuck to an unrelated provider');
  } finally { delete SP.REFERRALS.b2; }
});
