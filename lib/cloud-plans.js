'use strict';
(function () {

/**
 * Khayt Cloud plans — the app's copy of what each tier costs and includes.
 * The live definitions (prices and the limits the server enforces) are the
 * cloud's GET /v1/plans; this file must match it, and the website's data.js
 * mirrors this file. The ladder is Turki's of 2026-10-24 (Free / Maker /
 * Creator / Studio; it replaced Cloud and Branches). List only what is true:
 * no history or device limits here, because the server enforces none.
 *
 * Not to be confused with lib/feature-tiers.js. That gates LOCAL features by mode
 * (simple / professional / enthusiast) and has nothing to do with money — the
 * desktop stays 100% functional with no account, forever. This file describes
 * only the hosted service, which is the sole thing Khayt charges for.
 *
 * ── Free during beta ────────────────────────────────────────────────────────
 *
 * BETA_FREE is the switch. While it is true, every tier costs nothing and the UI
 * shows each price struck through next to "Free during beta". The prices are
 * real and are what the tiers will cost; they are shown now so that nobody
 * discovers a price later, having built their shop on the assumption there was
 * not one. Flipping it to false is a deliberate act — the same shape as
 * COMPRESS_ON_WRITE in lib/sync-crypto.js — and it must not be flipped before
 * payment collection exists, because a tier that says "$9/mo" while nothing can
 * charge for it is a promise the product cannot keep in either direction.
 *
 * Pure (no DOM/globals) so it can be unit-tested and reused.
 */

/** While true: nothing is charged, and every price renders struck through. */
const BETA_FREE = true;

/**
 * SAR is pegged to USD at 3.75, so these are not conversions that drift — they
 * are the same price expressed twice. USD is SAR ÷ 3.75 rounded UP
 * (25 → 6.67 → 7, 65 → 17.33 → 18), so the USD price is never the cheaper one.
 *
 * No other currency is listed on purpose. Anything not pegged would be a rate
 * snapshot that silently goes stale, and a wrong price is worse than a foreign
 * one — so every other locale sees USD, which is at least true.
 */
const PLANS = [
  {
    id: 'free',
    label: { en: 'Free', ar: 'مجاني' },
    price: { USD: 0, SAR: 0 },
    annual: { USD: 0, SAR: 0 },
    tagline: {
      en: 'The whole app, forever, with no account.',
      ar: 'التطبيق كامل، للأبد، بدون حساب.',
    },
    features: [
      { key: 'localApp',   label: { en: 'Local app, LAN and BYO-key AI — everything', ar: 'التطبيق المحلي والشبكة والذكاء الاصطناعي بمفتاحك — كل شيء' } },
      { key: 'syncBackup', label: { en: 'With a free account: encrypted sync and off-site backup', ar: 'بحساب مجاني: مزامنة مشفّرة ونسخة احتياطية خارجية' } },
      { key: 'portal30',   label: { en: 'Customer portal — 30-day trial once the beta ends', ar: 'بوابة العملاء — تجربة 30 يوماً بعد انتهاء التجربة العامة' } },
      { key: 'vault2',     label: { en: 'Khayt Vault — 2 GB, no share links', ar: 'خزنة خيط — 2 غيغابايت، بلا روابط مشاركة' } },
    ],
  },
  {
    id: 'maker',
    label: { en: 'Maker', ar: 'الصانع' },
    price: { USD: 7, SAR: 25 },
    annual: { USD: 70, SAR: 250 },
    tagline: {
      en: 'Your shop visible to your customers, and room for your files.',
      ar: 'متجرك ظاهر لعملائك، ومساحة لملفاتك.',
    },
    features: [
      { key: 'everything', label: { en: 'Everything in Free', ar: 'كل ما في المجانية' } },
      { key: 'portal',     label: { en: 'Customer portal and online storefront, with no time limit', ar: 'بوابة العملاء والمتجر الإلكتروني، بلا حدّ زمني' } },
      { key: 'team3',      label: { en: 'Team accounts — up to 3 people', ar: 'حسابات الفريق — حتى 3 أشخاص' } },
      { key: 'vault150',   label: { en: 'Khayt Vault — 150 GB, 50 share links', ar: 'خزنة خيط — 150 غيغابايت، 50 رابط مشاركة' } },
    ],
  },
  {
    id: 'creator',
    label: { en: 'Creator', ar: 'المبدع' },
    price: { USD: 18, SAR: 65 },
    annual: { USD: 180, SAR: 650 },
    tagline: {
      en: 'Everything in Maker, and sell your files.',
      ar: 'كل ما في الصانع، وبِع ملفاتك.',
    },
    features: [
      { key: 'everything', label: { en: 'Everything in Maker', ar: 'كل ما في الصانع' } },
      { key: 'selling',    label: { en: 'Sell files through makerrun.com, paid at your own checkout', ar: 'بيع الملفات عبر makerrun.com، والدفع عبر صفحة الدفع الخاصة بك' } },
      { key: 'vault400',   label: { en: 'Khayt Vault — 400 GB, 200 share links', ar: 'خزنة خيط — 400 غيغابايت، 200 رابط مشاركة' } },
    ],
  },
  {
    id: 'studio',
    label: { en: 'Studio', ar: 'الاستوديو' },
    price: { USD: 48, SAR: 180 },
    annual: { USD: 480, SAR: 1800 },
    tagline: {
      en: 'For a bigger team and a bigger library.',
      ar: 'لفريق أكبر ومكتبة أكبر.',
    },
    features: [
      { key: 'everything', label: { en: 'Everything in Creator', ar: 'كل ما في المبدع' } },
      { key: 'team5',      label: { en: 'Team accounts — up to 5 people', ar: 'حسابات الفريق — حتى 5 أشخاص' } },
      { key: 'vault1tb',   label: { en: 'Khayt Vault — 1 TB, 1,000 share links', ar: 'خزنة خيط — 1 تيرابايت، 1,000 رابط مشاركة' } },
    ],
  },
];

/** Currencies with a real listed price. Everything else is shown in USD. */
const CURRENCIES = ['USD', 'SAR'];

/** Normalize a shop's configured currency to one this file actually prices. */
function priceCurrency(currency) {
  const c = String(currency || '').toUpperCase();
  return CURRENCIES.includes(c) ? c : 'USD';
}

/** Is billing switched off for everyone right now? */
function isBetaFree() { return BETA_FREE; }

/** All plans, in ladder order. */
function allPlans() { return PLANS; }

/** One plan by id, or undefined. */
function planById(id) { return PLANS.find((p) => p.id === id); }

/**
 * What a plan costs, and how to render it.
 *
 * Returns `amount`/`currency` (the real price, always — the figure does not
 * become 0 during beta, it becomes struck through) plus:
 *   free      — this tier costs nothing even after beta
 *   charged   — whether this amount is being collected TODAY
 *   strike    — render `amount` with a line through it
 *
 * The distinction between `free` and `!charged` is the one that matters: the
 * Free tier is free forever, a paid tier is merely not being charged yet.
 */
function planPrice(id, currency, opts) {
  const plan = planById(id);
  if (!plan) return null;
  const betaFree = (opts && typeof opts.betaFree === 'boolean') ? opts.betaFree : BETA_FREE;
  const cur = priceCurrency(currency);
  const amount = plan.price[cur];
  const free = amount === 0;
  return {
    id,
    currency: cur,
    amount,
    annual: plan.annual[cur],
    free,
    charged: !free && !betaFree,
    strike: !free && betaFree,
  };
}

/**
 * Localized rows for the plan-comparison UI.
 * `lang` falls back to English per key, so a partially translated bundle still
 * renders a complete table rather than blanks.
 */
function planComparison(lang, currency, opts) {
  const L = (o) => (o && (o[lang] || o.en)) || '';
  return PLANS.map((p) => ({
    id: p.id,
    label: L(p.label),
    tagline: L(p.tagline),
    soon: !!p.soon,
    price: planPrice(p.id, currency, opts),
    features: p.features.map((f) => ({ key: f.key, label: L(f.label) })),
  }));
}

const api = { BETA_FREE, PLANS, CURRENCIES, isBetaFree, allPlans, planById, planPrice, planComparison, priceCurrency };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytCloudPlans = api;

})();
