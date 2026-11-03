const { test } = require('node:test');
const assert = require('node:assert/strict');

const reg = require('../renderer/themes/registry-core.js');

test('normalizeDesignId falls stale ids back to the default', () => {
  // The default is Khayt, the 2026 identity, since Nov 2026 (it was Workbench).
  assert.equal(reg.DEFAULT_DESIGN, 'khayt');
  assert.equal(reg.normalizeDesignId('classic'), 'khayt');
  assert.equal(reg.normalizeDesignId('unknown'), 'khayt');
  assert.equal(reg.normalizeDesignId(''), 'khayt');
  for (const gone of ['ledger', 'console', 'atelier', 'vitrine', 'cockpit', 'atlas']) {
    assert.equal(reg.normalizeDesignId(gone), 'khayt', `${gone} was deleted`);
  }
  // studio left with Bed Ready in 3.3 — it is not a Khayt design any more.
  assert.equal(reg.normalizeDesignId('studio'), 'khayt');
  // Workbench is still a design you can pick; it just is not the default.
  assert.equal(reg.normalizeDesignId('workbench'), 'workbench');
});

test('selectable themes are the three 2.6 designs plus the 3.4 additions', () => {
  // Blueprint and Nocturne join the 2.6 trio. They ship no shell of their own —
  // Blueprint rides Workbench, Nocturne rides Command — so this list growing is
  // the only registry-level signal that they exist and are pickable.
  const selectable = reg.listSelectableThemes();
  assert.deepEqual(selectable.filter((id) => !id.startsWith('custom:')).sort(),
    ['blueprint', 'command', 'flow', 'foreman', 'khayt', 'meridian', 'nocturne', 'vivid', 'workbench']);
});

test('the six deleted legacy designs are gone from the registry', () => {
  for (const gone of ['ledger', 'console', 'atelier', 'vitrine', 'cockpit', 'atlas']) {
    assert.equal(reg.BUILTIN_THEMES[gone], undefined, `${gone} should be deleted`);
    assert.equal(reg.registry[gone], undefined, `${gone} should be deleted`);
  }
});

test('studio is gone from Khayt entirely — Bed Ready owns its UI layer now', () => {
  // It used to survive here because Bed Ready was pinned to it. Bed Ready now
  // owns renderer/bedready/ and is identified by its html marker, so Khayt's
  // registry has no reason to carry it.
  assert.equal(reg.BUILTIN_THEMES.studio, undefined);
  assert.equal(reg.registry.studio, undefined);
  assert.equal(reg.STUDIO_ACCENTS, undefined);
  // Its accent table went with it; the fallback is the default theme's.
  assert.deepEqual(Object.keys(reg.accentsForTheme('nonsense')), Object.keys(reg.accentsForTheme('khayt')));
});

test('coming soon lists Frontier Pulse and Stream only', () => {
  const soon = reg.listComingSoonThemes();
  assert.ok(!soon.includes('console'));
  assert.ok(!soon.includes('atlas'));
  assert.ok(!soon.includes('cockpit'));
  assert.ok(soon.includes('pulse'));
  assert.ok(soon.includes('stream'));
});

test('the handoff-shell API is gone', () => {
  // khayt-handoff and khayt-studio were two body classes that could never
  // disagree once studio was the last handoff shell. Bed Ready sets one class
  // by product marker, so the registry no longer arbitrates it.
  assert.equal(reg.usesHandoffScreens, undefined);
  assert.equal(reg.HANDOFF_SCREEN_SHELLS, undefined);
});






test('each surviving theme has a default accent inside its own preset set', () => {
  for (const id of ['workbench', 'command', 'vivid', 'studio']) {
    const def = reg.defaultAccentForTheme(id);
    assert.ok(reg.accentsForTheme(id)[def], `${id} default accent ${def} missing from its set`);
  }
});

test('validateCustomManifest catches invalid ids', () => {
  const errors = reg.validateCustomManifest({ id: 'X', name: 'Bad' });
  assert.ok(errors.length > 0);
});

test('registerCustomTheme adds custom theme', () => {
  const result = reg.registerCustomTheme({
    id: 'test-shop',
    name: 'Test Shop',
    tokens: 'tokens.css',
    accents: { brand: { h: 200, s: '70%', l: '50%', label: 'Brand' } },
    // Was 'studio'. A custom theme adopting that shell would switch on
    // body.khayt-handoff for a Khayt user, re-activating Bed Ready's screen
    // layer through the back door — so custom themes now pick a Khayt shell.
    shell: 'workbench',
  });
  assert.equal(result.ok, true);
  assert.equal(reg.normalizeDesignId('custom:test-shop'), 'custom:test-shop');
  assert.equal(reg.defaultAccentForTheme('custom:test-shop'), 'brand');
});

test('validateCustomManifest rejects path traversal in stylesheet refs', () => {
  const base = { id: 'evil', name: 'Evil' };
  assert.ok(reg.validateCustomManifest({ ...base, tokens: '../../../etc/x.css' }).some((e) => /tokens/.test(e)));
  assert.ok(reg.validateCustomManifest({ ...base, tokens: 'ok.css', compat: 'a/b.css' }).some((e) => /compat/.test(e)));
  assert.ok(reg.validateCustomManifest({ ...base, tokens: 'ok.css', shellCss: '..\\win.css' }).some((e) => /shellCss/.test(e)));
  // A plain filename is accepted.
  assert.equal(reg.validateCustomManifest({ ...base, tokens: 'tokens.css' }).length, 0);
});

test('validateCustomManifest rejects malformed accents and bodyClass', () => {
  const base = { id: 'shop', name: 'Shop', tokens: 'tokens.css' };
  assert.ok(reg.validateCustomManifest({ ...base, accents: { x: { h: 999, s: '70%', l: '50%' } } }).some((e) => /h must/.test(e)));
  assert.ok(reg.validateCustomManifest({ ...base, accents: { x: { h: 200, s: 'red', l: '50%' } } }).some((e) => /s must/.test(e)));
  assert.ok(reg.validateCustomManifest({ ...base, bodyClass: 'a b" onload=x' }).some((e) => /bodyClass/.test(e)));
  // Valid accent (number or % forms) passes.
  assert.equal(reg.validateCustomManifest({ ...base, accents: { x: { h: 200, s: 70, l: '50%' } } }).length, 0);
});

test('custom manifests may only claim shells that still exist', () => {
  const base = { id: 'shop', name: 'Shop', tokens: 'tokens.css' };
  // Regression: 'ledger' was an accepted shell until the 3.3 legacy deletion
  // removed it — a manifest naming it validated clean and then rendered nothing.
  assert.ok(reg.validateCustomManifest({ ...base, shell: 'ledger' }).some((e) => /shell/.test(e)));
  // 'studio' is Bed Ready's shell, not a Khayt one.
  assert.ok(reg.validateCustomManifest({ ...base, shell: 'studio' }).some((e) => /shell/.test(e)));
  for (const shell of reg.CUSTOM_THEME_SHELLS) {
    assert.deepEqual(reg.validateCustomManifest({ ...base, shell }), [], `${shell} should be allowed`);
  }
});
