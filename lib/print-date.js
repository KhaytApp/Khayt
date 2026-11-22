'use strict';
/**
 * The date on a printed document.
 *
 * A shared module for one small reason: this is the only thing on an invoice
 * that a computer will happily print in a form no customer reads. The Mac app
 * had no copy of the renderer's formatter, so the ISO string arrived on the
 * paper — `2026-07-02T14:32:00.000Z` under DATE — and the invoice was correct
 * in every figure and wrong in the one line anybody looks at first.
 *
 * PURE: no globals, no clock. The locale tag is passed in because which tag a
 * language maps to is the app's decision, not the formatter's.
 */
(function (global) {

  /**
   * A language's tag for formatting.
   *
   * `ar` asks for Latin digits deliberately (`-u-nu-latn`): the document's own
   * Arabic-Indic pass runs afterwards over the elements it names, and a date
   * that arrived already converted would be converted twice.
   *
   * And for the Gregorian calendar by name (`-u-ca-gregory`): `ar-SA`'s
   * default is Umm al-Qura. Electron's ICU happened to give Gregorian anyway;
   * the Mac's JavaScriptCore does not, and printed "09 جمادى الأولى، 1448 هـ"
   * on an Arabic invoice dated 20 Oct 2026. The shop chose Gregorian dates
   * with Arabic month names (Oct 2026).
   */
  const LOCALE_TAGS = {
    en: 'en-US',
    ar: 'ar-SA-u-ca-gregory-nu-latn',
    de: 'de-DE',
    es: 'es-ES',
    fr: 'fr-FR',
    ja: 'ja-JP',
    tr: 'tr-TR',
    zh: 'zh-CN',
    'pt-BR': 'pt-BR',
  };

  /** The tag a language formats with, falling back to US English. */
  function localeTagFor(language) {
    return LOCALE_TAGS[language] || 'en-US';
  }

  /**
   * An ISO date as a person reads it — "02 Jul 2026".
   *
   * Anything unparseable comes back unchanged rather than as "Invalid Date":
   * a document showing the raw field is at least honest about what it was given.
   */
  function printDate(iso, tag) {
    if (!iso) return '';
    try {
      const d = new Date(iso);
      if (isNaN(d.getTime())) return String(iso);
      return d.toLocaleDateString(tag || 'en-US',
        { day: '2-digit', month: 'short', year: 'numeric' });
    } catch (e) {
      return String(iso);
    }
  }

  const api = { LOCALE_TAGS, localeTagFor, printDate };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrintDate = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
