/**
 * Pure number, money, CSV, and catalog pricing helpers (renderer + node:test).
 */
(function (global) {
  function num(v, fallback = 0) {
    const n = parseFloat(v);
    return Number.isFinite(n) ? n : fallback;
  }

  function clampPositive(v) {
    return Math.max(0, num(v, 0));
  }

  function fmtMoney(n) {
    return (Math.round((+n || 0) * 100) / 100).toFixed(2);
  }

  /**
   * Thousands-grouped number for display.
   *
   * Bare `n.toLocaleString()` inherits the SYSTEM locale, so on a machine set to
   * Saudi Arabia it renders Arabic-Indic digits — ١٨٬٧٥٠ with U+066B/U+066C
   * separators — even when Khayt itself is in English. Sampling live Saudi
   * products (Al Rajhi, SNB, Absher, Tawakkalna, Salla, Zid, STC) found Western
   * digits essentially everywhere, including in Hijri dates, so pin them rather
   * than inherit whatever the OS happens to be set to.
   */
  function fmtCount(n) {
    const v = +n || 0;
    if (!Number.isFinite(v)) return '0';
    try { return v.toLocaleString('en-US'); } catch (e) { return String(v); }
  }

  function computeUnitPrice(p) {
    if (p?.unitPrice && +p.unitPrice > 0) return +p.unitPrice;
    const qty = +p?.quantity || 1;
    return (+p?.amount || 0) / qty;
  }

  /** Neutralize CSV formula injection (=, +, -, @, tab, CR). */
  function csvFormulaNeutralize(v) {
    const s = String(v ?? '');
    return /^[=+\-@\t\r]/.test(s) ? "'" + s : s;
  }

  /**
   * BCP-47 tag for the language the user actually chose, for date and time
   * formatting.
   *
   * Every date in the app used to be formatted one of three wrong ways: a
   * hardcoded en-US/en-GB; a ternary picking the Arabic tag for Arabic and
   * en-US for everything else, which quietly meant English for the seven
   * languages that are not Arabic; or no argument at all, which follows the
   * OPERATING SYSTEM rather than the app — so picking 日本語 in Khayt still
   * produced "Monday, July 27, 2026" on an English Mac.
   *
   * Arabic keeps `-u-nu-latn`. That is the same deliberate choice `fmtCount`
   * documents: live Saudi products overwhelmingly use Western digits, so the
   * digits stay Latin while the words localise. Do NOT route `fmtCount`
   * through here — its 'en-US' is about digits, not language.
   *
   * The Hijri formatter in app-helpers.js is also deliberately left alone: it
   * pins the Umm al-Qura calendar, which is the point of it.
   */
  // The table lives in lib/print-date.js, because the invoice's own date
  // formatter needs it and the Mac app has no renderer to read it from.
  //
  // Looked up on every call, not once at load: index.html loads this file
  // ~200 scripts BEFORE print-date.js, so a lookup at load found nothing and
  // every date on Windows and Linux came out in US English whatever the
  // language.
  function dates() {
    if (typeof globalThis !== 'undefined' && globalThis.KhaytPrintDate) return globalThis.KhaytPrintDate;
    try { return require('../lib/print-date.js'); } catch (e) { return null; }
  }

  function localeTag() {
    const lang = (typeof i18n !== 'undefined' && i18n && i18n.current) || 'en';
    const d = dates();
    return d ? d.localeTagFor(lang) : 'en-US';
  }

  const api = { num, clampPositive, fmtMoney, fmtCount, computeUnitPrice, csvFormulaNeutralize, localeTag };
  Object.defineProperty(api, 'LOCALE_TAGS', {
    enumerable: true,
    get() { const d = dates(); return d ? d.LOCALE_TAGS : { en: 'en-US' }; },
  });

  global.KhaytFormat = api;
  global.num = num;
  global.clampPositive = clampPositive;
  global.fmtMoney = fmtMoney;
  global.fmtCount = fmtCount;
  global.computeUnitPrice = computeUnitPrice;
  global.csvFormulaNeutralize = csvFormulaNeutralize;
  global.localeTag = localeTag;

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
