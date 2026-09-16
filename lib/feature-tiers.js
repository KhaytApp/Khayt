'use strict';
(function () {

/**
 * Feature tiers — the SINGLE SOURCE OF TRUTH for what belongs to the Professional
 * mode, the business surfaces, and the always-on personal core.
 *
 * Three modes exist across the two flavors, but Khayt only offers two of them:
 *
 *   - simple      : small shop. Personal core + business basics, no Pro depth.
 *   - professional: full business. Everything.
 *   - enthusiast  : hobbyist / personal use. No commerce at all (no clients,
 *                   invoicing, ZATCA, storefront, payments). Personal core only.
 *                   NOT selectable in Khayt — there is no enthusiast option in
 *                   renderer/index.html. It is Bed Ready's only mode, offered in
 *                   bedready.html and force-pinned by applyMode() in shell.js.
 *                   The tier arrays below still describe it because the .biz-only
 *                   gating they document is what makes Bed Ready commerce-free.
 *
 * The UI gates Pro features with the .pro-only class (hidden under body.mode-simple
 * AND body.mode-enthusiast) and business features with the .biz-only class (hidden
 * under body.mode-enthusiast). This registry documents the boundary in one place
 * and drives the in-app tier comparison.
 *
 * Pure (no DOM/globals) so it can be unit-tested and reused.
 */

/** Personal core — available in EVERY mode (incl. enthusiast). */
const SIMPLE_CORE = [
  { key: 'quote',      label: { en: 'Cost calculator', ar: 'حاسبة التكلفة' } },
  { key: 'queue',      label: { en: 'Production queue (Kanban)', ar: 'قائمة الإنتاج (كانبان)' } },
  { key: 'printFiles', label: { en: 'Print-file library', ar: 'مكتبة ملفات الطباعة' } },
  { key: 'colorMix',   label: { en: 'Colour mixer & matcher', ar: 'مازج ومطابق الألوان' } },
  { key: 'inventory',  label: { en: 'Filament inventory', ar: 'مخزون الخيوط' } },
  { key: 'printers',   label: { en: 'Printers & monitoring', ar: 'الطابعات والمراقبة' } },
];

/**
 * Business features — commerce surfaces present in simple + professional, hidden in
 * enthusiast mode (each maps to .biz-only or .pro-only UI).
 */
const BUSINESS_FEATURES = [
  { key: 'clients',    label: { en: 'Clients', ar: 'العملاء' } },
  { key: 'invoices',   label: { en: 'Invoices & payments', ar: 'الفواتير والمدفوعات' } },
  { key: 'orders',     label: { en: 'Customer orders log', ar: 'سجل طلبات العملاء' } },
  { key: 'storefront', label: { en: 'Online storefront & portal', ar: 'المتجر الإلكتروني وبوابة العملاء' } },
  { key: 'giftCards',  label: { en: 'Gift cards', ar: 'بطاقات الهدايا' } },
  { key: 'reports',    label: { en: 'Sales reports', ar: 'تقارير المبيعات' } },
  // ── TWO THE REGISTRY GOVERNED AND DID NOT NAME ──────────────────────────
  //
  // `catalog-tab` and `portfolio-tab` in renderer/index.html both carry
  // `.biz-only`, so an enthusiast has never seen either — but neither
  // appeared in any list here. This file calls itself the single source of
  // truth for that boundary and drives `tierComparison`, which is what a shop
  // reads when it chooses a mode. So the comparison was short of two things
  // the shop actually gets.
  { key: 'catalog',    label: { en: 'Product catalogue', ar: 'كتالوج المنتجات' } },
  { key: 'portfolio',  label: { en: 'Portfolio', ar: 'معرض الأعمال' } },
];

/** Professional-only — unlocked in Professional mode (each maps to .pro-only UI). */
const PRO_FEATURES = [
  { key: 'analytics',     label: { en: 'Full analytics & forecasting', ar: 'تحليلات وتوقّعات كاملة' } },
  { key: 'zatca',         label: { en: 'ZATCA Phase 2 e-invoicing', ar: 'فوترة هيئة الزكاة (المرحلة الثانية)' } },
  { key: 'proforma',      label: { en: 'Proforma & milestone invoices, credit notes', ar: 'فواتير مبدئية ومراحل وإشعارات دائنة' } },
  { key: 'purchasing',    label: { en: 'Purchase orders & accounts payable', ar: 'أوامر الشراء والذمم الدائنة' } },
  { key: 'multiLocation', label: { en: 'Multiple locations & print-farm view', ar: 'فروع متعددة وعرض مزرعة الطباعة' } },
  { key: 'team',          label: { en: 'Team accounts & roles', ar: 'حسابات الفريق والأدوار' } },
  { key: 'maintenance',   label: { en: 'Machine maintenance & downtime', ar: 'صيانة الأجهزة والتوقّف' } },
  { key: 'loyalty',       label: { en: 'Loyalty tiers & break-even', ar: 'مستويات الولاء ونقطة التعادل' } },
  { key: 'expenses',      label: { en: 'Expense tracking', ar: 'تتبّع المصروفات' } },
];

/** Is the given mode the Professional tier? (default mode = professional) */
function isProMode(mode) { return (mode || 'professional') === 'professional'; }

/** Is the given mode the hobbyist/personal tier (no commerce)? */
function isEnthusiast(mode) { return mode === 'enthusiast'; }

/** Does this mode show business/commerce surfaces at all? enthusiast = no. */
function showsBusiness(mode) { return mode !== 'enthusiast'; }

/** Is a feature key available in the given mode? Unknown keys = personal-core (always on). */
function isFeatureEnabled(key, mode) {
  if (PRO_FEATURES.some((f) => f.key === key)) return isProMode(mode);
  if (BUSINESS_FEATURES.some((f) => f.key === key)) return showsBusiness(mode);
  return true;
}

/** Localized rows for the tier-comparison UI (three columns). */
function tierComparison(lang) {
  const L = (o) => (o && (o[lang] || o.en)) || '';
  const map = (arr) => arr.map((f) => ({ key: f.key, label: L(f.label) }));
  // Columns are additive: each lists only what it ADDS over the tier to its left
  // (enthusiast = personal core; simple adds business basics; pro adds depth).
  return {
    enthusiast: map(SIMPLE_CORE),
    simple: map(BUSINESS_FEATURES),
    pro: map(PRO_FEATURES),
  };
}

const api = { SIMPLE_CORE, BUSINESS_FEATURES, PRO_FEATURES, isProMode, isEnthusiast, showsBusiness, isFeatureEnabled, tierComparison };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytTiers = api;

})();
