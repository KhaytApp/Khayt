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

/**
 * ── S4: WHAT SIMPLE SHOWS, SCREEN BY SCREEN (SPEC — under review) ─────────
 *
 * Turki, Nov 11 2026: "Simple mode that's really simpler" — one capability
 * map, here, that the desktop, the Mac and (where it applies) the iPhone all
 * read, so Simple is designed per screen instead of being Professional with a
 * CSS filter (desktop: one rule, styles.css `.pro-only`; Mac: five gated
 * features). Nothing reads this table yet: the Mac and iPhone sessions review
 * it, Turki signs off, and only then does each app wire it.
 *
 * Each row is one surface:
 *   simple   'show'    — the same in both modes
 *            'reduced' — Simple gets the smaller form in `simpleShows`;
 *                        Professional adds `proAdds`
 *            'pro'     — Professional only; in Simple it is not listed, and a
 *                        link to it says "part of Professional" with a switch
 *   where    where each app has it today ('' = the app has no such surface)
 *   today    what Simple does with it today, per app, where that differs
 *
 * Changes from today are deliberate and come from the three Nov 11 reviews
 * (desktop M6, Mac A10): Simple gains a short Expenses list and a one-page
 * Money summary instead of losing both; Team, sites, assignment, WIP limits,
 * the batch planner, exchange rates and the advanced customer fields leave
 * Simple; loyalty stays (Turki, Nov 10).
 */
const SIMPLE_MAP = [
  // ── Work ──
  { key: 'today', area: 'work', simple: 'reduced',
    simpleShows: 'Needs you, jobs moving today, printers on the bench, money this month',
    proAdds: 'site switcher, team activity, KPI row for the whole farm',
    where: { desktop: 'Dashboard', mac: 'Today', ios: 'Home' } },
  { key: 'queue', area: 'work', simple: 'reduced',
    simpleShows: '4 stages: Quote · Queued · Printing · Ready; on hold / QC / shipped shown as a note on the card',
    proAdds: 'On hold, QC and Shipped as columns or filters; WIP limits; assignee; batch planner',
    where: { desktop: 'Production queue', mac: 'Board', ios: 'Orders' },
    today: { desktop: 'all 8 columns', mac: 'all stages, WIP limits, assignee' } },
  { key: 'jobPage', area: 'work', simple: 'reduced',
    simpleShows: 'customer, parts, price, due date, payments, shipping, notes',
    proAdds: 'assignee, location, client PO, milestones, change orders, payment plans',
    where: { desktop: 'Edit order (→ job page, S1)', mac: 'Job page / inspector', ios: 'Order page' } },
  { key: 'quote', area: 'work', simple: 'reduced',
    simpleShows: 'file in, price out: parts, material, time, margin, total',
    proAdds: '"More options": templates, marketplace fees, client PO, currency, rounding rules',
    where: { desktop: 'Calculator', mac: 'Quote', ios: '' },
    today: { desktop: 'every option shown' } },
  { key: 'jobsLog', area: 'work', simple: 'show',
    simpleShows: 'every job with search and status/date filters',
    proAdds: 'operator filter, saved filters, accounting export',
    where: { desktop: 'Orders log', mac: 'Jobs', ios: 'Orders › History' } },
  // ── Shop ──
  { key: 'customers', area: 'shop', simple: 'reduced',
    simpleShows: 'name, phone, email, addresses, notes, what they owe',
    proAdds: 'commercial registration, VAT number, lead source, payment terms, credit limit, price list, subscriptions, campaigns',
    where: { desktop: 'Customers', mac: 'Customers', ios: 'Clients' },
    today: { desktop: 'all fields', mac: 'all fields' } },
  { key: 'inventory', area: 'shop', simple: 'reduced',
    simpleShows: 'spools, what is running low, a reorder reminder',
    proAdds: 'purchase orders, suppliers, auto-draft, consumables pipeline',
    where: { desktop: 'Inventory', mac: 'Inventory', ios: 'Inventory' },
    today: { desktop: '"Draft PO" button shown', mac: 'reorder banner hidden' } },
  { key: 'printFiles', area: 'shop', simple: 'show', where: { desktop: 'Print files', mac: 'Library', ios: '' } },
  { key: 'catalog', area: 'shop', simple: 'show', where: { desktop: 'Catalog', mac: 'Products', ios: '' } },
  { key: 'portfolio', area: 'shop', simple: 'show', where: { desktop: 'Portfolio', mac: '', ios: '' } },
  { key: 'giftCards', area: 'shop', simple: 'show', where: { desktop: 'Gift cards', mac: 'Gift cards', ios: '' } },
  { key: 'loyalty', area: 'shop', simple: 'reduced',
    simpleShows: 'loyalty on/off and up to 3 tiers: name, completed orders, discount %',
    proAdds: 'spend thresholds, points per unit, redemption rules',
    where: { desktop: 'Settings › Pricing & tax', mac: 'Settings › Customers', ios: '' },
    today: { desktop: 'full editor', mac: 'full four-column editor' } },
  { key: 'machines', area: 'shop', simple: 'reduced',
    simpleShows: 'printers, what they are printing, nozzle/plate notes',
    proAdds: 'care plans, maintenance log, downtime, utilisation',
    where: { desktop: 'Settings › Printers', mac: 'Machines', ios: 'Machines' },
    today: { mac: 'care-plan button hidden' } },
  // ── Money ──
  { key: 'money', area: 'money', simple: 'reduced',
    simpleShows: 'one Money page: earned, owed and spent this month; who owes me; best customers; top products',
    proAdds: 'full analytics, forecasting, break-even, VAT return, accounting exports',
    where: { desktop: 'Analytics', mac: 'Reports', ios: '' },
    today: { desktop: 'reduced view that ranks tags', mac: 'Reports hidden; Today card says "Reconciled in Reports"' } },
  { key: 'expenses', area: 'money', simple: 'reduced',
    simpleShows: 'a short list: add an expense, this month\'s total',
    proAdds: 'budgets, recurring expenses, vendors, accounts payable',
    where: { desktop: 'Expenses', mac: 'Expenses', ios: '' },
    today: { desktop: 'hidden', mac: 'hidden' } },
  { key: 'invoices', area: 'money', simple: 'show',
    simpleShows: 'tax invoices with the ZATCA QR, receipts, payment links',
    proAdds: '',
    where: { desktop: 'Invoices', mac: 'Invoices', ios: 'Order page' } },
  { key: 'proforma', area: 'money', simple: 'pro', where: { desktop: 'Order editor', mac: 'Job page', ios: '' } },
  { key: 'paymentPlans', area: 'money', simple: 'pro', where: { desktop: 'Order editor (BNPL/instalments)', mac: 'Job page', ios: '' } },
  { key: 'zatca', area: 'money', simple: 'pro', where: { desktop: 'Settings › Invoices', mac: 'Settings › Invoices', ios: '' } },
  { key: 'multiCurrency', area: 'money', simple: 'reduced',
    simpleShows: 'the shop\'s currency; a customer\'s own currency only when one is set',
    proAdds: 'exchange-rate table, per-job currency',
    where: { desktop: 'Settings › Pricing & tax', mac: 'Settings › Money', ios: '' },
    today: { desktop: 'rate table shown (all 0.00)', mac: 'rate table shown' } },
  { key: 'waste', area: 'money', simple: 'reduced',
    simpleShows: 'the waste list', proAdds: 'waste analytics',
    where: { desktop: 'Waste log', mac: 'Waste', ios: '' } },
  // ── Team & sites ──
  { key: 'team', area: 'team', simple: 'pro', where: { desktop: 'Settings › Team', mac: 'Settings › Team & Access', ios: '' },
    today: { mac: 'shown in Simple' } },
  { key: 'sites', area: 'team', simple: 'pro',
    note: 'the location picker appears only with 2+ locations, in either mode',
    where: { desktop: 'top-bar location picker', mac: 'All sites switcher', ios: '' },
    today: { desktop: 'picker shown in Simple', mac: 'switcher shown in Simple' } },
  { key: 'assignment', area: 'team', simple: 'pro', where: { desktop: '', mac: 'Jobs › Assigned to', ios: '' },
    today: { mac: 'shown in Simple' } },
  // ── Tools ──
  { key: 'colour', area: 'tools', simple: 'show', where: { desktop: 'Colour', mac: 'Colour', ios: '' } },
  { key: 'converter', area: 'tools', simple: 'show', where: { desktop: 'Converter', mac: 'Converter', ios: '' } },
  { key: 'hueforge', area: 'tools', simple: 'show', where: { desktop: 'HueForge', mac: 'HueForge', ios: '' } },
  // ── Online & messages ──
  { key: 'storefront', area: 'online', simple: 'reduced',
    simpleShows: 'the quote form and tracking page; one store connection',
    proAdds: 'every storefront (Salla, Zid, Shopify, WooCommerce…), the customer portal settings',
    where: { desktop: 'Settings › Online store', mac: 'Settings › Online', ios: '' },
    today: { mac: 'six storefronts shown' } },
  { key: 'messages', area: 'online', simple: 'reduced',
    simpleShows: 'WhatsApp templates and customer messages',
    proAdds: 'SMS providers, Telegram, email relay, webhooks',
    where: { desktop: 'Settings › Notifications', mac: 'Settings › Messages', ios: '' },
    today: { desktop: 'whole pane hidden' } },
  { key: 'connectors', area: 'online', simple: 'show',
    note: 'payment and shipping connectors a shop installed stay visible in both modes',
    where: { desktop: 'Settings › Connections', mac: 'Settings › Connectors', ios: '' } },
  { key: 'ai', area: 'online', simple: 'pro', where: { desktop: 'Settings › AI assistant', mac: 'Settings › AI', ios: '' } },
  { key: 'developer', area: 'online', simple: 'pro',
    note: 'API tokens, LAN REST API, signed webhooks — also behind "Show developer settings"',
    where: { desktop: 'Settings › Advanced / Connections', mac: 'Settings › Advanced', ios: '' } },
  // ── Shell ──
  { key: 'modeBadge', area: 'shell', simple: 'show',
    simpleShows: '"Simple" next to the shop name; the switch at the top of Settings › General',
    where: { desktop: 'sidebar head', mac: 'sidebar head', ios: '' } },
  { key: 'gatedLink', area: 'shell', simple: 'show',
    simpleShows: 'a link to a Professional screen says "Part of Professional" with a button to switch — never an empty page or the staff-lock message',
    where: { desktop: 'openSettingsSection / switchTab', mac: 'hidden-screen view', ios: '' } },
];

/** What Simple does with one surface: 'show' | 'reduced' | 'pro' | undefined. */
function simpleDecision(key) {
  const row = SIMPLE_MAP.find((r) => r.key === key);
  return row ? row.simple : undefined;
}

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

const api = { SIMPLE_CORE, BUSINESS_FEATURES, PRO_FEATURES, SIMPLE_MAP, simpleDecision, isProMode, isEnthusiast, showsBusiness, isFeatureEnabled, tierComparison };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytTiers = api;

})();
