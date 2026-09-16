/**
 * Feature tiers — the Enthusiast/Simple/Professional single source of truth.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  PRO_FEATURES, SIMPLE_CORE, BUSINESS_FEATURES,
  isProMode, isEnthusiast, showsBusiness, isFeatureEnabled, tierComparison,
} = require('../lib/feature-tiers.js');

test('isProMode: professional only (simple + enthusiast are not pro)', () => {
  assert.equal(isProMode('professional'), true);
  assert.equal(isProMode(undefined), true); // default mode is professional
  assert.equal(isProMode('simple'), false);
  assert.equal(isProMode('enthusiast'), false);
});

test('isEnthusiast + showsBusiness', () => {
  assert.equal(isEnthusiast('enthusiast'), true);
  assert.equal(isEnthusiast('simple'), false);
  assert.equal(showsBusiness('enthusiast'), false);
  assert.equal(showsBusiness('simple'), true);
  assert.equal(showsBusiness('professional'), true);
  assert.equal(showsBusiness(undefined), true);
});

test('isFeatureEnabled: pro gated by mode, business gated by enthusiast, core always on', () => {
  assert.equal(isFeatureEnabled('zatca', 'simple'), false);       // pro
  assert.equal(isFeatureEnabled('zatca', 'professional'), true);
  assert.equal(isFeatureEnabled('clients', 'simple'), true);      // business — on in simple
  assert.equal(isFeatureEnabled('clients', 'enthusiast'), false); // business — hidden for enthusiast
  assert.equal(isFeatureEnabled('quote', 'enthusiast'), true);    // core
  assert.equal(isFeatureEnabled('printFiles', 'enthusiast'), true); // core (personal library)
  assert.equal(isFeatureEnabled('colorMix', 'enthusiast'), true);   // core (colour mixer)
  assert.equal(isFeatureEnabled('unknownFeature', 'enthusiast'), true); // unknown = core
});

test('colorMix is a personal-core feature (present in SIMPLE_CORE, on in every mode)', () => {
  assert.ok(SIMPLE_CORE.some((f) => f.key === 'colorMix'), 'colorMix is core');
  assert.equal(isFeatureEnabled('colorMix', 'simple'), true);
  assert.equal(isFeatureEnabled('colorMix', 'professional'), true);
});

test('registries are non-empty and disjoint by key', () => {
  assert.ok(PRO_FEATURES.length >= 5 && SIMPLE_CORE.length >= 3 && BUSINESS_FEATURES.length >= 3);
  const proKeys = new Set(PRO_FEATURES.map((f) => f.key));
  const bizKeys = new Set(BUSINESS_FEATURES.map((f) => f.key));
  assert.ok(!SIMPLE_CORE.some((f) => proKeys.has(f.key) || bizKeys.has(f.key)), 'core keys are distinct');
  assert.ok(!BUSINESS_FEATURES.some((f) => proKeys.has(f.key)), 'business keys are not pro');
});

test('tierComparison returns three localized columns (en/ar)', () => {
  const en = tierComparison('en');
  assert.equal(en.enthusiast.length, SIMPLE_CORE.length);
  assert.equal(en.simple.length, BUSINESS_FEATURES.length);
  assert.equal(en.pro.length, PRO_FEATURES.length);
  assert.ok(en.pro[0].label.length > 0);
  const ar = tierComparison('ar');
  assert.notEqual(ar.pro[0].label, en.pro[0].label); // actually translated
});

/**
 * ── THE REGISTRY MUST NAME WHAT IT GOVERNS ─────────────────────────────────
 *
 * This file calls itself the single source of truth for the mode boundary and
 * it drives `tierComparison`, which is the table a shop reads when choosing a
 * mode. Two navigation tabs — the catalogue and the portfolio — carried
 * `.biz-only` in `renderer/index.html` and appeared in no list here, so the
 * comparison was short of two things the shop actually gets.
 *
 * Nothing caught that, because the gating lives in a CSS class and the
 * registry is a separate list. This is the join.
 */
test('every gated nav tab maps to a feature the registry names', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');

  // tab id → registry key. A tab whose id is not the key needs a line here,
  // and a gated tab with no line at all fails below.
  const KEY_OF = {
    'analytics-tab': 'analytics',
    'catalog-tab': 'catalog',
    'clients-tab': 'clients',
    'gift-cards-tab': 'giftCards',
    'logs-tab': 'orders',
    'portfolio-tab': 'portfolio',
    'expenses-tab': 'expenses',
  };
  const known = new Set([
    ...SIMPLE_CORE.map((f) => f.key),
    ...BUSINESS_FEATURES.map((f) => f.key),
    ...PRO_FEATURES.map((f) => f.key),
  ]);

  const gated = [...html.matchAll(/class="tab-btn khayt-navitem (biz-only|pro-only)" data-tab="([a-z-]+)"/g)]
    .map((m) => ({ gate: m[1], tab: m[2] }));
  assert.ok(gated.length >= 7, `only found ${gated.length} gated tabs — the markup has moved`);

  for (const { gate, tab } of gated) {
    const key = KEY_OF[tab];
    assert.ok(key, `${tab} is gated ${gate} and this test has no key for it`);
    assert.ok(known.has(key), `${tab} is gated ${gate} but "${key}" is in no tier list`);
    // ── WHAT THE TWO GATES ACTUALLY MEAN ────────────────────────────────
    //
    // A `pro-only` TAB is Professional whole: the expenses tab carries the
    // class itself and holds no pro-only element inside it.
    //
    // A `biz-only` tab may still be a Pro FEATURE when what Professional
    // unlocks is the DEPTH rather than the tab. Analytics is exactly that —
    // the tab opens for a simple shop and fourteen elements inside it are
    // pro-only, which is why the registry calls the feature "Full analytics
    // & forecasting" and not "Analytics". So the requirement is that such a
    // tab really does gate something inside, not that the classes match.
    const isPro = PRO_FEATURES.some((f) => f.key === key);
    if (gate === 'pro-only') {
      assert.ok(isPro, `${tab} is marked pro-only but "${key}" is not in PRO_FEATURES`);
    } else if (isPro) {
      const body = html.slice(html.indexOf(`id="${tab}"`));
      const section = body.slice(0, body.indexOf('</section>'));
      assert.ok(section.includes('pro-only'),
        `${tab} is only biz-only, yet "${key}" is a Pro feature and nothing inside the tab is gated — `
        + 'a simple shop would get the whole of it');
    }
  }
});

test('the catalogue and the portfolio are business features, not Pro ones', () => {
  for (const key of ['catalog', 'portfolio']) {
    assert.equal(isFeatureEnabled(key, 'simple'), true, key + ' is hidden from a simple shop');
    assert.equal(isFeatureEnabled(key, 'professional'), true);
    // Bed Ready is commerce-free, and both of these are commerce.
    assert.equal(isFeatureEnabled(key, 'enthusiast'), false, key + ' reached an enthusiast');
  }
});
