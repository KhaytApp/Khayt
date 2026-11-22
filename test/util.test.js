const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  escapeHtml,
  parseCsvString,
  safeCssColor,
  initials,
  buildLanOrderTrackingUrl,
  buildLanQuoteApprovalUrl,
  copyText,
} = require('../renderer/util.js');

test('escapeHtml encodes special characters', () => {
  assert.equal(escapeHtml('<b>&"'), '&lt;b&gt;&amp;&quot;');
});

test('parseCsvString handles quoted commas', () => {
  const { headers, rows } = parseCsvString('name,qty\n"foo, bar",2\nx,1');
  assert.deepEqual(headers, ['name', 'qty']);
  assert.deepEqual(rows[0], ['foo, bar', '2']);
});

test('safeCssColor accepts hex only', () => {
  assert.equal(safeCssColor('#abc'), '#abc');
  assert.equal(safeCssColor('red'), '#5E2E14');
});

test('initials from name', () => {
  assert.equal(initials('Ada Lovelace'), 'AL');
  assert.equal(initials(''), '?');
});

test('buildLanOrderTrackingUrl includes token query', () => {
  const order = { id: 'O-1' };
  const url = buildLanOrderTrackingUrl('http://127.0.0.1:3219/', order);
  assert.match(url, /^http:\/\/127\.0\.0\.1:3219\/order\/O-1\?token=[0-9a-f]{32}$/);
});

test('buildLanQuoteApprovalUrl includes token query', () => {
  const order = { id: 'Q-1', status: 'quote' };
  const url = buildLanQuoteApprovalUrl('http://127.0.0.1:3219', order);
  assert.match(url, /^http:\/\/127\.0\.0\.1:3219\/order\/Q-1\/quote\?token=[0-9a-f]{32}$/);
});

/**
 * copyText decides whether "✓ Copied" is the truth. Every copy button in the
 * app used to assume success, which is how a permission the app never granted
 * turned into ~25 buttons that copied nothing and said they had.
 *
 * These drive the branch selection; the E2E smoke proves the real clipboard.
 */
function withGlobals(patch, fn) {
  // defineProperty, not assignment: globalThis.navigator is getter-only in Node,
  // so `globalThis.navigator = {...}` throws instead of stubbing.
  const saved = Object.keys(patch).map((k) => [k, Object.getOwnPropertyDescriptor(globalThis, k)]);
  for (const [k, v] of Object.entries(patch)) {
    Object.defineProperty(globalThis, k, { value: v, writable: true, configurable: true });
  }
  return (async () => fn())().finally(() => {
    for (const [k, desc] of saved) {
      if (desc) Object.defineProperty(globalThis, k, desc);
      else delete globalThis[k];
    }
  });
}

test('copyText prefers the main process and reports success', async () => {
  const seen = [];
  const ok = await withGlobals({
    hubAPI: { clipboardWrite: async (s) => { seen.push(s); return { ok: true }; } },
    navigator: { clipboard: { writeText: async () => { throw new Error('must not be reached'); } } },
  }, () => copyText('https://example.test/import/shopify'));
  assert.equal(ok, true);
  assert.deepEqual(seen, ['https://example.test/import/shopify']);
});

test('copyText falls back to the web API when there is no main process', async () => {
  const seen = [];
  const ok = await withGlobals({
    hubAPI: undefined,
    navigator: { clipboard: { writeText: async (s) => { seen.push(s); } } },
  }, () => copyText('fallback'));
  assert.equal(ok, true);
  assert.deepEqual(seen, ['fallback']);
});

test('copyText falls back when the main process reports failure', async () => {
  const seen = [];
  const ok = await withGlobals({
    hubAPI: { clipboardWrite: async () => ({ ok: false }) },
    navigator: { clipboard: { writeText: async (s) => { seen.push(s); } } },
  }, () => copyText('second-chance'));
  assert.equal(ok, true);
  assert.deepEqual(seen, ['second-chance']);
});

test('copyText reports false when both paths fail — it never throws', async () => {
  const ok = await withGlobals({
    hubAPI: { clipboardWrite: async () => { throw new Error('ipc down'); } },
    navigator: { clipboard: { writeText: async () => { throw new Error('NotAllowedError'); } } },
  }, () => copyText('nowhere'));
  assert.equal(ok, false);
});

test('copyText reports false when there is no clipboard at all', async () => {
  const ok = await withGlobals({ hubAPI: undefined, navigator: {} }, () => copyText('nothing'));
  assert.equal(ok, false);
});

test('copyText refuses empty text rather than wiping the clipboard', async () => {
  let called = false;
  for (const empty of ['', null, undefined]) {
    const ok = await withGlobals({
      hubAPI: { clipboardWrite: async () => { called = true; return { ok: true }; } },
    }, () => copyText(empty));
    assert.equal(ok, false, `${JSON.stringify(empty)} should not copy`);
  }
  assert.equal(called, false, 'nothing should have been written');
});
