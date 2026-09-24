/**
 * App collections, persistence (load/save), and store validators.
 */
/* Make sure the working week is loaded, WITHOUT declaring a binding for it.
 *
 * lib/working-week.js assigns globalThis.KhaytWorkingWeek itself, so the script
 * tag has already done this in the renderer, and `require` does it under Node,
 * where these files are pulled in directly by tests.
 *
 * The obvious version — a shared `const` at the top of each file — is a trap.
 * Classic scripts share ONE global lexical scope, so the second file to declare
 * the same top-level const throws "already been declared" and kills every script
 * after it. That is what happened: settings.js never reached its export list,
 * and the app died wiring a button whose handler had silently ceased to exist. */
if (typeof KhaytWorkingWeek === 'undefined' && typeof require === 'function') {
  require('../lib/working-week.js');
}
/* ---------- Storage keys (versioned) ---------- */
const K = {
  LOG:       '3d_print_log_v4',
  INV:       '3d_filament_inventory_v4',
  TPL:       '3d_part_templates_v4',
  PROD:      'hub_products_v1',
  CLIENTS:   'hub_clients_v1',
  SETTINGS:  'hub_settings_v2',
  THEME:     'hub_theme',
  PRINTERS:  'hub_printers_v1',
  EXPENSES:  'hub_expenses_v1',
  MACHINES:  'hub_machines_v1',
  WA_TEMPLATES: 'hub_wa_templates_v1',
  WASTE:     'hub_waste_log_v1',
  MAINT:     'hub_maint_log_v1',
  CONSUMABLES: 'hub_consumables_v1',
  SUPPLIERS:   'hub_suppliers_v1',
  CURRENT_BUILD: 'hub_current_build_v1',
  PURCHASE_ORDERS: 'hub_purchase_orders_v1',
  TEST_PRINTS: 'hub_test_prints_v1',
  LOCATIONS: 'hub_locations_v1',
  OPERATORS: 'hub_operators_v1',
  WAITING:   'hub_waiting_v1',
  WAITING_HISTORY: 'hub_waiting_history_v1',
  TIME_ENTRIES: 'hub_time_entries_v1',
  TOMBSTONES: 'hub_tombstones_v1',
  MAINT_TASKS: 'hub_maint_tasks_v1',
  LOYALTY_LEDGER: 'hub_loyalty_ledger_v1',
};

const STORE_SECRET_MASK = KhaytStore.SECRET_MASK;
function secretInputValue(v) { return v === STORE_SECRET_MASK ? '' : (v || ''); }
function secretInputSave(current, typed) {
  const t = (typed || '').trim();
  if (t) return t;
  return current === STORE_SECRET_MASK ? STORE_SECRET_MASK : (current || '');
}

function isSecretMasked(v) { return v === STORE_SECRET_MASK; }
function secretFieldPlaceholder(current) {
  return isSecretMasked(current) ? (t('common.secret_unchanged') || 'Leave blank to keep current') : '';
}
function migrateLanApiSettings() {
  if (!settings.lanApi) settings.lanApi = {};
  if (settings.sallaWebhookSecret && !settings.lanApi.sallaWebhookSecret) {
    settings.lanApi.sallaWebhookSecret = settings.sallaWebhookSecret;
  }
  if (settings.zidWebhookSecret && !settings.lanApi.zidWebhookSecret) {
    settings.lanApi.zidWebhookSecret = settings.zidWebhookSecret;
  }
}
/**
 * One-time migration to the 2.6 theme consolidation (7 legacy designs → 3).
 * Maps a saved legacy designTheme to the nearest new theme, once.
 *
 * The six deletable legacy designs are gone from the registry as of 3.3, so
 * normalizeDesignId() would fall a stale setting back to 'workbench' anyway —
 * but that would land a former cockpit/atlas user on the wrong shell. This map
 * keeps the intended destination, so it stays until the flag is universal.
 * `studio` is still mapped: it was a real saved value before 3.3, when Bed Ready
 * took that design with it and it stopped being a Khayt theme at all.
 */
function migrateLegacyDesignTheme() {
  if (!settings || settings.__designV26Migrated) return;
  const map = {
    studio: 'workbench', ledger: 'workbench', console: 'workbench',
    cockpit: 'command', atlas: 'command',
    vitrine: 'vivid', atelier: 'vivid',
  };
  const cur = settings.designTheme;
  if (cur && map[cur]) settings.designTheme = map[cur];
  settings.__designV26Migrated = true;
}
function sanitizePrintHtml(html) {
  return String(html || '')
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/\s+on\w+\s*=\s*(".*?"|'.*?'|[^\s>]+)/gi, '')
    .replace(/javascript\s*:/gi, '');
}

function defaultSettings() {
  return {
    ai:        { enabled: false, model: 'claude-opus-5', apiKey: '' }, // AI assist (BYO key, opt-in)
    cloud:     { enabled: false, url: 'https://cloud.khaytapp.com' },     // Khayt Cloud sync (opt-in, E2E)
    // Flavor-aware default shop name: the Bed Ready standalone app seeds its own
    // brand (guarded by the html data-app marker; Khayt is unaffected).
    bizEn:     (typeof document !== 'undefined' && document.documentElement?.dataset.app === 'bedready') ? 'Bed Ready' : 'Khayt',
    bizAr:     (typeof document !== 'undefined' && document.documentElement?.dataset.app === 'bedready') ? 'بيد ريدي' : 'خيط',
    vat:       '',
    cr:        '',
    phone:     '',
    email:     '',
    addrEn:    (typeof document !== 'undefined' && document.documentElement?.dataset.app === 'bedready') ? '' : 'Riyadh, Saudi Arabia',
    addrAr:    (typeof document !== 'undefined' && document.documentElement?.dataset.app === 'bedready') ? '' : 'الرياض، المملكة العربية السعودية',
    lang:      'en',
    theme:         'light',
    designTheme:   'workbench',
    // The board is what the product is sold on, so it is what a shop gets.
    // `queueViewChosen` is only ever written when someone works the toggle, which
    // is what separates "never expressed a view" from "asked for the list" — the
    // stored value alone cannot tell those apart, and every existing shop has
    // 'list' on disk purely because it used to be the default.
    queueView:     'kanban',
    accent:        'cyan',
    invPrefix: 'INV',
    footerEn:  'Thank you for your business!',
    footerAr:  'شكراً لتعاملكم معنا!',
    autoDeduct: true,
    lowStockThreshold: 200,
    // New in 1.3
    bankName:        '',
    accountHolder:   '',
    iban:            '',
    acceptedPayments: ['cash', 'mada', 'transfer'],
    useHijri:        true,
    useArabicNumerals: false,
    autoBackup:      true,
    autoDraftPo:     false,
    enableVat:       false,
    vatRate:         15,
    bizLogo:         '',
    // Per-shop overrides for the nozzle wear table. Empty means "use the
    // published figures" — see lib/nozzle-wear-data.js for where those come
    // from and which of them are still estimates.
    nozzleWear:      { life: {}, abrasive: {} },
    // Which languages this shop writes its PRODUCTS in — a different question
    // from which language the app is shown in. Defaults to the two the
    // catalogue was hard-coded to, so nothing changes until a shop chooses.
    contentLangs:    ['en', 'ar'],
    taglineEn:       '',
    taglineAr:       '',
    invAccentColor:  '#5E2E14',
    invTemplate:     'classic', // classic | modern | minimal
    invTermsEn:      '',
    invTermsAr:      '',
    // 'auto' | 'both' | 'single' — see lib/invoice-language.js. `auto` prints
    // one language for everyone except Arabic shops (whose English pairing is
    // doing real work) and shops under ZATCA (where Arabic is a legal
    // requirement and the setting is overridden entirely).
    invoiceBilingual: 'auto',
    // Which language goes second when a document is bilingual. Arabic is only
    // the DEFAULT — before this existed it was the only possibility, which is
    // how a French shop ended up printing French and Arabic.
    invoiceSecondLang: 'ar',
    // Empty means "follow the theme" — see applyLowStockColor(). A colour here
    // overrides ONLY the low-stock highlight, never the other warnings.
    lowStockColor:   '',
    // Empty means "follow the theme" — see applyLowStockColor(). A colour here
    // overrides ONLY the low-stock highlight, never the other warnings.
    lowStockColor:   '',
    quotePrefix:     'QUO',
    useIcloud:       false,
    monthlyGoal:     0,
    supplierPhone:   '',
    // v2.0 — worldwide
    currency:        (typeof document !== 'undefined' && document.documentElement?.dataset.app === 'bedready') ? 'USD' : 'SAR',
    enableZatca:     true,
    zatcaPhase2:     { enabled: false, environment: 'sandbox', csid: '', pcsid: '', cn: '', invoiceCounter: 0, lastInvoiceHash: 'NWZlY2ViNjZmZmM4NmYzOGQ5NTI3ODZjNmQ2OTZjNzljMmRiYzIzOWRkNGU5MWI4NjJhNGRhNjM3NWQ2OGM5', org: '', city: 'Riyadh', industry: '3D Printing', autoSubmit: true, emailAfterSubmit: false, submissions: [] },
    bnpl: {
      tabby:  { enabled: false, apiKey: '', merchantCode: '', currency: 'SAR' },
      tamara: { enabled: false, apiKey: '', notificationToken: '', currency: 'SAR', country: 'SA' },
      stripe: { enabled: false, apiKey: '', currency: 'usd', successUrl: '', cancelUrl: '' },
    },
    donationUrl:     '',
    firstRunDone:    false,
    tourDone:        false,
    coachTips:       true,
    savedReports:    [],
    // v3.0 additions
    minMarginPct:    0,
    expBudgets:      {},
    postChecklist:   [],
    customFields:    [],
    // Feature 7: Invoice number sequence
    invNumPrefix:    'INV',
    invNumYear:      new Date().getFullYear(),
    invNumNext:      1,
    quoteNumYear:    new Date().getFullYear(),
    quoteNumNext:    1,
    invNumFormat:    '{prefix}-{year}-{seq4}',
    // New Feature 7: Working hours schedule
    // Sunday to Thursday — see lib/working-week.js. This said Monday to
    // Thursday, a four-day week matching no calendar anywhere.
    workingHours:    { ...KhaytWorkingWeek.DEFAULT_WORKING_HOURS },
    holidays:        [],
    // Business Mode (simple | professional)
    mode:            'simple',
    businessType:    'solo',  // solo | shop | farm | b2b
    firstRun:        true,
    // Stale order alert thresholds (hours per status)
    staleHours: { printing: 48, post: 24, qc: 12, pending: 72 },
    // QC / reprint / RMA — opt-in inspection gate on the existing `qc` stage.
    // enabled:false keeps today's behaviour (pass/fail still work; new fields optional).
    // See docs/KHAYT-3.0-QC-SPEC.md.
    qc: { enabled: false, requireInspector: false, warrantyDays: 30, requirePhotoOnFail: false },
    // Feature 8 (this batch): Production pause
    productionPaused: false,
    pauseReason:      '',
    pausedAt:         null,
    // Feature 5 (this batch): Filament colour library
    filamentColours:  {},
    // Feature 5 (new batch): Email notifications
    emailConfig:      { provider: 'none', apiKey: '', fromEmail: '', fromName: '', domain: '', triggers: [] },
    // SMS / WhatsApp notifications (automated, provider-based)
    smsConfig:        { provider: 'none', channel: 'whatsapp', accountSid: '', authToken: '', from: '', phoneNumberId: '', token: '', appSid: '', senderId: '', url: '', secret: '' },
    // Print-farm auto-scheduling: when on, queued jobs are auto-assigned to free machines
    autoSchedule:     false,
    // Quote bundles: reusable named sets of products → one-tap multi-product quote
    bundles:          [],
    // Payment providers enabled per market (registry-backed): { id: { enabled, payLink } }
    paymentProviders: {},
    // Accounting sync: one-way webhook push of invoices/expenses (QuickBooks/Zoho/Xero bridge)
    accountingSync:   { enabled: false, format: 'generic', webhookUrl: '', secret: '', pushOnPaid: true },
    // Telemetry — OFF by default, and separately consented for crashes vs usage.
    // Nothing is collected or queued unless a stream is explicitly enabled.
    // See docs/KHAYT-3.0-TELEMETRY-SPEC.md.
    telemetry:        { crashOptIn: false, usageOptIn: false, installId: '', consentAt: '' },
    // Privacy / PDPL — optional retention window for customer-submitted intake data.
    // 0 = keep indefinitely (default; the owner decides their own retention basis).
    // See docs/KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md.
    privacy:          { retentionMonths: 0 },
    // Shipping & fulfillment — opt-in Saudi carrier credentials (encrypted). Manual-first:
    // shipping works with zero config; API carriers layer on when enabled. See
    // docs/KHAYT-3.0-SHIPPING-SPEC.md. Per-carrier: { enabled, apiKey, accountNumber, webhookSecret }.
    shipping:         { smsa: {}, aramex: {}, spl: {} },
    // Feature 7 (new batch): Operator lock
    activeOperatorId: null,
    operatorLockEnabled: false,
    securityEnabled: false,
    recoveryCodeHash: '',
    recoveryCodeCreatedAt: '',
    // Feature 8 (new batch): Loyalty tiers
    loyaltyEnabled:   false,
    loyaltyTiers:     [],
    // Round 12: Webhooks
    webhooks:         { enabled: false, secret: '', events: {
      order_created: '', status_changed: '', payment_received: '', quote_approved: '', order_delivered: ''
    }},
    // Round 12: Break-even / fixed overhead
    fixedCosts:       [],
    // Online: customer intake + LAN-backed links (no Khayt cloud)
    onlineEnabled:    false,
    // Round 12: LAN API
    lanApi:           { enabled: false, port: 3219, pin: '', intakePin: '', intakeToken: '', calendarToken: '', webhookToken: '', sallaWebhookSecret: '', zidWebhookSecret: '', tunnelEnabled: false, bindLan: false, apiTokens: [] },
    // Round 12: Saved filter presets
    savedFilters:     [],
    betaAcknowledged: true, // legacy field — kept so old saved data doesn't break
    betaUpdates:       false, // opt-in: include beta pre-releases in auto-update checks
    /* How long a job takes to reach a customer — the shop's own working pattern.
     *
     * Used to answer "when could this be ready" BEFORE somebody orders, so the
     * numbers here are a promise rather than a plan. `safetyDays` is added to
     * every promise and to nothing else: it must not move the internal schedule
     * board, or the shop ends up planning against padding it added for customers.
     *
     * dailyHours defaults low and workingDaysPerWeek defaults to five, because a
     * default that flatters the date is a default that breaks a promise. */
    leadTime: {
      dailyHours:         8,   // printing hours actually achieved on a working day
      workingDaysPerWeek: 5,
      finishingDays:      1,   // post-processing and QC after the last layer
      dispatchDays:       1,   // packing and handover to the carrier
      safetyDays:         1,   // added to every promise, never to the schedule
      publishToCloud:     false,
    },
    // Easy-wins batch: Calculator
    quoteValidityDays: 7,
    // Quote follow-up automation (auto-nudge OFF by default; dashboard card always on)
    quoteFollowUp:     { enabled: false, windowDays: 2, graceDays: 1, cooldownDays: 2, maxCount: 2 },
    // Overdue-invoice payment reminders (auto-flag OFF by default)
    paymentReminder:   { enabled: false, graceDays: 3, cooldownDays: 3, maxCount: 3 },
    // Outbound event webhooks (fire on order events; OFF by default)
    eventWebhooks:     { enabled: false, url: '', secret: '', events: { created: true, status: true, paid: true } },
    minOrderAmount:    0,
    rushFeeEnabled:    false,
    rushFeePct:        25,
    // Analysis batch
    wipLimits:            {},           // e.g. { printing: 3, qc: 2 }
    wipEnforceHardLimit:  false,        // when true, block moves that exceed WIP limits
    postProcessPresets:   [],           // [{ name, amount }]
    defaultPackagingCost: 0,
    paymentInstructions:  '',           // Shown in client portal and invoices
    // Job templates — full calculator config presets
    jobTemplates:         [],
    // Resin exposure profile presets
    resinProfiles:        [],
    // Dismissed/snoozed notifications: key → expiresAt ISO string or 'forever'
    dismissedNotifs:      {},
    // Kanban column collapsed state (array of column IDs) — synced with settings to survive backup restore
    kanbanCollapsed:      [],
    // Feature H: Exchange rates — how many base-currency units per 1 foreign unit
    exchangeRates:        {},  // e.g. { USD: 3.75, EUR: 4.12 }
    // Feature I: Email digest scheduler
    emailDigest: {
      enabled: false,
      frequency: 'daily',   // 'daily' | 'weekly'
      hour: 8,              // 0–23, hour of day to send
      weekday: 1,           // 0=Sun…6=Sat, only used when frequency='weekly'
      recipientEmail: '',   // defaults to settings.email if blank
      lastSentDate: '',     // 'YYYY-MM-DD' or 'YYYY-WW' (ISO week), prevents double-send
    },
  };
}


function defaultWaTemplates() {
  return [
    { id: 'tpl-ready',   name: 'Order Ready',      body: 'Hi {{client}}, your order {{id}} is ready! Total: {{price}} {{currency}}. Please arrange pickup or delivery. Thank you!' },
    { id: 'tpl-confirm', name: 'Order Confirmed',   body: 'Hi {{client}}, we\'ve received order {{id}} and it\'s now in our production queue. We\'ll notify you when it\'s ready.' },
    { id: 'tpl-payment', name: 'Payment Reminder',  body: 'Hi {{client}}, gentle reminder: payment of {{price}} {{currency}} is outstanding for order {{id}}. Thank you!' },
  ];
}

/* ---------- App state ---------- */
let printLog   = loadJSON(K.LOG, []);
let machines   = loadJSON(K.MACHINES, []);
let waTemplates = loadJSON(K.WA_TEMPLATES, defaultWaTemplates());
let printers   = loadJSON(K.PRINTERS, []);
let inventory  = loadJSON(K.INV, [
  { id: 'seed-1', material: 'PLA+ 2.0',   cost: 75, weight: 1000 },
  { id: 'seed-2', material: 'Sunlu PETG', cost: 85, weight: 1000 },
  { id: 'seed-3', material: 'Sunlu TPU',  cost: 110, weight: 1000 }
]);
let templates  = loadJSON(K.TPL, []);
let products   = loadJSON(K.PROD, []);
let clients    = loadJSON(K.CLIENTS, []);
let settings   = loadJSON(K.SETTINGS, defaultSettings());
let expenses   = loadJSON(K.EXPENSES, []);
let wasteLog      = loadJSON(K.WASTE, []);
let machMaintLog  = loadJSON(K.MAINT, []);

// currency.js (and other IIFE modules) read `global.settings` / `global.clients`
// off globalThis, but the `let` bindings above are lexical globals that are NOT
// attached to globalThis — so those reads returned undefined and currencySymbol()
// / fmtPrice() silently fell back to SAR. This was invisible in Khayt (SAR is the
// default) but wrong for any other currency (e.g. the Bed Ready flavor defaults
// to USD). Live accessors keep globalThis in sync across every reassignment
// (init / reset / loadStore) without having to touch each assignment site.
Object.defineProperty(globalThis, 'settings', { get: () => settings, set: (v) => { settings = v; }, configurable: true });
Object.defineProperty(globalThis, 'clients',  { get: () => clients,  set: (v) => { clients = v; },  configurable: true });
let consumables   = loadJSON(K.CONSUMABLES, []);
let suppliers     = loadJSON(K.SUPPLIERS, []);
let purchaseOrders = loadJSON(K.PURCHASE_ORDERS, []);
let testPrints     = loadJSON(K.TEST_PRINTS, []);
let locations      = loadJSON(K.LOCATIONS, []);
let operators      = loadJSON(K.OPERATORS, []);
let waitingList    = loadJSON(K.WAITING, []);
let waitingListHistory = loadJSON(K.WAITING_HISTORY, []);
let timeEntries    = loadJSON(K.TIME_ENTRIES, []);
let tombstones     = loadJSON(K.TOMBSTONES, []); // Phase 0 sync: delete markers
let machMaintTasks = loadJSON(K.MAINT_TASKS, []); // recurring preventive-maintenance task defs
let loyaltyLedger  = loadJSON(K.LOYALTY_LEDGER, []); // loyalty points redeem entries

// Batch-2 new arrays
let shiftLogs      = [];
let giftCards      = [];
let slicerProfiles = [];
let envLogs        = [];
let subscriptions  = []; // retainer / subscription plans (recurring revenue)
let auditLog       = []; // append-only team activity log (who did what, when)
let printFiles     = []; // 3.1: standalone print-file library (STL/3MF/gcode + previews)
let filamentDryLog = []; // 3.2 (Bed Ready): filament drying/storage tracker

/* ---------- Lazy id→record indexes ----------
 * O(1) lookups instead of a linear `.find` scan — the difference that keeps lookups fast at
 * the 3,000-order target, especially inside render loops. Each index rebuilds only when its
 * collection's identity or length changes (an add / remove / reassign). Field mutations need
 * no rebuild because the map stores live object *references*; and record ids are immutable
 * primary keys, so an unchanged (ref, length) means the id set is unchanged too. Declared at
 * top level (like the collections) so every renderer script can call them bare.
 */
function _makeIdIndex(getArr) {
  let ref = null, len = -1, map = new Map();
  return (id) => {
    const arr = getArr() || [];
    if (arr !== ref || arr.length !== len) {
      map = new Map();
      for (const x of arr) if (x && x.id != null) map.set(x.id, x);
      ref = arr; len = arr.length;
    }
    return (id == null) ? null : (map.get(id) || null);
  };
}
const orderById = _makeIdIndex(() => printLog);
const clientById = _makeIdIndex(() => clients);
const productById = _makeIdIndex(() => products);
const inventoryById = _makeIdIndex(() => inventory);
const machineById = _makeIdIndex(() => machines);

// Runtime-only state (not persisted)
let kanbanTimerInterval = null;
let activeLocation = null; // Feature 8: null = all locations

// Feature 2 (new batch): Live printer status cache (in-memory only)
let machineStatusCache = {};


// UI state for filters and search
let logSearchTerm = '';
let logClientFilter = '';       // filter logs by specific clientId
let logOperatorFilter = '';
let logDisplayLimit = 100;
let _lastLogFilterHash = '';
let kanSearchTerm = '';
let kanbanCollapsed = new Set(settings?.kanbanCollapsed || []);
let logStatusFilter = '';
let logPayFilter = '';
let logRangeFilter = 'all';
let analyticsRange = 'all';

// Batch selection for the logs table
let selectedOrders = new Set();

// Tag filter for the logs table
let logTagFilter = '';
let logSortCol = 'date';  // 'date' | 'project' | 'price' | 'material' | 'status'
let logSortDir = 'desc';  // 'asc' | 'desc'
let showArchivedOrders = false;
let kanbanSortByPriority = false;

(function (global) {

/**
 * A saved template with this job's facts in it.
 *
 * The SUBSTITUTION is `lib/wa-template.js` — which placeholders exist, and
 * what stands in for a blank — because a template a shop writes here is sent
 * from the Mac app too, and two lists of placeholder names means a message
 * going to a real customer with `{{due}}` printed in it.
 *
 * The FORMATTING stays here: what a price looks like is a currency, a locale
 * and a digit system, and this app's answer is the one the rest of its screen
 * already agrees with.
 */
function fillWaTemplate(body, order, client) {
  const name = client ? localName(client) : (order.project || '');
  return KhaytWaTemplate.fillTemplate(body, {
    client:   name,
    id:       order.id,
    price:    fmtMoney(order.price),
    currency: currencySymbol(),
    due:      order.dueDate,
    status:   t('queue.' + order.status),
  });
}

function sanitiseForAssign(obj) {
  if (!obj || typeof obj !== 'object') return {};
  const clean = {};
  for (const key of Object.keys(obj)) {
    if (key === '__proto__' || key === 'constructor' || key === 'prototype') continue;
    const val = obj[key];
    // Recurse into plain objects so nested __proto__ keys are also stripped
    clean[key] = (val && typeof val === 'object' && !Array.isArray(val)) ? sanitiseForAssign(val) : val;
  }
  return clean;
}
function isValidOrder(o) {
  return o && typeof o === 'object' &&
    typeof o.id === 'string' && o.id.length > 0 &&
    typeof o.date === 'string' &&
    typeof o.status === 'string' &&
    typeof o.project === 'string';
}
function isValidClient(c) {
  return c && typeof c === 'object' && typeof c.id === 'string' && c.id.length > 0;
}
function isValidInventoryItem(i) {
  return i && typeof i === 'object' && typeof i.id === 'string' && i.id.length > 0;
}
function isValidRecord(r) {
  return r && typeof r === 'object' && typeof r.id === 'string' && r.id.length > 0;
}
let _saveAllTimer = null;
let _saveChain = Promise.resolve();

function collectStoreCollections() {
  return {
    printLog, inventory, templates, products, clients, settings, printers,
    expenses, machines, waTemplates, wasteLog, machMaintLog, consumables,
    suppliers, purchaseOrders, testPrints, locations, operators, waitingList,
    waitingListHistory, timeEntries, shiftLogs, giftCards, slicerProfiles, envLogs,
    tombstones, machMaintTasks, loyaltyLedger, subscriptions, auditLog, printFiles,
    filamentDryLog,
  };
}

/** Snapshot current in-memory state as a plain object. */
function buildStoreSnapshot() {
  return KhaytStore.buildSnapshot(collectStoreCollections());
}

/**
 * Point the sync change-index at whichever shop this store now belongs to.
 *
 * Call this after `settings.cloud.shopId` changes — connecting, disconnecting, or
 * switching branch. Connecting and disconnecting are handled as renames inside
 * setScope (same records, new label), so they cost nothing; a move between two
 * real shops genuinely has no fingerprints yet, and seeding here is what keeps
 * the next save from re-stamping the whole store and winning every subsequent
 * conflict against the shop's other devices.
 */
function syncScopeToShop() {
  if (!window.KhaytSync || !KhaytSync.setScope) return;
  try {
    const { seeded } = KhaytSync.setScope(settings?.cloud?.shopId || null);
    if (!seeded) KhaytSync.seedIndex(collectStoreCollections());
  } catch (e) { console.error('syncScopeToShop failed:', e); }
}

/** Build a versioned export/backup payload; optionally redact secrets. */
function buildExportPayload({ redactSecrets = false } = {}) {
  return KhaytStore.buildExportPayload(collectStoreCollections(), { redactSecrets });
}

const redactSettingsForExport = (src) => KhaytStore.redactSettingsForExport(src);
const redactMachinesForExport = (arr) => KhaytStore.redactMachinesForExport(arr);

/** Reset in-memory store then load snapshot (import / full replace). */
/**
 * Replace every collection from a snapshot (restore, import, cloud restore).
 *
 * VALIDATES BEFORE IT DESTROYS. This used to zero all 31 collections unconditionally and
 * only then call applyStoreFromSnapshot(), which early-returns on a falsy, corrupt or
 * unnormalizable snapshot — so picking the wrong .json (or a truncated or empty one)
 * wiped the shop's entire database, applied nothing, and the caller's saveAll() persisted
 * the emptiness under a "restored successfully" toast.
 *
 * Returns true when the snapshot was applied, false when it was refused and NOTHING was
 * touched. Callers must not save or report success on false.
 */
function replaceStoreFromSnapshot(store) {
  if (!store || store.__corrupt) {
    console.error('replaceStoreFromSnapshot: refusing an empty or corrupt snapshot');
    return false;
  }
  /* AND IT MUST BE A KHAYT STORE, not merely valid JSON.
   *
   * normalizeStoreSnapshot SALVAGES: it keeps what it recognises and skips the
   * rest. Handed a file that is not ours it recognises NOTHING and returns a
   * truthy empty object — so this check passed, all 31 collections were zeroed,
   * applyStoreFromSnapshot applied nothing, and the caller toasted success.
   * Picking the wrong .json was enough. */
  if (!KhaytStoreValidate.looksLikeStore(store)) {
    console.error('replaceStoreFromSnapshot: that file is not a Khayt export — nothing replaced');
    return false;
  }
  const { normalized } = KhaytStoreValidate.normalizeStoreSnapshot(store);
  if (!normalized) {
    console.error('replaceStoreFromSnapshot: snapshot could not be normalized — nothing replaced');
    return false;
  }
  /* WHAT BELONGS TO THIS COMPUTER STAYS.
   *
   * A slicer's path and argument template run here, and a restore or import
   * must never change them: a genuine slicer handed another shop's (or an
   * attacker's) arguments runs any command it is told to. And a cloud
   * snapshot carries the mask where the ntfy topic and webhook URLs were, which
   * must not replace the real ones. lib/store-secret-paths.js keepMachineLocal
   * — the Mac's Restore reads the same rule. */
  if (typeof KhaytStoreSecretPaths !== 'undefined' && KhaytStoreSecretPaths.keepMachineLocal) {
    store = KhaytStoreSecretPaths.keepMachineLocal(
      { settings: JSON.parse(JSON.stringify(settings || {})) },
      JSON.parse(JSON.stringify(store)),
      (typeof KhaytStore !== 'undefined' && KhaytStore.SECRET_MASK) || '__KHAYT_MASKED__',
    );
  }
  printLog = [];
  inventory = [];
  templates = [];
  products = [];
  clients = [];
  printers = [];
  expenses = [];
  machines = [];
  waTemplates = defaultWaTemplates();
  wasteLog = [];
  machMaintLog = [];
  consumables = [];
  suppliers = [];
  purchaseOrders = [];
  testPrints = [];
  locations = [];
  operators = [];
  waitingList = [];
  waitingListHistory = [];
  timeEntries = [];
  shiftLogs = [];
  giftCards = [];
  slicerProfiles = [];
  envLogs = [];
  tombstones = [];
  machMaintTasks = [];
  loyaltyLedger = [];
  subscriptions = [];
  auditLog = [];
  printFiles = [];
  filamentDryLog = [];
  settings = defaultSettings();
  applyStoreFromSnapshot(store);
  /* RESEED THE CHANGE INDEX, or the restore deletes the difference everywhere.
   *
   * `_doSave` runs `KhaytSync.stampChanges` on every save, and that treats
   * "in the index, absent from the snapshot in front of me" as a DELETE — it
   * writes a tombstone. The index is seeded at load, on a shop switch and after
   * a cloud merge; a restore reseeded nothing.
   *
   * So restoring a three-week-old backup on the office machine wrote a tombstone
   * for every order, client and invoice created since. Those sync out,
   * applyDeltas deletes unconditionally, and because the tombstone carries the
   * very rev the peer still holds, the delete-over-edit conflict check does not
   * fire either. Three weeks of work vanished from the shop-floor machine with
   * nothing said on either side.
   *
   * After a restore the records that are gone are gone because the SHOP CHOSE an
   * older state — not because anyone deleted them — so the index has to start
   * again from what is now in front of it. */
  try {
    if (window.KhaytSync && KhaytSync.seedIndex) KhaytSync.seedIndex(collectStoreCollections());
  } catch (e) { console.error('reseed after restore failed:', e); }
  return true;
}

function ensureOrderTrackingTokens() {
  let changed = false;
  for (const o of printLog) {
    if (!o?.trackingToken) {
      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      o.trackingToken = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
      changed = true;
    }
  }
  if (changed) saveAll();
}

/** Load all collections from a store snapshot (disk load or import). */
function applyStoreFromSnapshot(store) {
  if (!store) return;
  if (store.__corrupt) return;
  const { normalized, warnings } = KhaytStoreValidate.normalizeStoreSnapshot(store);
  if (!normalized) return;
  if (warnings.length) console.warn('applyStoreFromSnapshot:', warnings.join('; '));
  store = normalized;
  const isObj = x => x && typeof x === 'object';
  if (store.printLog)       printLog       = store.printLog.filter(isValidOrder);
  if (store.inventory)      inventory      = store.inventory.filter(isValidRecord);
  if (store.templates)      templates      = store.templates.filter(isValidRecord);
  if (store.products)       products       = store.products.filter(isValidRecord);
  if (store.clients)        clients        = store.clients.filter(isValidClient);
  if (store.printers)       printers       = store.printers.filter(isObj);
  if (store.expenses)       expenses       = store.expenses.filter(isObj);
  if (store.machines)       machines       = store.machines.filter(isValidRecord);
  if (store.waTemplates)    waTemplates    = store.waTemplates.filter(isValidRecord);
  if (store.wasteLog)       wasteLog       = store.wasteLog.filter(isObj);
  if (store.machMaintLog)   machMaintLog   = store.machMaintLog.filter(isObj);
  if (store.consumables)    consumables    = store.consumables.filter(isValidRecord);
  if (store.suppliers)      suppliers      = store.suppliers.filter(isValidRecord);
  if (store.purchaseOrders) purchaseOrders = store.purchaseOrders.filter(isValidRecord);
  if (store.testPrints)     testPrints     = store.testPrints.filter(isObj);
  if (store.locations)      locations      = store.locations.filter(isValidRecord);
  if (store.operators)           operators           = store.operators.filter(isValidRecord);
  if (store.waitingList)         waitingList         = store.waitingList.filter(isValidRecord);
  if (store.waitingListHistory)  waitingListHistory  = store.waitingListHistory.filter(isObj);
  if (store.timeEntries)         timeEntries         = store.timeEntries.filter(isObj);
  if (store.shiftLogs)           shiftLogs           = store.shiftLogs.filter(isObj);
  if (store.giftCards)           giftCards           = store.giftCards.filter(isObj);
  if (store.slicerProfiles)      slicerProfiles      = store.slicerProfiles.filter(isObj);
  if (store.envLogs)             envLogs             = store.envLogs.filter(isObj);
  if (store.tombstones)          tombstones          = store.tombstones.filter(isObj);
  if (store.machMaintTasks)      machMaintTasks      = store.machMaintTasks.filter(isValidRecord);
  if (store.loyaltyLedger)       loyaltyLedger       = store.loyaltyLedger.filter(isObj);
  if (store.subscriptions)       subscriptions       = store.subscriptions.filter(isObj);
  if (store.auditLog)            auditLog            = store.auditLog.filter(isObj);
  if (store.printFiles)          printFiles          = store.printFiles.filter(isValidRecord);
  if (store.filamentDryLog)      filamentDryLog      = store.filamentDryLog.filter(isValidRecord);
  if (store.settings)            settings            = Object.assign({}, defaultSettings(), sanitiseForAssign(store.settings));
  migrateLanApiSettings();
  migrateLegacyDesignTheme();
  if (store.settings) {
    const nested = ['emailDigest', 'emailConfig', 'smsConfig', 'accountingSync', 'zatcaPhase2', 'bnpl', 'lanApi', 'exchangeRates', 'printerApi', 'quoteFollowUp', 'paymentReminder', 'eventWebhooks'];
    const isPlainObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
    for (const key of nested) {
      if (isPlainObj(store.settings[key])) {
        const dflt = defaultSettings()[key] || {};
        const merged = Object.assign({}, dflt, sanitiseForAssign(store.settings[key]));
        // Second level: re-merge sub-objects (e.g. bnpl.tabby) so a stored partial
        // child keeps its sibling defaults (merchantCode/currency) instead of
        // replacing the whole child object.
        for (const sub of Object.keys(merged)) {
          if (isPlainObj(dflt[sub]) && isPlainObj(store.settings[key][sub])) {
            merged[sub] = Object.assign({}, dflt[sub], sanitiseForAssign(store.settings[key][sub]));
          }
        }
        settings[key] = merged;
      }
    }
  }
}

/** Write the store snapshot to disk; serializes concurrent saves (last snapshot wins). */
function _doSave(snapshot) {
  if (!window.hubAPI?.saveStore) return Promise.resolve();
  // Phase 0 sync foundation: stamp rev/updatedAt on changed records + tombstone
  // deletes, in place, before persisting. No-op-safe if the module isn't loaded.
  try { if (window.KhaytSync) KhaytSync.stampChanges(snapshot); } catch (e) { console.error('stampChanges failed:', e); }
  _saveChain = _saveChain
    .then(() => window.hubAPI.saveStore(snapshot))
    .then((res) => {
      // hub:save-store RETURNS { ok:false, error } for a disk-full write, a permissions
      // error, an oversized store or an unrecoverable shape — it does not reject. Only
      // inspecting rejection meant every one of those failed silently: the UI showed the
      // order saved and the shop lost the work at next launch.
      if (res && res.ok === false) throw new Error(res.error || 'save failed');
    })
    .catch((e) => {
      console.error('Save failed:', e);
      const detail = e && e.message ? ` — ${e.message}` : '';
      toast('⚠ ' + (t('common.save_failed') || 'Save failed — check disk space') + detail, 'error', 10000);
    });
  // Stage C: when Khayt Cloud is connected + unlocked, push changes in the
  // background (debounced + conflict-merging). No-op when cloud is off.
  try { if (window.KhaytCloudSync && KhaytCloudSync.isOn()) KhaytCloudSync.scheduleSync(); } catch (e) { console.error('cloud scheduleSync failed:', e); }
  return _saveChain;
}

function saveAll() {
  // Debounce: coalesce rapid successive saves into one disk write (300 ms window)
  if (_saveAllTimer) clearTimeout(_saveAllTimer);
  _saveAllTimer = setTimeout(() => {
    _saveAllTimer = null;
    _doSave(buildStoreSnapshot());
  }, 300);
}

/**
 * Cancel any pending debounced save and write to disk immediately.
 * Returns a Promise that resolves when the write is complete.
 * Use before quitting (update install, app close, etc.) to avoid data loss.
 */
function flushSave() {
  if (_saveAllTimer) { clearTimeout(_saveAllTimer); _saveAllTimer = null; }
  return _doSave(buildStoreSnapshot());
}

function migrateFromLocalStorage() {
  try {
    const store = {};
    const keyMap = {
      printLog:       K.LOG,
      inventory:      K.INV,
      templates:      K.TPL,
      products:       K.PROD,
      clients:        K.CLIENTS,
      settings:       K.SETTINGS,
      printers:       K.PRINTERS,
      expenses:       K.EXPENSES,
      machines:       K.MACHINES,
      waTemplates:    K.WA_TEMPLATES,
      wasteLog:       K.WASTE,
      machMaintLog:   K.MAINT,
      consumables:    K.CONSUMABLES,
      suppliers:      K.SUPPLIERS,
      purchaseOrders: K.PURCHASE_ORDERS,
    };
    for (const [name, key] of Object.entries(keyMap)) {
      try {
        const raw = localStorage.getItem(key);
        if (raw) store[name] = safeJsonParse(raw);
      } catch(e) {}
    }
    if (Object.keys(store).length > 0) {
      return store;
    }
  } catch(e) {}
  return null;
}

async function loadAll() {
  let store = null;
  try {
    store = await window.hubAPI.loadStore();
  } catch(e) {}

  if (store && store.__corrupt) {
    console.error('Store corruption detected:', store.error);
    setTimeout(() => toast(t('store.unreadable'), 'error', 10000), 1500);
    store = null;
  } else if (store && store.__recovered) {
    // The main process recovered from a completed temp write or the previous
    // generation after the primary file was unreadable.
    //
    // This used to be a green tick reading "Recovered your data" no matter which
    // copy was used. Recovering from `.prev` means the LAST SAVE IS GONE — that is
    // real loss, and a tick is the wrong thing to show over it. Say which copy came
    // back and when it was written, so the shop knows whether to check its work.
    const at = Number(store.__recoveredAt) || 0;
    const when = at ? new Date(at).toLocaleString() : '';
    const msg = store.__recovered === 'prev'
      ? (when
          ? `${t('store.recovered_prev')} (${when})`
          : t('store.recovered_prev'))
      : t('store.recovered');
    const tone = store.__recovered === 'prev' ? 'error' : 'success';
    setTimeout(() => toast(msg, tone, 12000), 1500);
  }

  if (!store) {
    store = migrateFromLocalStorage();
  }

  if (store) applyStoreFromSnapshot(store);

  // One-time migration: pull localStorage kanban state into settings
  const legacyCollapsed = localStorage.getItem('khayt_kan_collapsed');
  if (legacyCollapsed && !settings.kanbanCollapsed?.length) {
    try {
      settings.kanbanCollapsed = safeJsonParse(legacyCollapsed);
      localStorage.removeItem('khayt_kan_collapsed');
      saveAll(); // persist the migration
    } catch {}
  }

  // Sync in-memory kanbanCollapsed Set from settings (ensures restore doesn't cause desync)
  kanbanCollapsed = new Set(settings.kanbanCollapsed || []);

  // One-time migration (Bug A): de-duplicate any colliding order/quote ids.
  // Quotes historically reused the invoice counter without advancing it, so two
  // quotes could share an id — and id is the primary key for every lookup.
  (function dedupeOrderIds() {
    if (settings._idDedupeDone) return;
    const seen = new Set();
    const remap = {};
    for (const o of printLog) {
      if (!o || !o.id) continue;
      if (seen.has(o.id)) {
        const oldId = o.id;
        let n = 2;
        let candidate = `${oldId}-${n}`;
        while (seen.has(candidate)) { n++; candidate = `${oldId}-${n}`; }
        o.id = candidate;
        remap[oldId] = remap[oldId] || [];
        remap[oldId].push(candidate);
      }
      seen.add(o.id);
    }
    // Seed the quote counter past the highest existing quote number for this year
    // so freshly-minted quotes don't immediately collide with pre-existing ones.
    const yr = new Date().getFullYear();
    const qPrefix = settings.quotePrefix || 'QUO';
    let maxQ = 0;
    for (const o of printLog) {
      const m = (o.id || '').match(new RegExp('^' + qPrefix + '-' + yr + '-(\\d+)'));
      if (m) maxQ = Math.max(maxQ, parseInt(m[1], 10) || 0);
    }
    if (settings.quoteNumNext === undefined || (settings.quoteNumYear === yr && settings.quoteNumNext <= maxQ)) {
      settings.quoteNumYear = yr;
      settings.quoteNumNext = maxQ + 1;
    }
    settings._idDedupeDone = true;
    if (Object.keys(remap).length) {
      console.warn('[migration] de-duplicated colliding order ids:', remap);
      saveAll();
    }
  })();

  ensureOrderTrackingTokens();

  /* Deposits stranded on jobs split before the money fix.
   *
   * A split parent is now excluded from what is owed — correct, its children
   * carry the debt — but a job split BEFORE that change left every sub-order at
   * paidAmount 0 with the deposit recorded on the parent, so excluding it
   * credited the money to nothing. SAR 3,000 read as outstanding on a job with
   * SAR 2,000 left to pay. Better than the SAR 5,000 it used to say, and still a
   * customer chased for money they had paid.
   *
   * Idempotent by an explicit marker on the parent, and it refuses in every
   * uncertain case — see migrateSplitDeposits. Runs BEFORE the sync backfill so
   * the changed records are stamped and pushed like any other edit. */
  try {
    if (typeof KhaytSplitOrder !== 'undefined' && typeof printLog !== 'undefined') {
      const r = KhaytSplitOrder.migrateSplitDeposits(printLog);
      if (r.migrated) {
        console.warn(`[split] moved ${r.moved} of deposits onto the sub-orders of ${r.migrated} split job(s)`);
        if (typeof toast === 'function') {
          setTimeout(() => toast(t('ord.split_deposit_moved', { n: r.migrated })
            || `Deposits on ${r.migrated} previously split job(s) were credited to their sub-orders`, 'info', 9000), 2000);
        }
      }
    }
  } catch (e) { console.error('split deposit migration failed:', e); }

  // Phase 0 sync foundation: backfill change metadata (rev/updatedAt) for records
  // that predate it, then seed the in-memory index from the final loaded state so
  // the next save only stamps records that actually changed (no churn on restart).
  try {
    if (window.KhaytSync) {
      KhaytSync.backfill(collectStoreCollections());
      // Name the scope BEFORE seeding, so the fingerprints land under this shop's
      // id rather than under the unnamed default and have to be moved later.
      if (KhaytSync.setScope) KhaytSync.setScope(settings?.cloud?.shopId || null);
      KhaytSync.seedIndex(collectStoreCollections());
    }
  } catch (e) { console.error('sync foundation init failed:', e); }

  // Records the old merge bug brought back after they were deleted. The fix
  // stops new ones; it cannot undo what is already on disk, so say so rather
  // than leaving the shop to find out. Report-only — see findResurrected().
  if (typeof reportResurrectedRecords === 'function') reportResurrectedRecords();

  /* Two things a shop upgrading from an earlier build meets in its OWN data.
   *
   * Both are consequences of money fixes in this release, and both are
   * REPORT-ONLY, for different reasons:
   *
   *  - An instalment plan written before the deposit fix split the gross price,
   *    so it asks for more than the order still owes. A schedule is an agreement
   *    the shop may have put in writing; rewriting the amounts silently would be
   *    worse than saying so.
   *  - Points used to be earned on cancelled, personal and fully refunded jobs.
   *    Correcting that lowers what a client has EARNED, and the balance clamps at
   *    zero — so a customer who was told they had points now has none, quietly.
   *    Re-inflating it would perpetuate a liability the shop does not owe.
   *
   * Announced when the set CHANGES, not on every launch: nagging each start
   * trains the owner to dismiss it, and announcing once ever is missed by anyone
   * who was not looking that day. Same rule as reportResurrectedRecords. */
  try { if (typeof reportLegacyMoneyState === 'function') reportLegacyMoneyState(); }
  catch (e) { console.error('legacy money report failed:', e); }

  // Feature 4 (batch-2): Process any due recurring orders on load.
  // Guarded: the Bed Ready flavor ships no operations-extras module.
  if (typeof processRecurringOrders === 'function') processRecurringOrders();

  // Quote follow-up auto-nudge (opt-in): run once on load + start periodic timer.
  if (typeof processQuoteFollowUps === 'function') processQuoteFollowUps();
  if (typeof startQuoteFollowUpTimer === 'function') startQuoteFollowUpTimer();
  // Overdue-invoice payment reminders (opt-in): same cadence.
  if (typeof processPaymentReminders === 'function') processPaymentReminders();
  if (typeof startPaymentReminderTimer === 'function') startPaymentReminderTimer();
}

function pruneExpiredNotifs() {
  const dismissed = settings.dismissedNotifs;
  if (!dismissed || typeof dismissed !== 'object') return;
  const now = new Date().toISOString();
  let changed = false;
  for (const key of Object.keys(dismissed)) {
    const val = dismissed[key];
    if (val !== 'forever' && val < now) {
      delete dismissed[key];
      changed = true;
    }
  }
  if (changed) saveAll();
}

  const api = {
    defaultSettings,
    defaultWaTemplates,
    fillWaTemplate,
    collectStoreCollections,
    buildStoreSnapshot,
    buildExportPayload,
    // Called BARE (not behind a typeof guard) from settings.js, by all three
    // ways a shop gets a shop id: sign-up, log-in and join-a-team. Missing from
    // this list, that is a ReferenceError mid-handler — the account is assigned
    // in memory, the saveAll() on the next line never runs, and the panel sits
    // on "Connecting…" forever with nothing logged where the shop can see it.
    // Reported exactly that way: "trying to log onto the cloud and stuck at
    // connecting". test/cross-file-wiring.test.js now checks bare calls too.
    syncScopeToShop,
    applyStoreFromSnapshot,
    replaceStoreFromSnapshot,
    ensureOrderTrackingTokens,
    saveAll,
    flushSave,
    migrateFromLocalStorage,
    loadAll,
    pruneExpiredNotifs,
    sanitiseForAssign,
    isValidOrder,
    isValidClient,
    isValidInventoryItem,
    isValidRecord,
    // Both are called from other files behind `typeof X === 'function'`, which
    // this IIFE made permanently false. inventory.js printed labels with the
    // raw, unsanitised HTML as its fallback; online.js showed a masked PIN as
    // though it were the real one. test/cross-file-wiring.test.js now checks the
    // whole class rather than these two.
    sanitizePrintHtml,
    isSecretMasked,
  };
  Object.assign(global, api);
  global.KhaytAppState = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
