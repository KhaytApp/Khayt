/**
 * Integrations registry — top-3 storefronts + top-3 payments per translated market.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { MARKETS, forLocale, allStorefrontIds, allPaymentIds, storefront } = require('../lib/integrations-registry.js');

const LOCALES = ['ar', 'en', 'es', 'fr', 'de', 'ja', 'zh'];

test('every translated market has at least 3 storefronts + 3 payments', () => {
  for (const loc of LOCALES) {
    const m = MARKETS[loc];
    assert.ok(m, `market ${loc} exists`);
    assert.ok(m.storefronts.length >= 3, `${loc} storefronts`);
    assert.ok(m.payments.length >= 3, `${loc} payments`);
    assert.ok(m.country.en && m.country.ar, `${loc} country labels`);
    // ids unique within a market
    assert.equal(new Set(m.storefronts.map((s) => s.id)).size, m.storefronts.length, `${loc} storefront ids unique`);
    assert.equal(new Set(m.payments.map((p) => p.id)).size, m.payments.length, `${loc} payment ids unique`);
  }
});

test('entries are well-formed (id + name; storefront dir is in/out)', () => {
  for (const m of Object.values(MARKETS)) {
    for (const sf of m.storefronts) {
      assert.ok(sf.id && sf.name, 'storefront id+name');
      assert.ok(Array.isArray(sf.dir) && sf.dir.every((d) => d === 'in' || d === 'out'));
    }
    for (const p of m.payments) assert.ok(p.id && p.name, 'payment id+name');
  }
});

test('forLocale falls back to en for unknown locales', () => {
  assert.equal(forLocale('en'), forLocale('xx'));
  assert.equal(forLocale('ar').country.en, 'Saudi Arabia & Gulf');
});

test('id lookups', () => {
  assert.ok(allStorefrontIds().includes('shopify'));
  assert.ok(allPaymentIds().includes('alipay'));
  assert.equal(storefront('salla').name, 'Salla');
  assert.equal(storefront('nope'), null);
});

const R = require('../lib/integrations-registry.js');

// ── WHICH MARKET A SHOP OPENS ON ───────────────────────────────────────────
//
// The directory opened on the interface LANGUAGE, and that is a different
// question from where the shop sells. A Riyadh shop running Khayt in English
// was shown the United States market — Shopify and Stripe rather than Salla,
// Zid, Mada, STC Pay and Tabby — while its own book said `country: 'SA'`, its
// currency was SAR and its invoices carried a ZATCA QR.

test('a shop is placed by where it sells, not by what it reads', () => {
  for (const language of ['en', 'ar', 'fr', 'zh', '']) {
    assert.equal(R.marketFor({ country: 'SA', language }), 'ar',
      `a Saudi shop reading ${language || '(nothing)'} is still a Saudi shop`);
  }
  assert.equal(R.marketFor({ country: 'US', language: 'ar' }), 'en');
  assert.equal(R.marketFor({ country: 'DE', language: 'en' }), 'de');
});

test('every Gulf state the market names is one it covers', () => {
  // The market calls itself "Saudi Arabia & Gulf". These are the six.
  for (const code of ['SA', 'AE', 'KW', 'QA', 'BH', 'OM']) {
    assert.equal(R.marketFor({ country: code, language: 'en' }), 'ar', code);
  }
});

test('the country is read however it is written', () => {
  for (const written of ['sa', 'SA', ' sa ', 'Sa']) {
    assert.equal(R.marketFor({ country: written, language: 'en' }), 'ar',
      JSON.stringify(written));
  }
});

test('a shop that has not said where it is falls back to its language', () => {
  // Which is exactly what the directory did for everyone before, so no shop
  // is moved by this except one that had already said where it was.
  assert.equal(R.marketFor({ language: 'fr' }), 'fr');
  assert.equal(R.marketFor({ country: '', language: 'ja' }), 'ja');
  // A country nobody has curated a market for changes nothing.
  assert.equal(R.marketFor({ country: 'EG', language: 'ar' }), 'ar');
  assert.equal(R.marketFor({ country: 'BR', language: 'en' }), 'en');
});

test('nonsense lands on a real market rather than an empty screen', () => {
  assert.equal(R.marketFor(), 'en');
  assert.equal(R.marketFor({}), 'en');
  assert.equal(R.marketFor({ country: null, language: null }), 'en');
  assert.equal(R.marketFor({ country: 'ZZ', language: 'xx' }), 'en');
  assert.equal(R.marketFor({ country: 42, language: {} }), 'en');
});

test('every market a country points at is one the registry has', () => {
  for (const [code, market] of Object.entries(R.MARKET_BY_COUNTRY)) {
    assert.ok(R.MARKETS[market], `${code} points at '${market}', which is not a market`);
  }
});

// ── AND FOR A SHOP THAT NEVER SAID WHERE IT IS ─────────────────────────────
//
// Plenty never fill the country in — this shop's own book has it blank while
// pricing in riyals with a ZATCA QR on its invoices, which is not ambiguous
// about which storefronts to offer.

test('a shop with no country is placed by what it charges in', () => {
  assert.equal(R.marketFor({ currency: 'SAR', language: 'en' }), 'ar');
  assert.equal(R.marketFor({ currency: 'JPY', language: 'en' }), 'ja');
  assert.equal(R.marketFor({ currency: 'sar', language: 'en' }), 'ar', 'however it is written');
});

test('a country that is known still wins over the currency', () => {
  // A German shop invoicing an American customer in dollars is still German.
  assert.equal(R.marketFor({ country: 'DE', currency: 'USD', language: 'en' }), 'de');
  assert.equal(R.marketFor({ country: 'US', currency: 'SAR', language: 'ar' }), 'en');
});

test('the euro says nothing, and is not made to', () => {
  // Spain, France and Germany all use it, so it cannot pick between them —
  // and guessing one would be worse than the language the shop actually reads.
  assert.equal(R.marketFor({ currency: 'EUR', language: 'fr' }), 'fr');
  assert.equal(R.marketFor({ currency: 'EUR', language: 'de' }), 'de');
  assert.equal(R.marketFor({ currency: 'EUR', language: 'en' }), 'en');
  // Sterling has no market of its own at all.
  assert.equal(R.marketFor({ currency: 'GBP', language: 'en' }), 'en');
});

test('every market a currency points at is one the registry has', () => {
  for (const [code, market] of Object.entries(R.MARKET_BY_CURRENCY)) {
    assert.ok(R.MARKETS[market], `${code} points at '${market}', which is not a market`);
  }
});
