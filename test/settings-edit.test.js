/**
 * lib/settings-edit.js is the settings save, lifted out of the renderer.
 *
 * THE PROOF METHOD: the original `saveSettingsFromForm` literal is copied below
 * VERBATIM — every `$('#set_…')` read, every clamp, every `|| default` — and
 * run against a fake page built from the same form the module is handed. Both
 * results are compared field for field over thousands of generated shops and
 * forms. A clamp that moved, a default that changed, a key the module forgot
 * to preserve: any of them shows up as a diff on a concrete input.
 *
 * The one deliberate change (a key the form does not carry keeps its value)
 * is outside the comparison — the original throws on a missing control, so
 * there is no behaviour to compare — and has its own tests below.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const KhaytTax = require('../lib/tax.js');
const { apply, chooseCountry, DAYS, WIP_COLUMNS, DEFAULT_EXPENSE_CATEGORIES } = require('../lib/settings-edit.js');

// ---------------------------------------------------------------------------
// The original, verbatim, from renderer/settings.js as of the lift (#969).
// Only the closing was changed: `saveAll()` and the screen refreshes that
// followed the literal are the host's and are not part of the rule.
// ---------------------------------------------------------------------------
const ORIGINAL = `
function saveSettingsFromForm() {
  const accepted = $$('#acceptedPaymentsList input[data-pm]')
    .filter(cb => cb.checked).map(cb => cb.dataset.pm);
  settings = {
    /* START FROM WHAT IS ALREADY THERE.
     *
     * This literal REPLACES settings wholesale, so every key it does not name
     * is destroyed — silently, on a save the shop made for an unrelated reason.
     * The hand-maintained "preserve" entries further down are what that costs:
     * a list that has to be extended every time anyone adds a setting, and was
     * not. Nineteen keys were being dropped by the time this was found,
     * including \`cloud\` — so entering a business name signed the shop out of
     * Khayt Cloud and destroyed its sync keyset — plus \`slicers\`, the \`privacy\`
     * choices, and the migration flags, which then re-ran.
     *
     * Spreading first makes omission the safe case. The explicit entries below
     * still win; several of them do real work (lanApi migrates, tax recomputes,
     * wipLimits rebuilds) and are not merely preserving.
     */
    ...settings,
    /* The shop's own text, per language, read from whatever fields are on
     * screen — business name, tagline, address, invoice footer and terms. They
     * were ten hard-coded lines here, which is why a shop could only ever have
     * an English and an Arabic one. A language the shop has stopped using keeps
     * whatever it had: removing a language must not erase the text. */
    ...readContentFields(),
    vat:       $('#set_vat').value.trim(),
    cr:        $('#set_cr').value.trim(),
    phone:     $('#set_phone').value.trim(),
    email:     $('#set_email').value.trim(),
    lang:      $('#set_lang').value,
    theme:       $('#set_theme').value,
    designTheme: $('#set_designTheme')?.value || settings.designTheme || 'studio',
    accent:      $('#set_accent')?.value || settings.accent || 'cyan',
    invPrefix: $('#set_invPrefix').value.trim() || 'INV',
    autoDeduct: $('#set_autoDeduct').checked,
    lowStockThreshold: Math.max(0, num($('#set_lowStock').value, 200)),
    // 1.3 additions
    bankName:      $('#set_bankName').value.trim(),
    accountHolder: $('#set_accountHolder').value.trim(),
    iban:          $('#set_iban').value.trim().replace(/\\s+/g, ''),
    acceptedPayments: accepted,
    useHijri:      $('#set_useHijri').checked,
    useArabicNumerals: $('#set_useArabicNumerals').checked,
    autoBackup:    $('#set_autoBackup').checked,
    // Written by the folder pickers, not by a field the shop can mistype — a
    // path typed by hand is a path that silently does not exist.
    printLibrary:  settings.printLibrary || {},
    // Same reason as printLibrary above: kits are written by the log's batch bar,
    // not by any field on this page, so rebuilding settings from the form would
    // drop them — silently, on the next unrelated Settings save.
    kits:          settings.kits || [],
    coachTips:     $('#set_coachTips') ? $('#set_coachTips').checked : (settings.coachTips !== false),
    enableVat:     $('#set_enableVat').checked,
    vatRate:       Math.max(0, num($('#set_vatRate').value, 15)),
    bizLogo:       settings.bizLogo || '',
    invAccentColor:$('#set_invAccent').value || '#5E2E14',
    invTemplate:   $('#set_invTemplate')?.value || 'classic',
    invoiceBilingual: $('#set_invoiceBilingual')?.value || 'auto',
    // Falls back to the stored value, not to a literal: the picker is hidden
    // while a document is single-language or ZATCA-pinned, and a hidden control
    // must not quietly reset a choice the owner made earlier.
    invoiceSecondLang: $('#set_invoiceSecondLang')?.value || settings.invoiceSecondLang || 'ar',
    // Reset writes '' while the picker still shows the default colour, so an
    // untouched picker must not silently re-pin that default as an override.
    // This must compare against whatever the picker uses as its default, which
    // is now the theme's colour. Leaving a literal here while the swatch shows
    // the theme's would make an untouched picker read as a deliberate choice
    // and persist it — pinning that theme's colour so low stock stopped
    // following a later theme change.
    lowStockColor: (settings.lowStockColor === ''
      && $('#set_lowStockColor')?.value === themeLowStockColor())
      ? '' : ($('#set_lowStockColor')?.value || ''),
    quotePrefix:   $('#set_quotePrefix').value.trim() || 'QUO',
    useIcloud:     $('#set_useIcloud').checked,
    monthlyGoal:   Math.max(0, num($('#set_monthlyGoal').value, 0)),
    supplierPhone: $('#set_supplierPhone').value.trim(),
    // 2.0 worldwide / regional
    currency:      $('#set_currency')?.value    || 'SAR',
    enableZatca:   !!$('#set_enableZatca')?.checked,
    // Written from the live profile so the legacy VAT fields above and the tax
    // profile can never drift apart into two different answers.
    tax: (() => {
      const prof = KhaytTax.profileFromSettings(settings);
      const mode = $('#set_taxMode')?.value || prof.mode;
      const rate = +$('#set_vatRate')?.value;
      const enabled = !!$('#set_enableVat')?.checked;
      const rates = (settings.tax?.rates?.length && settings.tax.rates.length > 1)
        ? settings.tax.rates
        : (enabled && rate > 0 ? [{ id: 'vat', label: prof.rates[0]?.label || 'VAT', percent: rate }] : []);
      return { country: $('#set_taxCountry')?.value || settings.tax?.country || '',
               name: prof.name, registration: prof.registration, mode, rates };
    })(),
    firstRunDone:  true,
    // Operational settings
    minMarginPct:  Math.max(0, Math.min(100, num($('#set_minMarginPct')?.value, 0))),
    expBudgets:    Object.fromEntries(EXP_CATEGORIES.map(c => [c, Math.max(0, num($(\`#set_budget_\${c}\`)?.value, 0))])),
    postChecklist: settings.postChecklist || [],
    // Invoice numbering (managed by renderInvoiceNumberingSection — preserve as-is)
    invNumPrefix:  settings.invNumPrefix  || 'INV',
    invNumYear:    settings.invNumYear    || new Date().getFullYear(),
    invNumNext:    settings.invNumNext    || 1,
    invNumFormat:  settings.invNumFormat  || '{prefix}-{year}-{seq4}',
    // New Feature 7: Working hours
    workingHours: Object.fromEntries(
      ['mon','tue','wed','thu','fri','sat','sun'].map(d => [d, Math.max(0, Math.min(24, num($(\`#wh_\${d}\`)?.value, 0)))])
    ),
    holidays: settings.holidays || [],
    // Business Mode — preserve current mode/firstRun (changed via mode toggle buttons)
    mode:      settings.mode      || 'professional',
    firstRun:  false,
    customFields: settings.customFields || [],
    // Feature 5 (new 8-pack): Email config — managed by renderEmailNotificationSettings, preserve as-is
    emailConfig: settings.emailConfig || { provider: 'none', apiKey: '', fromEmail: '', fromName: '', domain: '', triggers: [] },
    // SMS/WhatsApp config — managed by renderSmsNotificationSettings, preserve as-is
    smsConfig: settings.smsConfig || { provider: 'none', channel: 'whatsapp' },
    // Accounting sync — managed by renderAccountingSyncSettings, preserve as-is
    accountingSync: settings.accountingSync || { enabled: false, format: 'generic', webhookUrl: '', secret: '', pushOnPaid: true },
    // Payment providers — managed by renderIntegrationsSettings, preserve as-is
    paymentProviders: settings.paymentProviders || {},
    // Feature 7 (new 8-pack): Operator lock
    operatorLockEnabled: !!$('#set_operatorLock')?.checked,
    activeOperatorId: settings.activeOperatorId || null,
    // Feature 8 (new 8-pack): Loyalty tiers
    loyaltyEnabled: !!$('#set_loyaltyEnabled')?.checked,
    loyaltyTiers:   settings.loyaltyTiers || [],
    // Batch-2 Feature 10: Telegram — preserved from renderTelegramSettings
    telegram: settings.telegram || { botToken: '', chatId: '', notifyOnComplete: false, notifyOnHold: false, notifyOnLowStock: false, notifyPrinterError: true, notifyPrinterOffline: true, notifyPrinterStall: false },
    // Round 12 — preserve managed-in-place settings
    webhooks:     settings.webhooks     || { enabled: false, secret: '', events: {} },
    fixedCosts:   settings.fixedCosts   || [],
    savedFilters: settings.savedFilters || [],
    // Payment instructions (textarea, not auto-included by DOM reconstruction)
    paymentInstructions: $('#set_paymentInstructions')?.value ?? settings.paymentInstructions ?? '',
    betaAcknowledged: true, // legacy field — always true, beta phase is over
    betaUpdates:       !!$('#set_betaUpdates')?.checked,
    // Easy-wins batch: Calculator
    quoteValidityDays: Math.max(1, num($('#set_quoteValidityDays')?.value, 7)),
    /* Delivery estimates. Clamped to the same ranges the cloud endpoint enforces,
       so a value that would be refused on publish is refused here where somebody
       can see why — rather than silently failing to publish later.
       \`staleAfterHours\` is not on the form: it is how long the shop's own figure
       should be believed for, which is a property of the publish schedule rather
       than a business decision, so it is preserved rather than edited. */
    leadTime: {
      ...(settings.leadTime || {}),
      dailyHours:         Math.max(1, Math.min(24, num($('#set_leadDailyHours')?.value, 8))),
      workingDaysPerWeek: Math.max(1, Math.min(7, num($('#set_leadDaysPerWeek')?.value, 5))),
      finishingDays:      Math.max(0, Math.min(90, num($('#set_leadFinishingDays')?.value, 1))),
      dispatchDays:       Math.max(0, Math.min(90, num($('#set_leadDispatchDays')?.value, 1))),
      safetyDays:         Math.max(0, Math.min(90, num($('#set_leadSafetyDays')?.value, 1))),
      publishToCloud:     !!$('#set_leadPublish')?.checked,
    },
    // Quote follow-up automation — preserve advanced fields, update toggle + window from form
    quoteFollowUp: {
      ...(settings.quoteFollowUp || { graceDays: 1, cooldownDays: 2, maxCount: 2 }),
      enabled:    !!$('#set_quoteFollowUpEnabled')?.checked,
      windowDays: Math.max(0, Math.min(60, num($('#set_quoteFollowUpWindow')?.value, 2))),
    },
    paymentReminder: {
      ...(settings.paymentReminder || { cooldownDays: 3, maxCount: 3 }),
      enabled:   !!$('#set_payReminderEnabled')?.checked,
      graceDays: Math.max(0, Math.min(90, num($('#set_payReminderGrace')?.value, 3))),
    },
    minOrderAmount:    Math.max(0, num($('#set_minOrderAmount')?.value, 0)),
    rushFeeEnabled:    !!$('#set_rushFeeEnabled')?.checked,
    rushFeePct:        Math.max(0, Math.min(500, num($('#set_rushFeePct')?.value, 25))),
    defaultPackagingCost: Math.max(0, num($('#set_defaultPackagingCost')?.value, 0)),
    // WIP limits
    wipLimits: (() => {
      const wip = { ...(settings.wipLimits || {}) };
      ['pending', 'printing', 'post', 'qc'].forEach(col => {
        const v = num($(\`#set_wip_\${col}\`)?.value, 0);
        if (v > 0) wip[col] = v;
        else delete wip[col];
      });
      return wip;
    })(),
    wipEnforceHardLimit: !!$('#set_wipEnforceHardLimit')?.checked,
    // QC / reprint / RMA
    qc: {
      enabled:            !!$('#set_qcEnabled')?.checked,
      requireInspector:   !!$('#set_qcRequireInspector')?.checked,
      requirePhotoOnFail: !!$('#set_qcRequirePhotoOnFail')?.checked,
      warrantyDays:       Math.max(0, num($('#set_qcWarrantyDays')?.value, 30)),
    },
    // Preserve fields managed outside this form — never silently drop them
    zatcaPhase2:        settings.zatcaPhase2        || {},
    emailDigest:        settings.emailDigest        || {},
    bnpl:               settings.bnpl               || {},
    exchangeRates:      settings.exchangeRates       || {},
    exchangeRatesUpdatedAt: settings.exchangeRatesUpdatedAt ?? null,
    staleHours:         settings.staleHours          || {},
    productionPaused:   settings.productionPaused    || false,
    pauseReason:        settings.pauseReason         || '',
    pausedAt:           settings.pausedAt            ?? null,
    filamentColours:    settings.filamentColours     || {},
    jobTemplates:       settings.jobTemplates        || [],
    postProcessPresets: settings.postProcessPresets  || [],
    resinProfiles:      settings.resinProfiles       || [],
    dismissedNotifs:    settings.dismissedNotifs     || {},
    kanbanCollapsed:    settings.kanbanCollapsed     || [],
    donationUrl:        settings.donationUrl         || '', // legacy — UI removed; preserve on save
    printerApi:         settings.printerApi          || {},
    locations:          settings.locations           || [],
    lanApi: (() => { migrateLanApiSettings(); return settings.lanApi || { enabled: false, port: 3219, pin: '' }; })(),
    // Preserve fields not edited by this form — never silently drop them
    onlineEnabled:        !!settings.onlineEnabled,
    securityEnabled:      !!settings.securityEnabled,
    recoveryCodeHash:     settings.recoveryCodeHash || '',
    recoveryCodeCreatedAt: settings.recoveryCodeCreatedAt || '',
    quoteNumYear:         settings.quoteNumYear ?? new Date().getFullYear(),
    quoteNumNext:         settings.quoteNumNext ?? 1,
  };
  return settings;
}
`;

/** Run the original over a fake page that answers `$` from a form. */
function runOriginal(settings, form, ctx) {
  const els = new Map();
  const put = (id, el) => els.set('#' + id, el);
  const text = (k) => { if (form[k] !== undefined) put('set_' + k, { value: form[k] }); };
  const check = (id, v) => { if (v !== undefined) put(id, { checked: !!v }); };
  for (const k of ['vat', 'cr', 'phone', 'email', 'lang', 'theme', 'designTheme', 'accent', 'invPrefix',
                   'lowStock', 'bankName', 'accountHolder', 'iban', 'vatRate', 'invAccent', 'invTemplate',
                   'invoiceBilingual', 'invoiceSecondLang', 'lowStockColor', 'quotePrefix', 'monthlyGoal',
                   'supplierPhone', 'currency', 'taxMode', 'taxCountry', 'minMarginPct', 'paymentInstructions',
                   'quoteValidityDays', 'minOrderAmount', 'rushFeePct', 'defaultPackagingCost']) text(k);
  for (const k of ['autoDeduct', 'useHijri', 'useArabicNumerals', 'autoBackup', 'coachTips', 'enableVat',
                   'useIcloud', 'enableZatca', 'operatorLock', 'loyaltyEnabled', 'betaUpdates',
                   'rushFeeEnabled', 'wipEnforceHardLimit']) check('set_' + k, form[k]);
  for (const c of DEFAULT_EXPENSE_CATEGORIES) put('set_budget_' + c, { value: form.budgets[c] });
  for (const d of DAYS) put('wh_' + d, { value: form.workingHours[d] });
  for (const col of WIP_COLUMNS) put('set_wip_' + col, { value: form.wip[col] });
  const lt = form.leadTime;
  put('set_leadDailyHours', { value: lt.dailyHours });
  put('set_leadDaysPerWeek', { value: lt.workingDaysPerWeek });
  put('set_leadFinishingDays', { value: lt.finishingDays });
  put('set_leadDispatchDays', { value: lt.dispatchDays });
  put('set_leadSafetyDays', { value: lt.safetyDays });
  check('set_leadPublish', lt.publishToCloud);
  check('set_quoteFollowUpEnabled', form.quoteFollowUp.enabled);
  put('set_quoteFollowUpWindow', { value: form.quoteFollowUp.windowDays });
  check('set_payReminderEnabled', form.paymentReminder.enabled);
  put('set_payReminderGrace', { value: form.paymentReminder.graceDays });
  check('set_qcEnabled', form.qc.enabled);
  check('set_qcRequireInspector', form.qc.requireInspector);
  check('set_qcRequirePhotoOnFail', form.qc.requirePhotoOnFail);
  put('set_qcWarrantyDays', { value: form.qc.warrantyDays });

  const scope = {
    $: (sel) => els.get(sel) || null,
    $$: (sel) => sel === '#acceptedPaymentsList input[data-pm]'
      ? form.acceptedPayments.map((pm) => ({ checked: true, dataset: { pm } })) : [],
    settings: JSON.parse(JSON.stringify(settings)),
    readContentFields: () => ({ ...form.content }),
    num: (v, fallback = 0) => { const n = parseFloat(v); return Number.isFinite(n) ? n : fallback; },
    KhaytTax,
    EXP_CATEGORIES: DEFAULT_EXPENSE_CATEGORIES,
    migrateLanApiSettings: () => {},
    themeLowStockColor: () => ctx.themeLowStockColor,
  };
  const fn = new Function(...Object.keys(scope), ORIGINAL + '\nreturn saveSettingsFromForm();');
  return fn(...Object.values(scope));
}

// ---------------------------------------------------------------------------
// Generated shops and forms
// ---------------------------------------------------------------------------
function rng(seed) {
  let x = seed >>> 0 || 1;
  return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];
const maybe = (r, v, p = 0.5) => (r() < p ? v : undefined);
/** What a text or number control can hold: blanks, padding, junk, extremes. */
const value = (r) => pick(r, ['', '  ', ' x ', 'abc', '0', '-5', '7', '15', '99.5', '999', '24', '1e3', 'NaN', '  9  ', 'SA03 8000 0000 6080 1016 7519']);
const flag = (r) => r() < 0.5;

function someSettings(r) {
  const s = {};
  if (r() < 0.7) s.cloud = { token: 'T', keyset: 'K' };
  if (r() < 0.5) s.slicers = ['orca'];
  if (r() < 0.5) s.privacy = { crash: true };
  if (r() < 0.5) s.__designV26Migrated = true;
  if (r() < 0.5) s.vatRate = pick(r, [0, 5, 15, '15', 'x']);
  if (r() < 0.5) s.enableVat = flag(r);
  if (r() < 0.5) s.tax = pick(r, [
    { country: 'SA', name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] },
    { country: 'IN', name: 'GST', mode: 'exclusive', registration: 'GSTIN', rates: [{ id: 'c', label: 'CGST', percent: 9 }, { id: 's', label: 'SGST', percent: 9 }] },
    { country: '', name: 'Tax', mode: 'inclusive', registration: 'Tax No.', rates: [] },
  ]);
  if (r() < 0.5) s.lowStockColor = pick(r, ['', '#f5a623', '#123456']);
  if (r() < 0.5) s.invoiceSecondLang = pick(r, ['', 'ar', 'fr']);
  if (r() < 0.5) s.designTheme = pick(r, ['', 'workbench']);
  if (r() < 0.5) s.coachTips = flag(r);
  if (r() < 0.5) s.leadTime = { staleAfterHours: 6, dailyHours: 10 };
  if (r() < 0.5) s.quoteFollowUp = { graceDays: 9, cooldownDays: 9, maxCount: 9 };
  if (r() < 0.5) s.paymentReminder = { cooldownDays: 1, maxCount: 1, foo: 1 };
  if (r() < 0.5) s.wipLimits = { pending: 3, qc: 2, weird: 5 };
  if (r() < 0.5) s.paymentInstructions = pick(r, ['', 'Pay at the counter']);
  if (r() < 0.5) s.kits = [{ id: 'k' }];
  if (r() < 0.5) s.invNumNext = 41;
  if (r() < 0.5) s.quoteNumNext = 0;
  if (r() < 0.5) s.quoteNumYear = 2024;
  if (r() < 0.5) s.exchangeRatesUpdatedAt = 0;
  if (r() < 0.5) s.pausedAt = 0;
  if (r() < 0.3) s.lanApi = { enabled: true, port: 1, pin: '9' };
  return s;
}

function someForm(r, ctx) {
  const f = {
    content: { bizEn: pick(r, ['', ' Tuwaiq ']), bizAr: 'تويق' },
    vat: value(r), cr: value(r), phone: value(r), email: value(r),
    lang: pick(r, ['en', 'ar']), theme: pick(r, ['dark', 'light']),
    designTheme: pick(r, ['', 'studio', 'workbench']), accent: pick(r, ['', 'cyan']),
    invPrefix: value(r), autoDeduct: flag(r), lowStock: value(r),
    bankName: value(r), accountHolder: value(r), iban: value(r),
    acceptedPayments: pick(r, [[], ['cash'], ['cash', 'bank']]),
    useHijri: flag(r), useArabicNumerals: flag(r), autoBackup: flag(r),
    coachTips: maybe(r, flag(r)),
    enableVat: flag(r), vatRate: value(r),
    invAccent: pick(r, ['', '#5E2E14', '#000']), invTemplate: pick(r, ['', 'modern']),
    invoiceBilingual: pick(r, ['', 'auto', 'both']), invoiceSecondLang: pick(r, ['', 'ar', 'fr']),
    lowStockColor: pick(r, ['', ctx.themeLowStockColor, '#123456']),
    quotePrefix: value(r), useIcloud: flag(r), monthlyGoal: value(r), supplierPhone: value(r),
    currency: pick(r, ['', 'SAR', 'EUR']), enableZatca: flag(r),
    taxMode: pick(r, ['', 'inclusive', 'exclusive']), taxCountry: pick(r, ['', 'SA', 'US']),
    minMarginPct: value(r),
    budgets: Object.fromEntries(DEFAULT_EXPENSE_CATEGORIES.map((c) => [c, value(r)])),
    workingHours: Object.fromEntries(DAYS.map((d) => [d, value(r)])),
    operatorLock: flag(r), loyaltyEnabled: flag(r),
    paymentInstructions: pick(r, ['', 'x']), betaUpdates: flag(r),
    quoteValidityDays: value(r),
    leadTime: { dailyHours: value(r), workingDaysPerWeek: value(r), finishingDays: value(r),
                dispatchDays: value(r), safetyDays: value(r), publishToCloud: flag(r) },
    quoteFollowUp: { enabled: flag(r), windowDays: value(r) },
    paymentReminder: { enabled: flag(r), graceDays: value(r) },
    minOrderAmount: value(r), rushFeeEnabled: flag(r), rushFeePct: value(r), defaultPackagingCost: value(r),
    wip: Object.fromEntries(WIP_COLUMNS.map((c) => [c, value(r)])),
    wipEnforceHardLimit: flag(r),
    qc: { enabled: flag(r), requireInspector: flag(r), requirePhotoOnFail: flag(r), warrantyDays: value(r) },
  };
  // `coachTips` is the one control the original tests for presence.
  if (f.coachTips === undefined) delete f.coachTips;
  return f;
}

const CTX = { year: new Date().getFullYear(), themeLowStockColor: '#f5a623', expenseCategories: DEFAULT_EXPENSE_CATEGORIES };

test('the module and the original agree, field for field, over 3000 generated saves', () => {
  const r = rng(20260904);
  for (let i = 0; i < 3000; i++) {
    const settings = someSettings(r);
    const form = someForm(r, CTX);
    const theirs = runOriginal(settings, form, CTX);
    const ours = apply(settings, form, CTX);
    assert.deepEqual(ours, theirs, `case ${i}\nsettings=${JSON.stringify(settings)}\nform=${JSON.stringify(form)}`);
  }
});

// ---------------------------------------------------------------------------
// The deliberate change: a key the form does not carry keeps its value
// ---------------------------------------------------------------------------
test('a form that carries five settings saves five settings', () => {
  const before = { phone: '050', vat: '3001', wipLimits: { pending: 3 }, lowStockThreshold: 50,
                   enableVat: true, vatRate: 15, tax: { country: 'SA', name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] },
                   acceptedPayments: ['cash'], qc: { enabled: true, warrantyDays: 7 } };
  const after = apply(before, { phone: ' 055 ' }, CTX);
  assert.equal(after.phone, '055');
  assert.equal(after.vat, '3001', 'a text field not on the form is kept');
  assert.deepEqual(after.wipLimits, { pending: 3 }, 'the WIP limits are kept, not emptied');
  assert.equal(after.lowStockThreshold, 50, 'a number not on the form keeps its value, not its default');
  assert.equal(after.enableVat, true, 'a checkbox not on the form is not read as unticked');
  assert.deepEqual(after.tax, before.tax, 'the tax profile is not rebuilt by a save that did not touch it');
  assert.deepEqual(after.acceptedPayments, ['cash']);
  assert.deepEqual(after.qc, before.qc);
});

test('the save does not mutate what it was given', () => {
  const settings = { phone: '050', wipLimits: { pending: 3 }, leadTime: { dailyHours: 8 } };
  const frozen = JSON.stringify(settings);
  apply(settings, { phone: '1', wip: { pending: '9' }, leadTime: { dailyHours: '2' } }, CTX);
  assert.equal(JSON.stringify(settings), frozen);
});

test('an empty save still preserves, normalises and marks the first run done', () => {
  const after = apply({ cloud: { token: 'T' }, slicers: ['x'], privacy: { a: 1 }, telemetry: { b: 1 },
                        __designV26Migrated: true, _idDedupeDone: true }, {}, CTX);
  for (const key of ['cloud', 'slicers', 'privacy', 'telemetry', '__designV26Migrated', '_idDedupeDone']) {
    assert.ok(key in after, `a save would drop settings.${key}`);
  }
  assert.equal(after.firstRunDone, true);
  assert.equal(after.firstRun, false);
  assert.deepEqual(after.webhooks, { enabled: false, secret: '', events: {} });
  assert.equal(after.quoteNumYear, CTX.year);
});

test('the tax profile is rebuilt only from the four things it is built from', () => {
  const s = { enableVat: true, vatRate: 15, tax: { country: 'SA', name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };
  const moved = apply(s, { taxMode: 'exclusive' }, CTX);
  assert.equal(moved.tax.mode, 'exclusive');
  assert.equal(moved.tax.rates[0].percent, 15, 'the rate is read from the stored value when the form has none');
  const off = apply(s, { enableVat: false }, CTX);
  assert.deepEqual(off.tax.rates, [], 'switching VAT off empties the rates');
  assert.equal(off.enableVat, false);
});

// ---------------------------------------------------------------------------
// Choosing a country
// ---------------------------------------------------------------------------
test('choosing a country rewrites name, rate, convention and registration label together', () => {
  const s = { enableVat: false, vatRate: 0, phone: '050' };
  const india = chooseCountry(s, 'in');
  assert.equal(india.tax.country, 'IN', 'upper-cased, the way the presets are keyed');
  assert.equal(india.tax.name, 'GST');
  assert.equal(india.tax.registration, 'GSTIN');
  assert.equal(india.tax.mode, 'exclusive');
  assert.equal(india.tax.rates.length, 2, 'two rates, CGST and SGST');
  assert.equal(india.enableVat, true, 'the legacy field is kept in step');
  assert.equal(india.vatRate, india.tax.rates[0].percent);
  assert.equal(india.phone, '050', 'and nothing else is touched');
  assert.equal(s.tax, undefined, 'the input is not mutated');
});

test('a country with no rate yet switches VAT off and leaves the old rate alone', () => {
  const out = chooseCountry({ enableVat: true, vatRate: 15 }, 'US');
  assert.equal(out.enableVat, false);
  assert.equal(out.vatRate, 15, 'the stored rate is not zeroed — the renderer never did either');
  assert.deepEqual(out.tax.rates, []);
});

test('"Custom" changes nothing', () => {
  const s = { tax: { country: 'SA', name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [] } };
  assert.deepEqual(chooseCountry(s, ''), s);
});

test('a chosen country survives the save that follows it, as it does in the renderer', () => {
  // The renderer chooses on the change and saves later; the Mac chooses and
  // saves in one write. Both must land the same record.
  const chosen = chooseCountry({}, 'DE');
  const saved = apply(chosen, { taxCountry: 'DE', enableVat: true, vatRate: '19', taxMode: 'inclusive' }, CTX);
  assert.equal(saved.tax.name, 'VAT');
  assert.equal(saved.tax.registration, 'USt-IdNr.');
  assert.deepEqual(saved.tax.rates, [{ id: 'vat', label: 'USt.', percent: 19 }]);
  assert.equal(saved.tax.country, 'DE');
});

/* ============================================================
   When models get checked for print risks
   ============================================================ */

test('the print-risk schedule saves, and only the values the reader accepts', () => {
  const base = { printRisk: { when: 'demand', keepMe: 1 } };
  assert.equal(apply(base, { printRisk: { when: 'import' } }).printRisk.when, 'import');
  // Validated through the reader that reads it back rather than against a
  // second list here: a screen that can save a value its own reader rejects is
  // a screen with a dead option in it.
  assert.equal(apply(base, { printRisk: { when: 'whenever' } }).printRisk.when, 'demand');
  assert.equal(apply(base, { printRisk: { when: 'IMPORT' } }).printRisk.when, 'import');
});

test('saving the schedule leaves anything else under printRisk alone', () => {
  // The same rule as everywhere else here: a save must not destroy a setting
  // the form does not show. `cloud` was lost that way once, with a shop's sync
  // keyset in it.
  const out = apply({ printRisk: { when: 'demand', keepMe: 1 } }, { printRisk: { when: 'import' } });
  assert.equal(out.printRisk.keepMe, 1);
});

test('a form that does not carry the schedule keeps the stored one', () => {
  // The Mac's panes each save only the keys they show.
  const out = apply({ printRisk: { when: 'import' } }, { minMarginPct: 5 });
  assert.equal(out.printRisk.when, 'import');
});

test('a book that never set a schedule gets no printRisk block', () => {
  // Absent, not `{when:'demand'}`: writing the default in would put a field on
  // every shop's book to say what the absence of it already says, and the
  // other app would sync it around.
  assert.equal(apply({}, {}).printRisk, undefined);
});
