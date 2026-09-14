'use strict';
(function () {

/**
 * Khayt Cloud plans — the SINGLE SOURCE OF TRUTH for what a cloud tier costs and
 * what it includes. Figures and reasoning: docs/KHAYT-CLOUD-FEATURES-AND-PRICING.md §4,
 * costed against measured hosting in docs/KHAYT-CLOUD-COST-PER-SHOP.md.
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
 * are the same price expressed twice. They are rounded UP (33.75 → 35,
 * 108.75 → 109) rather than to the nearest, because a price ending in 5 or 9
 * reads as a price and one ending in 4 reads as a leftover conversion.
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
      { key: 'localApp',  label: { en: 'Local app, LAN and BYO-key AI — everything', ar: 'التطبيق المحلي والشبكة والذكاء الاصطناعي بمفتاحك — كل شيء' } },
      { key: 'backup1',   label: { en: 'Off-site encrypted backup — 1 device', ar: 'نسخة احتياطية مشفّرة خارجية — جهاز واحد' } },
      { key: 'portal30',  label: { en: 'Customer portal — 30-day trial', ar: 'بوابة العملاء — تجربة 30 يوماً' } },
      { key: 'history7',  label: { en: '7 days of snapshot history', ar: 'سجل نسخ لمدة 7 أيام' } },
    ],
  },
  {
    id: 'cloud',
    label: { en: 'Cloud', ar: 'السحابة' },
    price: { USD: 9, SAR: 35 },
    annual: { USD: 90, SAR: 350 },
    tagline: {
      en: 'Your shop on every device, and visible to your customers.',
      ar: 'متجرك على كل جهاز، وظاهر لعملائك.',
    },
    features: [
      { key: 'syncAll',   label: { en: 'Encrypted sync across all your devices', ar: 'مزامنة مشفّرة عبر كل أجهزتك' } },
      { key: 'portal',    label: { en: 'Customer portal and online storefront', ar: 'بوابة العملاء والمتجر الإلكتروني' } },
      { key: 'team3',     label: { en: 'Team accounts — up to 3 people', ar: 'حسابات الفريق — حتى 3 أشخاص' } },
      { key: 'history90', label: { en: '90 days of snapshot history', ar: 'سجل نسخ لمدة 90 يوماً' } },
    ],
  },
  {
    id: 'branches',
    label: { en: 'Branches', ar: 'الفروع' },
    price: { USD: 29, SAR: 109 },
    annual: { USD: 290, SAR: 1090 },
    // Phase 3 is not built (docs/KHAYT-3.0-CLOUD-STATUS.md). The tier is listed
    // so the ladder is legible, and `soon` keeps the UI from implying otherwise
    // — announcing a price for something unbuilt is only honest if it says so.
    soon: true,
    tagline: {
      en: 'One owner, several branches, one set of numbers.',
      ar: 'مالك واحد، عدة فروع، أرقام موحّدة.',
    },
    features: [
      { key: 'everything', label: { en: 'Everything in Cloud', ar: 'كل ما في السحابة' } },
      { key: 'multiShop',  label: { en: 'Multiple branches with an HQ dashboard', ar: 'فروع متعددة مع لوحة تحكم رئيسية' } },
      { key: 'team10',     label: { en: 'Team accounts — up to 10 people', ar: 'حسابات الفريق — حتى 10 أشخاص' } },
      { key: 'sharedInv',  label: { en: 'Shared inventory across branches', ar: 'مخزون مشترك بين الفروع' } },
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
