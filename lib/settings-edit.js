'use strict';
/**
 * Saving the shop's settings from a form.
 *
 * The rule was a 240-line object literal inside renderer/settings.js, reading
 * seventy controls off the screen — which is why only the Electron window
 * could change a setting, and why the Mac app could show a shop's tax rate and
 * not let anyone correct it. Lifted here so both apps write the same record by
 * the same rules: the same clamps, the same defaults, the same tax recompute.
 *
 * WHAT THE RULE IS. Start from what is already there (a save must not destroy
 * a setting the form does not show — `cloud` was lost that way once, and with
 * it a shop's sync keyset). Then, for each control the form carries: trim the
 * text, clamp the numbers to the range the rest of the app assumes, fall back
 * to the defaults the app was written against. Then normalise the objects
 * other screens manage in place, so a missing one becomes the empty shape its
 * readers expect rather than `undefined`. And rebuild `tax` from the live
 * profile, so the legacy VAT fields and the tax profile can never drift into
 * two different answers.
 *
 * ONE DELIBERATE CHANGE from the original: A KEY THE FORM DOES NOT CARRY KEEPS
 * ITS VALUE. The renderer's form carries every key, so this changes nothing
 * there. It is what lets a screen that shows five settings save five settings
 * — the Mac's Business tab does not show the WIP limits, and saving the shop's
 * phone number must not zero them.
 *
 * PURE: no DOM, no globals, no clock. The year, the theme's low-stock colour
 * and the expense categories are passed in, because they are the host's.
 *
 * `KhaytTax` is consulted the way every sibling module consults a sibling:
 * through the global it assigns itself to, present in both apps.
 */
(function (global) {

  const tax = () => (typeof global.KhaytTax !== 'undefined')
    ? global.KhaytTax
    : (function () { try { return require('./tax.js'); } catch (e) { return null; } })();

  const stlEstimate = () => (typeof global.KhaytStl !== 'undefined')
    ? global.KhaytStl
    : (function () { try { return require('./stl-estimate.js'); } catch (e) { return null; } })();

  const aiProviders = () => (typeof global.KhaytAiProviders !== 'undefined')
    ? global.KhaytAiProviders
    : (function () { try { return require('./ai-providers.js'); } catch (e) { return null; } })();

  const aiPrivacy = () => (typeof global.KhaytAiPrivacy !== 'undefined')
    ? global.KhaytAiPrivacy
    : (function () { try { return require('./ai-privacy.js'); } catch (e) { return null; } })();

  /** An address only if a key may travel to it; otherwise keep what was stored. */
  function safeBaseUrl(raw, stored) {
    const v = String(raw == null ? '' : raw).trim();
    if (!v) return '';                       // the vendor's own address
    const rules = (typeof global.KhaytBaseUrl !== 'undefined')
      ? global.KhaytBaseUrl
      : (function () { try { return require('./base-url.js'); } catch (e) { return null; } })();
    if (!rules) return stored;
    try { rules.validateBaseUrl(v, { what: 'address', secret: 'API key' }); return v; }
    catch (e) { return stored; }
  }

  // Same shape, same reason: `print-risk.js` owns which values are allowed and
  // what an unrecognised one means, so this does not keep a second list.
  const printRisk = () => (typeof global.KhaytPrintRisk !== 'undefined')
    ? global.KhaytPrintRisk
    : (function () { try { return require('./print-risk.js'); } catch (e) { return null; } })();

  const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  const WIP_COLUMNS = ['pending', 'printing', 'post', 'qc'];
  const DEFAULT_EXPENSE_CATEGORIES = ['filament', 'electricity', 'maintenance', 'tools', 'shipping', 'other'];

  /** The renderer's `num`: parseFloat with a fallback for anything that is not a number. */
  function num(v, fallback) {
    const n = parseFloat(v);
    return Number.isFinite(n) ? n : fallback;
  }
  const clamp = (lo, hi, v) => Math.max(lo, Math.min(hi, v));
  const has = (form, key) => Object.prototype.hasOwnProperty.call(form, key) && form[key] !== undefined;

  /**
   * @param {object} settings  the shop's settings as stored
   * @param {object} form      the values the form holds — see the field list
   *                           in `apply`; a key that is absent is not changed
   * @param {object} ctx       `{ year, themeLowStockColor, expenseCategories }`
   * @returns {object}         the settings to store; `settings` is not mutated
   */
  function apply(settings, form, ctx) {
    const s = settings || {};
    const f = form || {};
    const c = ctx || {};
    const year = c.year != null ? c.year : new Date().getFullYear();
    const categories = Array.isArray(c.expenseCategories) ? c.expenseCategories : DEFAULT_EXPENSE_CATEGORIES;

    // Text: trimmed, and kept when the form has no field for it.
    const text = (key) => has(f, key) ? String(f[key] == null ? '' : f[key]).trim() : (s[key] == null ? '' : s[key]);
    // A checkbox: absent keeps the stored value, present is a boolean.
    const flag = (key, stored = key) => has(f, key) ? !!f[key] : !!s[stored];
    // A number with a floor, a ceiling and the default the app was written against.
    const number = (key, lo, hi, fallback, stored = key) =>
      has(f, key) ? clamp(lo, hi, num(f[key], fallback)) : (s[stored] != null ? s[stored] : fallback);

    const out = {
      ...s,
      // The shop's own text, per language. Only the languages on screen; a
      // language the shop has stopped using keeps whatever it had.
      ...(f.content || {}),
    };

    if (has(f, 'vat'))   out.vat   = text('vat');
    if (has(f, 'cr'))    out.cr    = text('cr');
    if (has(f, 'phone')) out.phone = text('phone');
    if (has(f, 'email')) out.email = text('email');
    if (has(f, 'lang'))  out.lang  = f.lang;
    if (has(f, 'theme')) out.theme = f.theme;
    if (has(f, 'designTheme')) out.designTheme = f.designTheme || s.designTheme || 'studio';
    if (has(f, 'accent'))      out.accent      = f.accent || s.accent || 'cyan';
    if (has(f, 'invPrefix'))   out.invPrefix   = text('invPrefix') || 'INV';
    if (has(f, 'autoDeduct'))  out.autoDeduct  = !!f.autoDeduct;
    if (has(f, 'lowStock'))    out.lowStockThreshold = Math.max(0, num(f.lowStock, 200));
    if (has(f, 'bankName'))      out.bankName      = text('bankName');
    if (has(f, 'accountHolder')) out.accountHolder = text('accountHolder');
    // An IBAN is entered in groups of four and stored without the spaces.
    if (has(f, 'iban'))          out.iban          = text('iban').replace(/\s+/g, '');
    if (has(f, 'acceptedPayments')) out.acceptedPayments = Array.isArray(f.acceptedPayments) ? f.acceptedPayments.slice() : [];
    if (has(f, 'useHijri'))          out.useHijri          = !!f.useHijri;
    if (has(f, 'useArabicNumerals')) out.useArabicNumerals = !!f.useArabicNumerals;
    if (has(f, 'autoBackup'))        out.autoBackup        = !!f.autoBackup;
    // Written by the folder pickers and the log's batch bar, not by any field
    // on the page — rebuilding from the form must not drop them.
    out.printLibrary = s.printLibrary || {};
    out.kits = s.kits || [];
    out.coachTips = has(f, 'coachTips') ? !!f.coachTips : (s.coachTips !== false);
    if (has(f, 'enableVat')) out.enableVat = !!f.enableVat;
    if (has(f, 'vatRate'))   out.vatRate   = Math.max(0, num(f.vatRate, 15));
    out.bizLogo = s.bizLogo || '';
    if (has(f, 'invAccent'))        out.invAccentColor   = f.invAccent || '#5E2E14';
    if (has(f, 'invTemplate'))      out.invTemplate      = f.invTemplate || 'classic';
    if (has(f, 'invoiceBilingual')) out.invoiceBilingual = f.invoiceBilingual || 'auto';
    // Falls back to the stored value, not to a literal: the picker is hidden
    // while a document is single-language or ZATCA-pinned, and a hidden control
    // must not quietly reset a choice the owner made earlier.
    if (has(f, 'invoiceSecondLang')) out.invoiceSecondLang = f.invoiceSecondLang || s.invoiceSecondLang || 'ar';
    // Reset writes '' while the picker still shows the theme's colour, so an
    // untouched picker must not silently re-pin that default as an override.
    if (has(f, 'lowStockColor')) {
      out.lowStockColor = (s.lowStockColor === '' && f.lowStockColor === c.themeLowStockColor)
        ? '' : (f.lowStockColor || '');
    }
    if (has(f, 'quotePrefix'))   out.quotePrefix   = text('quotePrefix') || 'QUO';
    if (has(f, 'useIcloud'))     out.useIcloud     = !!f.useIcloud;
    if (has(f, 'monthlyGoal'))   out.monthlyGoal   = Math.max(0, num(f.monthlyGoal, 0));
    if (has(f, 'supplierPhone')) out.supplierPhone = text('supplierPhone');
    if (has(f, 'currency'))      out.currency      = f.currency || 'SAR';
    if (has(f, 'enableZatca'))   out.enableZatca   = !!f.enableZatca;

    // Written from the live profile so the legacy VAT fields and the tax
    // profile can never drift apart into two different answers. Only when the
    // form touched any of the four things it is built from.
    if (has(f, 'taxMode') || has(f, 'taxCountry') || has(f, 'vatRate') || has(f, 'enableVat')) {
      const T = tax();
      const prof = T.profileFromSettings(s);
      const mode = f.taxMode || prof.mode;
      const rate = has(f, 'vatRate') ? +f.vatRate : +s.vatRate;
      const enabled = has(f, 'enableVat') ? !!f.enableVat : !!s.enableVat;
      const rates = (s.tax && s.tax.rates && s.tax.rates.length > 1)
        ? s.tax.rates
        : (enabled && rate > 0 ? [{ id: 'vat', label: (prof.rates[0] && prof.rates[0].label) || 'VAT', percent: rate }] : []);
      out.tax = {
        country: f.taxCountry || (s.tax && s.tax.country) || '',
        name: prof.name, registration: prof.registration, mode, rates,
      };
    }

    out.firstRunDone = true;
    if (has(f, 'minMarginPct')) out.minMarginPct = clamp(0, 100, num(f.minMarginPct, 0));
    if (has(f, 'budgets')) {
      out.expBudgets = Object.fromEntries(categories.map((cat) =>
        [cat, Math.max(0, num((f.budgets || {})[cat], 0))]));
    }
    out.postChecklist = s.postChecklist || [];
    // Invoice numbering is managed by its own section; preserved as-is.
    out.invNumPrefix = s.invNumPrefix || 'INV';
    out.invNumYear   = s.invNumYear   || year;
    out.invNumNext   = s.invNumNext   || 1;
    out.invNumFormat = s.invNumFormat || '{prefix}-{year}-{seq4}';
    if (has(f, 'workingHours')) {
      out.workingHours = Object.fromEntries(DAYS.map((d) =>
        [d, clamp(0, 24, num((f.workingHours || {})[d], 0))]));
    }
    out.holidays = s.holidays || [];
    out.mode = s.mode || 'professional';
    out.firstRun = false;
    out.customFields = s.customFields || [];
    // Managed by their own sections; a missing one becomes the empty shape its
    // readers expect.
    out.emailConfig = s.emailConfig || { provider: 'none', apiKey: '', fromEmail: '', fromName: '', domain: '', triggers: [] };
    out.smsConfig = s.smsConfig || { provider: 'none', channel: 'whatsapp' };
    out.accountingSync = s.accountingSync || { enabled: false, format: 'generic', webhookUrl: '', secret: '', pushOnPaid: true };
    out.paymentProviders = s.paymentProviders || {};
    if (has(f, 'operatorLock')) out.operatorLockEnabled = !!f.operatorLock;
    out.activeOperatorId = s.activeOperatorId || null;
    if (has(f, 'loyaltyEnabled')) out.loyaltyEnabled = !!f.loyaltyEnabled;
    out.loyaltyTiers = s.loyaltyTiers || [];
    out.telegram = s.telegram || { botToken: '', chatId: '', notifyOnComplete: false, notifyOnHold: false, notifyOnLowStock: false, notifyPrinterError: true, notifyPrinterOffline: true, notifyPrinterStall: false };
    out.webhooks = s.webhooks || { enabled: false, secret: '', events: {} };
    out.fixedCosts = s.fixedCosts || [];
    out.savedFilters = s.savedFilters || [];
    if (has(f, 'paymentInstructions')) out.paymentInstructions = f.paymentInstructions ?? s.paymentInstructions ?? '';
    out.betaAcknowledged = true;
    if (has(f, 'betaUpdates')) out.betaUpdates = !!f.betaUpdates;
    if (has(f, 'quoteValidityDays')) out.quoteValidityDays = Math.max(1, num(f.quoteValidityDays, 7));
    // Delivery estimates, clamped to the ranges the cloud endpoint enforces so
    // a value that would be refused on publish is refused here, where somebody
    // can see why. `staleAfterHours` is not on any form and is carried through.
    if (has(f, 'leadTime')) {
      const lt = f.leadTime || {};
      out.leadTime = {
        ...(s.leadTime || {}),
        dailyHours:         clamp(1, 24, num(lt.dailyHours, 8)),
        workingDaysPerWeek: clamp(1, 7, num(lt.workingDaysPerWeek, 5)),
        finishingDays:      clamp(0, 90, num(lt.finishingDays, 1)),
        dispatchDays:       clamp(0, 90, num(lt.dispatchDays, 1)),
        safetyDays:         clamp(0, 90, num(lt.safetyDays, 1)),
        publishToCloud:     !!lt.publishToCloud,
      };
    }
    if (has(f, 'quoteFollowUp')) {
      const q = f.quoteFollowUp || {};
      out.quoteFollowUp = {
        ...(s.quoteFollowUp || { graceDays: 1, cooldownDays: 2, maxCount: 2 }),
        enabled: !!q.enabled,
        windowDays: clamp(0, 60, num(q.windowDays, 2)),
      };
    }
    if (has(f, 'paymentReminder')) {
      const r = f.paymentReminder || {};
      out.paymentReminder = {
        ...(s.paymentReminder || { cooldownDays: 3, maxCount: 3 }),
        enabled: !!r.enabled,
        graceDays: clamp(0, 90, num(r.graceDays, 3)),
      };
    }
    if (has(f, 'minOrderAmount'))       out.minOrderAmount       = Math.max(0, num(f.minOrderAmount, 0));
    if (has(f, 'rushFeeEnabled'))       out.rushFeeEnabled       = !!f.rushFeeEnabled;
    if (has(f, 'rushFeePct'))           out.rushFeePct           = clamp(0, 500, num(f.rushFeePct, 25));
    if (has(f, 'defaultPackagingCost')) out.defaultPackagingCost = Math.max(0, num(f.defaultPackagingCost, 0));
    if (has(f, 'wip')) {
      const wip = { ...(s.wipLimits || {}) };
      WIP_COLUMNS.forEach((col) => {
        const v = num((f.wip || {})[col], 0);
        if (v > 0) wip[col] = v;
        else delete wip[col];
      });
      out.wipLimits = wip;
    }
    if (has(f, 'wipEnforceHardLimit')) out.wipEnforceHardLimit = !!f.wipEnforceHardLimit;
    if (has(f, 'qc')) {
      const q = f.qc || {};
      out.qc = {
        enabled:            !!q.enabled,
        requireInspector:   !!q.requireInspector,
        requirePhotoOnFail: !!q.requirePhotoOnFail,
        warrantyDays:       Math.max(0, num(q.warrantyDays, 30)),
      };
    }
    if (has(f, 'estimator')) {
      const e = f.estimator || {};
      const held = s.estimator || {};
      const stl = stlEstimate();
      // Validated THROUGH the reader that reads it back: `fromSettings` clamps
      // each field to the range the estimator assumes and falls back to its own
      // default for anything outside it. Keeping a second set of ranges here is
      // how a screen comes to save a value its own reader silently replaces.
      const merged = { ...held };
      for (const key of ['densityGPerCm3', 'infillPct', 'shellFactor',
                         'wallThicknessMm', 'throughputMm3PerS', 'wastePct']) {
        if (has(e, key)) merged[key] = e[key];
      }
      out.estimator = stl ? stl.fromSettings({ estimator: merged }) : merged;
    }
    if (has(f, 'ai')) {
      const a = f.ai || {};
      const held = s.ai || {};
      const rules = aiProviders();
      const privacy = aiPrivacy();
      // The provider through the registry, so a value the reader would reject
      // cannot be saved — `providerOf` falls back rather than throwing.
      //
      // ONLY WHEN THE FORM CARRIES ONE. `providerOf` falls back to Anthropic
      // for an absent value, so recomputing it unconditionally turned a shop
      // on OpenAI into a shop on Anthropic the moment it saved anything else
      // about the assistant — the same silent-revert shape as the consent
      // boxes the provider chooser used to discard.
      const provider = has(a, 'provider')
        ? (rules ? rules.providerOf({ ai: a }).id : String(a.provider || ''))
        : (held.provider || '');
      // Consent for KNOWN features only. A key nobody has a switch for is a
      // permission nobody granted, and it would sit in the book looking granted.
      const features = {};
      if (privacy) {
        for (const id of Object.keys(privacy.AI_FEATURES)) {
          features[id] = has(a, 'features') ? !!(a.features || {})[id]
                                            : !!((held.features || {})[id]);
        }
      }
      out.ai = {
        ...held,
        enabled: has(a, 'enabled') ? !!a.enabled : !!held.enabled,
        provider,
        // A blank address means the vendor's own. A given one is CHECKED, and a
        // bad one leaves the stored value alone rather than saving something a
        // key would then travel to.
        baseUrl: has(a, 'baseUrl') ? safeBaseUrl(a.baseUrl, held.baseUrl || '') : (held.baseUrl || ''),
        model: has(a, 'model') ? String(a.model == null ? '' : a.model).trim() : (held.model || ''),
        // The key is OPAQUE here — sealed by the host before it arrives, and
        // never inspected or re-encoded. Absent keeps what is stored, which is
        // what a masked field means.
        apiKey: has(a, 'apiKey') && String(a.apiKey || '') ? a.apiKey : (held.apiKey || ''),
        features,
      };
    }
    if (has(f, 'printRisk')) {
      const pr = f.printRisk || {};
      // Validated THROUGH the reader that will read it back, not with a
      // second list of allowed values here. A settings screen that could save
      // a value its own reader rejects is a screen with a dead option in it.
      const rules = printRisk();
      out.printRisk = {
        ...(s.printRisk || {}),
        // No fallback list if the module is missing: `when` is then left as it
        // was rather than replaced with a guess, because a wrong value here
        // decides whether every import walks its mesh.
        when: rules ? rules.riskWhen({ printRisk: pr }) : ((s.printRisk || {}).when ?? 'demand'),
      };
    }
    // Preserved, in the shape their readers expect.
    out.zatcaPhase2 = s.zatcaPhase2 || {};
    out.emailDigest = s.emailDigest || {};
    out.bnpl = s.bnpl || {};
    out.exchangeRates = s.exchangeRates || {};
    out.exchangeRatesUpdatedAt = s.exchangeRatesUpdatedAt ?? null;
    out.staleHours = s.staleHours || {};
    out.productionPaused = s.productionPaused || false;
    out.pauseReason = s.pauseReason || '';
    out.pausedAt = s.pausedAt ?? null;
    out.filamentColours = s.filamentColours || {};
    out.jobTemplates = s.jobTemplates || [];
    out.postProcessPresets = s.postProcessPresets || [];
    out.resinProfiles = s.resinProfiles || [];
    out.dismissedNotifs = s.dismissedNotifs || {};
    out.kanbanCollapsed = s.kanbanCollapsed || [];
    out.donationUrl = s.donationUrl || '';
    out.printerApi = s.printerApi || {};
    out.locations = s.locations || [];
    // The host migrates the legacy webhook secrets into this BEFORE calling.
    out.lanApi = s.lanApi || { enabled: false, port: 3219, pin: '' };
    out.onlineEnabled = !!s.onlineEnabled;
    out.securityEnabled = !!s.securityEnabled;
    out.recoveryCodeHash = s.recoveryCodeHash || '';
    out.recoveryCodeCreatedAt = s.recoveryCodeCreatedAt || '';
    out.quoteNumYear = s.quoteNumYear ?? year;
    out.quoteNumNext = s.quoteNumNext ?? 1;
    return out;
  }

  /**
   * Choosing a country for tax rules.
   *
   * A country choice rewrites the tax's name, rate, pricing convention and the
   * label of its registration number together — picking them apart is exactly
   * the fiddly bit a preset exists to remove. The legacy `enableVat`/`vatRate`
   * fields are kept in step so anything still reading them agrees.
   *
   * This was the change handler on the renderer's country picker, which wrote
   * straight into the live settings; here it returns a new object so a form
   * that is not saved until later can apply it at save time. An empty code
   * ("Custom") changes nothing: a shop that picks Custom keeps what it has and
   * edits it by hand.
   */
  function chooseCountry(settings, code) {
    const s = settings || {};
    const country = String(code || '').toUpperCase();
    if (!country) return { ...s };
    const preset = tax().presetFor(country);
    const first = preset.rates[0];
    const out = {
      ...s,
      tax: { country, name: preset.name, mode: preset.mode, registration: preset.registration, rates: preset.rates },
      enableVat: !!first,
    };
    if (first) out.vatRate = first.percent;
    return out;
  }

  const api = { apply, chooseCountry, DAYS, WIP_COLUMNS, DEFAULT_EXPENSE_CATEGORIES };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSettingsEdit = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
