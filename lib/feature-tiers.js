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
  // Loyalty is shown in Simple (Turki, Nov 10): the settings card carries no
  // .pro-only and the Mac does not gate it. The comparison listed it as Pro.
  { key: 'loyalty',    label: { en: 'Loyalty tiers', ar: 'مستويات الولاء' } },
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
  { key: 'breakEven',     label: { en: 'Break-even & overhead', ar: 'نقطة التعادل والتكاليف الثابتة' } },
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
 *   today      where each app has it today ('' = the app has no such surface)
 *   afterS2    the pane it moves to once Settings is rebuilt (S2, Mac page 09)
 *   simpleNow  what Simple does with it today, per app, where that differs
 *   gate       the existing lib gate key this row owns (see GATE_ROWS)
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
    today: { desktop: 'Dashboard', mac: 'Today', ios: 'Home' } },
  { key: 'queue', area: 'work', simple: 'reduced',
    simpleShows: '4 stages: Quote · Queued · Printing · Ready; on hold / QC / shipped shown as a note on the card',
    proAdds: 'On hold, QC and Shipped as columns or filters; WIP limits; assignee; batch planner',
    today: { desktop: 'Production queue', mac: 'Jobs › Board view (the stage is "Pending")', ios: 'Orders' },
    simpleNow: { desktop: 'all 8 columns', mac: 'all stages, WIP limits, assignee' } },
  { key: 'jobPage', area: 'work', simple: 'reduced',
    simpleShows: 'customer, parts, price, due date, payments, shipping, notes',
    proAdds: 'assignee, location, client PO, milestones, change orders, payment plans',
    today: { desktop: 'Edit order (modal) / board drawer', mac: 'Jobs › inspector / Edit Job / Order details…', ios: 'Order page (payments are recorded here)' } },
  { key: 'quote', area: 'work', simple: 'reduced',
    simpleShows: 'file in, price out: parts, material, time, margin, total',
    proAdds: '"More options": templates, marketplace fees, client PO, currency, rounding rules',
    today: { desktop: 'Calculator', mac: 'Calculator + New Job › Save as quote', ios: 'New › Calculator, New › Quote a file, Orders › Quotes' },
    simpleNow: { desktop: 'every option shown' } },
  { key: 'jobsLog', area: 'work', simple: 'show',
    simpleShows: 'every job with search and status/date filters',
    proAdds: 'operator filter, saved filters, accounting export',
    today: { desktop: 'Orders log', mac: 'Jobs', ios: 'Orders › History' } },
  { key: 'schedule', area: 'work', simple: 'pro',
    note: 'capacity planning across machines; Simple keeps due dates and ETAs on the cards',
    today: { desktop: 'Production queue › Schedule view', mac: 'Schedule / Suggest Schedule', ios: '' } },
  { key: 'kiosk', area: 'work', simple: 'pro',
    note: 'a shop-floor screen for staff',
    today: { desktop: 'Kiosk view', mac: 'Kiosk', ios: '' } },
  { key: 'endOfDay', area: 'work', simple: 'show',
    simpleShows: 'what was finished, earned, wasted and logged today',
    today: { desktop: 'End of day report', mac: 'End of Day', ios: 'End of day' } },
  // ── Shop ──
  { key: 'customers', area: 'shop', simple: 'reduced',
    simpleShows: 'name, phone, email, addresses, notes, what they owe',
    proAdds: 'commercial registration, VAT number, lead source, payment terms, credit limit, price list, subscriptions',
    today: { desktop: 'Customers', mac: 'Customers', ios: 'Clients' },
    simpleNow: { desktop: 'all fields', mac: 'all fields' } },
  { key: 'campaigns', area: 'shop', simple: 'pro',
    today: { desktop: 'Customers › More › Campaign', mac: 'Campaigns', ios: '' } },
  { key: 'inventory', area: 'shop', simple: 'reduced', gate: 'purchasing',
    simpleShows: 'spools, what is running low, a reorder reminder',
    proAdds: 'purchase orders, suppliers, auto-draft, consumables pipeline (the `purchasing` gate)',
    today: { desktop: 'Inventory', mac: 'Inventory', ios: 'Inventory' },
    simpleNow: { desktop: '"Draft PO" button shown', mac: 'reorder banner hidden' } },
  { key: 'printFiles', area: 'shop', simple: 'show', today: { desktop: 'Print files', mac: 'Library', ios: 'New › Library (browse)' } },
  { key: 'catalog', area: 'shop', simple: 'show', today: { desktop: 'Catalog', mac: 'Catalogue', ios: 'Catalogue' } },
  { key: 'portfolio', area: 'shop', simple: 'show', today: { desktop: 'Portfolio', mac: 'More › Portfolio', ios: '' } },
  { key: 'giftCards', area: 'shop', simple: 'show', today: { desktop: 'Gift cards', mac: 'More › Gift cards', ios: '' } },
  { key: 'loyalty', area: 'shop', simple: 'reduced',
    simpleShows: 'loyalty on/off and up to 3 tiers by completed orders: name, completed orders, discount % (Turki, Nov 11)',
    proAdds: 'spend thresholds, points per unit, redemption rules, more tiers',
    today: { desktop: 'Settings › Pricing & Tax', mac: 'Settings › Pricing & Tax', ios: '' },
    afterS2: { desktop: 'Pricing & costs', mac: 'Pricing & costs' },
    simpleNow: { desktop: 'full editor', mac: 'full four-column editor' } },
  { key: 'machines', area: 'shop', simple: 'reduced',
    simpleShows: 'printers, what they are printing, nozzle/plate notes',
    proAdds: 'care plans and the parts to buy for them (see machineUpkeep)',
    today: { desktop: 'Settings › Printers & Slicers', mac: 'Machines', ios: 'Machines' },
    simpleNow: { mac: 'care-plan button hidden' } },
  { key: 'machineUpkeep', area: 'shop', simple: 'pro', gate: 'maintenance',
    note: 'care plans, maintenance log, downtime, purchase value and depreciation',
    today: { desktop: 'Machine editor › maintenance', mac: 'Edit Printer › Upkeep and Value tabs', ios: 'Machines › Care, Parts to buy' } },
  { key: 'productionSettings', area: 'shop', simple: 'reduced',
    simpleShows: 'the post-processing checklist and custom order fields',
    proAdds: 'the QC stage, WIP limits, the environment log',
    today: { desktop: 'Settings › Production', mac: 'Settings › Production', ios: '' },
    afterS2: { desktop: 'Production', mac: 'Production' } },
  // ── Money ──
  { key: 'money', area: 'money', simple: 'reduced', gate: 'analytics',
    simpleShows: 'one Money page: earned, owed and spent this month; who owes me; best customers; top products',
    proAdds: 'full analytics, forecasting, break-even, accounting exports',
    note: 'the `analytics` gate means "full analytics": in Simple it opens the Money page instead of hiding',
    today: { desktop: 'Analytics', mac: 'Reports', ios: 'Home money card, Owed, End of day (no reports)' },
    simpleNow: { desktop: 'reduced view that ranks tags', mac: 'Reports hidden; Today card says "Reconciled in Reports"' } },
  { key: 'expenses', area: 'money', simple: 'reduced', gate: 'expenses',
    simpleShows: 'a short list: add an expense, this month\'s total',
    proAdds: 'budgets, recurring expenses, vendors, accounts payable',
    note: 'the `expenses` gate becomes "reduced", not "hidden"',
    today: { desktop: 'Expenses', mac: 'Expenses', ios: 'New › Expense (add only)' },
    simpleNow: { desktop: 'hidden', mac: 'hidden' } },
  { key: 'invoices', area: 'money', simple: 'show',
    simpleShows: 'tax invoices, receipts and payment links; the simplified-invoice QR always prints',
    proAdds: 'ZATCA Phase 2 settings (see zatca)',
    today: { desktop: 'Invoices + Settings › Invoices & Payments', mac: 'Job › Invoice sheet + Settings › Invoices & Payments', ios: 'Order page' },
    afterS2: { desktop: 'Documents · Payments', mac: 'Documents · Payments' } },
  { key: 'vatReturns', area: 'money', simple: 'reduced',
    simpleShows: 'VAT owed this quarter, as one line on the Money page',
    proAdds: 'the return table, filing frequency, exports',
    today: { desktop: 'Analytics › VAT return + Settings › Invoices & Payments', mac: 'Reports › VAT returns + Settings (return frequency)', ios: '' },
    afterS2: { desktop: 'Tax & currency', mac: 'Tax & currency' } },
  { key: 'proforma', area: 'money', simple: 'pro', today: { desktop: 'Order editor', mac: 'Job menu papers + Milestones sheet', ios: 'Order page › Proforma' } },
  { key: 'paymentPlans', area: 'money', simple: 'pro', today: { desktop: 'Order editor (BNPL / instalments)', mac: 'Job › Payment Plan…', ios: '' } },
  { key: 'zatca', area: 'money', simple: 'pro', gate: 'zatca',
    note: 'ZATCA Phase 2 only; the simplified-invoice QR (Phase 1) prints in both modes',
    today: { desktop: 'Settings › Invoices & Payments', mac: 'Settings › Pricing & Tax', ios: '' },
    afterS2: { desktop: 'Tax & currency', mac: 'Tax & currency' } },
  { key: 'multiCurrency', area: 'money', simple: 'reduced',
    simpleShows: 'the shop\'s currency; a customer\'s own currency only when one is set',
    proAdds: 'exchange-rate table, per-job currency',
    today: { desktop: 'Settings › Pricing & Tax', mac: 'Settings › Pricing & Tax', ios: '' },
    afterS2: { desktop: 'Tax & currency', mac: 'Tax & currency' },
    simpleNow: { desktop: 'rate table shown (all 0.00)', mac: 'rate table shown' } },
  { key: 'waste', area: 'money', simple: 'reduced',
    simpleShows: 'the waste list', proAdds: 'waste analytics',
    today: { desktop: 'Waste log', mac: 'More › Waste', ios: 'New › Log a failed print' } },
  // ── Team & sites ──
  { key: 'team', area: 'team', simple: 'pro',
    today: { desktop: 'Settings › Team & Access', mac: 'Settings › Team & Access', ios: '' },
    afterS2: { desktop: 'Team & access', mac: 'Team & access' },
    simpleNow: { mac: 'shown in Simple' } },
  { key: 'staffPins', area: 'team', simple: 'pro',
    note: 'staff sign-in PINs and hourly rates; the owner\'s app-lock PIN stays in both modes',
    today: { desktop: 'Settings › Team & Access › Operator PINs', mac: 'Settings › Team & Access', ios: 'Settings › Staff on this phone' },
    afterS2: { desktop: 'Team & access', mac: 'Team & access' } },
  { key: 'sites', area: 'team', simple: 'pro',
    note: 'the location picker appears only with 2+ locations, in either mode',
    today: { desktop: 'top-bar location picker', mac: 'sidebar switcher + Edit Printer + Settings › Shop › Locations', ios: '' },
    afterS2: { desktop: 'Shop details', mac: 'Shop details' },
    simpleNow: { desktop: 'picker shown in Simple', mac: 'switcher shown in Simple' } },
  { key: 'assignment', area: 'team', simple: 'pro', today: { desktop: '', mac: 'Jobs › Assigned to', ios: '' },
    simpleNow: { mac: 'shown in Simple' } },
  // ── Tools ──
  { key: 'colour', area: 'tools', simple: 'show', today: { desktop: 'Colour', mac: 'More › Colour', ios: '' } },
  { key: 'converter', area: 'tools', simple: 'show', today: { desktop: 'Converter', mac: 'Library › Model menu › Convert For', ios: '' } },
  { key: 'hueforge', area: 'tools', simple: 'show', today: { desktop: 'HueForge', mac: 'HueForge', ios: '' } },
  // ── Online & messages ──
  { key: 'storefront', area: 'online', simple: 'reduced',
    simpleShows: 'the quote form and tracking page; one store connection',
    proAdds: 'every storefront (Salla, Zid, Shopify, WooCommerce…), the customer portal settings',
    today: { desktop: 'Settings › Online Store', mac: 'Settings › Online + Integrations › Storefronts', ios: '' },
    afterS2: { desktop: 'Sales channels', mac: 'Sales channels' },
    simpleNow: { mac: 'six storefronts shown' } },
  { key: 'webStore', area: 'online', simple: 'show',
    note: 'orders that arrive from the shop\'s own web store or quote form',
    today: { desktop: 'Production queue › Awaiting approval / intake', mac: 'Web store / Online orders', ios: 'Orders' } },
  { key: 'messages', area: 'online', simple: 'reduced',
    simpleShows: 'WhatsApp templates and customer messages',
    proAdds: 'SMS providers, Telegram, email relay, webhooks',
    today: { desktop: 'Settings › Notifications & Messages', mac: 'Settings › Integrations / Online', ios: '' },
    afterS2: { desktop: 'Messages & alerts', mac: 'Messages & alerts' },
    simpleNow: { desktop: 'whole pane hidden' } },
  { key: 'connectors', area: 'online', simple: 'show',
    note: 'payment and shipping connectors a shop installed stay visible in both modes (Turki, Nov 11)',
    today: { desktop: 'Settings › Connections', mac: 'Settings › Integrations / Online', ios: 'Settings › Connectors (read-only)' },
    afterS2: { desktop: 'Connectors', mac: 'Connectors' } },
  { key: 'libraryStorage', area: 'online', simple: 'reduced',
    simpleShows: 'where the library lives (this computer, a folder, Google Drive) and the off-site backup',
    proAdds: 'S3 / R2 storage, tiering, sealing',
    today: { desktop: 'Settings › Library & Files', mac: 'Settings › Library (Drive, off-site backup)', ios: '' },
    afterS2: { desktop: 'Library & backup', mac: 'Library & backup' } },
  { key: 'ai', area: 'online', simple: 'pro',
    note: 'Ask the Book and the AI settings',
    today: { desktop: 'Settings › AI Assistant', mac: 'Ask the Book + Settings › AI', ios: '' },
    afterS2: { desktop: 'AI assist', mac: 'AI assist' } },
  { key: 'developer', area: 'online', simple: 'pro',
    note: 'API tokens, LAN REST API, signed webhooks — also behind "Show developer settings"',
    today: { desktop: 'Settings › Advanced / Connections', mac: 'Settings › Integrations / Online (no Advanced pane)', ios: '' },
    afterS2: { desktop: 'Developer', mac: 'Developer' } },
  // ── Shell ──
  { key: 'modeBadge', area: 'shell', simple: 'show',
    simpleShows: '"Simple" next to the shop name; the switch at the top of General',
    today: { desktop: 'Settings › General (mode cards)', mac: 'Settings › General › Experience', ios: '' },
    afterS2: { desktop: 'General', mac: 'General' } },
  { key: 'gatedLink', area: 'shell', simple: 'show',
    simpleShows: 'a link to a Professional screen says "Part of Professional" with a button to switch — never an empty page or the staff-lock message',
    today: { desktop: 'openSettingsSection / switchTab', mac: 'the NotAllowed view', ios: '' } },
];

/** The five gates the apps already read, and the row each one belongs to.
 *  `analytics` and `expenses` stop meaning "hidden in Simple" and start
 *  meaning "the reduced form in Simple" (Dev Hub, Nov 11). */
const GATE_ROWS = { analytics: 'money', expenses: 'expenses', maintenance: 'machineUpkeep', purchasing: 'inventory', zatca: 'zatca' };

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

const api = { SIMPLE_CORE, BUSINESS_FEATURES, PRO_FEATURES, SIMPLE_MAP, GATE_ROWS, simpleDecision, isProMode, isEnthusiast, showsBusiness, isFeatureEnabled, tierComparison };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytTiers = api;

})();
