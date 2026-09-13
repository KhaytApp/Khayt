'use strict';
(function () {

/**
 * Integrations registry — the curated top-3 storefronts + top-3 payment systems
 * for each market Khayt is translated into. Single source of truth driving the
 * Settings → Integrations directory, the inbound import mappers, and the payment
 * options. Pure data + lookups (no DOM/globals) so it's unit-testable.
 *
 * `dir` on a storefront = supported directions: 'in' (import orders), 'out'
 * (publish catalog). `webhook:true` means it can POST orders to Khayt's inbound
 * endpoint. Payment entries carry a site for the owner to get their pay link/key.
 *
 * `setup:'subscriber'` means the platform CAN post orders but has no webhook UI
 * to paste a URL into — the shop installs a few lines of code instead. Handing
 * such a shop only a "Copy import link" button is handing them a URL with
 * nowhere to put it, so the directory offers the code too. Medusa is the first
 * of these and, being self-hosted, appears in every market rather than one.
 */

const MARKETS = {
  ar: { country: { en: 'Saudi Arabia & Gulf', ar: 'السعودية والخليج' },
    storefronts: [
      { id: 'salla',      name: 'Salla',       dir: ['in', 'out'], webhook: true },
      { id: 'zid',        name: 'Zid',         dir: ['in', 'out'], webhook: true },
      { id: 'shopify',    name: 'Shopify',     dir: ['in', 'out'], webhook: true },
      { id: 'wuilt',      name: 'Wuilt',       dir: ['in', 'out'], webhook: true },
      { id: 'expandcart', name: 'ExpandCart',  dir: ['in', 'out'], webhook: true },
      { id: 'medusa',     name: 'Medusa',      dir: ['in'],        webhook: true, setup: 'subscriber' },
    ],
    payments: [
      { id: 'mada',    name: 'Mada' },
      { id: 'stcpay',  name: 'STC Pay' },
      { id: 'tabby',   name: 'Tabby' },
      { id: 'tamara',  name: 'Tamara' },
      { id: 'paytabs', name: 'PayTabs' },
    ] },
  en: { country: { en: 'United States & Global', ar: 'الولايات المتحدة وعالمياً' },
    storefronts: [
      { id: 'shopify',     name: 'Shopify',     dir: ['in', 'out'], webhook: true },
      { id: 'woocommerce', name: 'WooCommerce', dir: ['in', 'out'], webhook: true },
      { id: 'etsy',        name: 'Etsy',        dir: ['in', 'out'], webhook: true },
      { id: 'bigcommerce', name: 'BigCommerce', dir: ['in', 'out'], webhook: true },
      { id: 'wix',         name: 'Wix',         dir: ['in', 'out'], webhook: true },
      { id: 'medusa',     name: 'Medusa',      dir: ['in'],        webhook: true, setup: 'subscriber' },
    ],
    payments: [
      { id: 'stripe',    name: 'Stripe' },
      { id: 'paypal',    name: 'PayPal' },
      { id: 'square',    name: 'Square' },
      { id: 'applepay',  name: 'Apple Pay' },
      { id: 'googlepay', name: 'Google Pay' },
    ] },
  es: { country: { en: 'Spain', ar: 'إسبانيا' },
    storefronts: [
      { id: 'shopify',     name: 'Shopify',     dir: ['in', 'out'], webhook: true },
      { id: 'woocommerce', name: 'WooCommerce', dir: ['in', 'out'], webhook: true },
      { id: 'prestashop',  name: 'PrestaShop',  dir: ['in', 'out'], webhook: true },
      { id: 'wix',         name: 'Wix',         dir: ['in', 'out'], webhook: true },
      { id: 'bigcommerce', name: 'BigCommerce', dir: ['in', 'out'], webhook: true },
      { id: 'medusa',     name: 'Medusa',      dir: ['in'],        webhook: true, setup: 'subscriber' },
    ],
    payments: [
      { id: 'stripe', name: 'Stripe' },
      { id: 'paypal', name: 'PayPal' },
      { id: 'bizum',  name: 'Bizum' },
      { id: 'redsys', name: 'Redsys' },
      { id: 'klarna', name: 'Klarna' },
    ] },
  fr: { country: { en: 'France', ar: 'فرنسا' },
    storefronts: [
      { id: 'shopify',     name: 'Shopify',     dir: ['in', 'out'], webhook: true },
      { id: 'woocommerce', name: 'WooCommerce', dir: ['in', 'out'], webhook: true },
      { id: 'prestashop',  name: 'PrestaShop',  dir: ['in', 'out'], webhook: true },
      { id: 'wix',         name: 'Wix',         dir: ['in', 'out'], webhook: true },
      { id: 'bigcommerce', name: 'BigCommerce', dir: ['in', 'out'], webhook: true },
      { id: 'medusa',     name: 'Medusa',      dir: ['in'],        webhook: true, setup: 'subscriber' },
    ],
    payments: [
      { id: 'stripe',  name: 'Stripe' },
      { id: 'paypal',  name: 'PayPal' },
      { id: 'payplug', name: 'PayPlug' },
      { id: 'lydia',   name: 'Lydia' },
      { id: 'klarna',  name: 'Klarna' },
    ] },
  de: { country: { en: 'Germany', ar: 'ألمانيا' },
    storefronts: [
      { id: 'shopify',     name: 'Shopify',     dir: ['in', 'out'], webhook: true },
      { id: 'woocommerce', name: 'WooCommerce', dir: ['in', 'out'], webhook: true },
      { id: 'shopware',    name: 'Shopware',    dir: ['in', 'out'], webhook: true },
      { id: 'wix',         name: 'Wix',         dir: ['in', 'out'], webhook: true },
      { id: 'etsy',        name: 'Etsy',        dir: ['in', 'out'], webhook: true },
      { id: 'medusa',     name: 'Medusa',      dir: ['in'],        webhook: true, setup: 'subscriber' },
    ],
    payments: [
      { id: 'paypal',  name: 'PayPal' },
      { id: 'klarna',  name: 'Klarna' },
      { id: 'stripe',  name: 'Stripe' },
      { id: 'giropay', name: 'giropay' },
      { id: 'sofort',  name: 'SOFORT' },
    ] },
  ja: { country: { en: 'Japan', ar: 'اليابان' },
    storefronts: [
      { id: 'shopify',  name: 'Shopify',  dir: ['in', 'out'], webhook: true },
      { id: 'base',     name: 'BASE',     dir: ['in', 'out'], webhook: true },
      { id: 'rakuten',  name: 'Rakuten',  dir: ['in'],        webhook: true },
      { id: 'stores',   name: 'STORES',   dir: ['in', 'out'], webhook: true },
      { id: 'makeshop', name: 'MakeShop', dir: ['in', 'out'], webhook: true },
      { id: 'medusa',     name: 'Medusa',      dir: ['in'],        webhook: true, setup: 'subscriber' },
    ],
    payments: [
      { id: 'paypay',     name: 'PayPay' },
      { id: 'rakutenpay', name: 'Rakuten Pay' },
      { id: 'stripe',     name: 'Stripe' },
      { id: 'linepay',    name: 'LINE Pay' },
      { id: 'merpay',     name: 'Merpay' },
    ] },
  zh: { country: { en: 'China', ar: 'الصين' },
    storefronts: [
      { id: 'taobao',    name: 'Taobao / Tmall',  dir: ['in'],        webhook: true },
      { id: 'jd',        name: 'JD.com',          dir: ['in'],        webhook: true },
      { id: 'youzan',    name: 'Youzan (WeChat)', dir: ['in', 'out'], webhook: true },
      { id: 'pinduoduo', name: 'Pinduoduo',       dir: ['in'],        webhook: true },
      { id: 'weidian',   name: 'Weidian',         dir: ['in', 'out'], webhook: true },
      { id: 'medusa',     name: 'Medusa',      dir: ['in'],        webhook: true, setup: 'subscriber' },
    ],
    payments: [
      { id: 'alipay',    name: 'Alipay' },
      { id: 'wechatpay', name: 'WeChat Pay' },
      { id: 'unionpay',  name: 'UnionPay' },
      { id: 'jdpay',     name: 'JD Pay' },
      { id: 'qqpay',     name: 'QQ Pay' },
    ] },
};

/** Registry for a locale (falls back to 'en'). */
function forLocale(locale) { return MARKETS[locale] || MARKETS.en; }

/** All known storefront platform ids (deduped, for the inbound import router). */
function allStorefrontIds() {
  const s = new Set();
  for (const m of Object.values(MARKETS)) for (const sf of m.storefronts) s.add(sf.id);
  return [...s];
}

/** All known payment provider ids (deduped). */
function allPaymentIds() {
  const s = new Set();
  for (const m of Object.values(MARKETS)) for (const p of m.payments) s.add(p.id);
  return [...s];
}

/* ── THE TWO LINKS A SHOP PASTES INTO ITS STORE ──────────────────────────────
 *
 * These were built inline in `renderer/settings.js`, which was fine while one
 * app drew the directory. They are a cloud ROUTE SHAPE, and a route shape
 * written down in two places is one that can disagree: spell it differently and
 * the shop pastes a URL the cloud does not serve, gets no orders, and gets no
 * error either — the store reports a successful webhook delivery to a 404.
 *
 * The base is trimmed of trailing slashes because a shop types its cloud URL by
 * hand and "https://cloud.example.com/" is what a browser's address bar hands
 * over. `//v1/shops/...` is a different path.
 */
function cloudBase(url) { return String(url || '').replace(/\/+$/, ''); }

/** Where a storefront POSTs new orders. */
function importUrl(url, shopId, platformId) {
  return `${cloudBase(url)}/v1/shops/${shopId}/import/${platformId}`;
}

/** Where a storefront reads the shop's published catalogue. */
function feedUrl(url, shopId, platformId) {
  return `${cloudBase(url)}/v1/shops/${shopId}/feed/${platformId}`;
}

/** Look up a storefront platform by id across all markets. */
function storefront(id) {
  for (const m of Object.values(MARKETS)) { const f = m.storefronts.find((x) => x.id === id); if (f) return f; }
  return null;
}

const api = { MARKETS, forLocale, allStorefrontIds, allPaymentIds, storefront,
  cloudBase, importUrl, feedUrl };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytIntegrations = api;

})();
