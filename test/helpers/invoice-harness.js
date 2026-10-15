'use strict';
/**
 * Render an invoice outside a browser.
 *
 * `renderInvoice` writes into `#invoice-print-area`, and everything else it
 * needs is a renderer global. Both are stubbed here: the element records what
 * it was handed, and the globals are the smallest honest versions of the real
 * ones — `escapeHtml` escapes, `t` returns the English string, money is
 * formatted the way `renderer/format.js` formats it.
 *
 * Shared by the fixture generator and the test, so the two cannot disagree
 * about what "the same invoice" means.
 */
/* THE DOCUMENT SHOWS A LOCAL TIME, so the fixtures depend on a timezone.
 *
 * An invoice prints the hour it was issued in the shop's own time, which is
 * correct — and made the first fixture 12:15 on a machine in Riyadh and 09:15
 * on a runner in UTC. CI runs the unit suite in three timezones on purpose;
 * this is the trap that exists for.
 *
 * Pinned here rather than worked around in the fixture, so the fixtures say
 * what the document really produces and say it identically everywhere. */
process.env.TZ = 'UTC';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.join(__dirname, '..', '..');
/** Khayt's own English strings, run rather than parsed — the file is a script
 *  that assigns onto a root object, which is how the renderer loads it too. */
const LOCALES = (() => {
  const box = {};
  for (const lang of ['en', 'ar']) {
    vm.runInNewContext(fs.readFileSync(path.join(ROOT, `renderer/locales/${lang}.js`), 'utf8'), box);
  }
  return box.KhaytLocales;
})();
const EN = LOCALES.en;

// The real table, not a three-row stand-in: the fixtures are what the document
// prints, and the document prints against lib/currencies.js.
const { CURRENCIES } = require('../../lib/currencies.js');

/** A DOM element that only remembers what it was given. */
function fakeArea() {
  const el = {
    innerHTML: '',
    style: {},
    querySelectorAll: () => [],
    querySelector: () => null,
    appendChild: () => {},
  };
  return el;
}

function context({ settings = {}, clients = [], language = 'en' } = {}) {
  const area = fakeArea();
  const esc = (s) => String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  const ctx = {
    console,
    Date,
    Math,
    JSON,
    Number,
    String,
    Object,
    Array,
    Intl,
    settings,
    clients,
    printLog: [],
    CURRENCIES,
    $: (sel) => (sel === '#invoice-print-area' ? area : null),
    document: { querySelector: () => null, createElement: () => fakeArea() },
    escapeHtml: esc,
    t: (k, vars) => {
      let s = EN[k] || k;
      if (vars) for (const n of Object.keys(vars)) s = s.split('{' + n + '}').join(String(vars[n]));
      return s;
    },
    // `tIn` is how the document renders its SECOND language: the bilingual
    // label strip asks for a specific language rather than the current one.
    i18n: {
      current: language,
      tIn: (lang, key, vars) => {
        const table = lang === 'en' ? EN : (LOCALES[lang] || EN);
        let out = table[key] || EN[key] || key;
        if (vars) for (const n of Object.keys(vars)) out = out.split('{' + n + '}').join(String(vars[n]));
        return out;
      },
    },
    fmtMoney: (n) => (Number.isFinite(+n) ? +n : 0).toFixed(2),
    fmtPrice: (n) => (Number.isFinite(+n) ? +n : 0).toFixed(2),
    num: (v, d) => (Number.isFinite(+v) ? +v : d),
    shopField: (base) => settings[base + 'En'] || settings[base + 'Ar'] || '',
    shopName: () => settings.bizEn || settings.bizAr || '',
    localName: (c) => (c && (c.nameEn || c.nameAr)) || '',
    altLocalName: (c) => (c && (c.nameAr || '')) || '',
    orderCurrency: (o) => o.currency || settings.currency || 'SAR',
    clientCurrency: () => settings.currency || 'SAR',
    payStatus: (o) => o.paymentStatus || 'unpaid',
    hijriDate: () => '1448/03/12',
    toArabicNumerals: (s) => String(s).replace(/[0-9]/g, (d) => '٠١٢٣٤٥٦٧٨٩'[+d]),
    qcStatusOf: () => null,
    safeBizLogo: () => '',
    safeCssColor: (v, fallback) => (/^#[0-9a-fA-F]{3,8}$/.test(String(v || '')) ? String(v) : fallback),
    BRAND_MARK_SVG: '<svg id="brand"></svg>',
    // renderClientSub is NOT passed, for the same reason the renderer stopped
    // passing it: the contact line is the document's own rule, and a harness
    // that overrides it would render a document neither app prints.
    window: {},
  };
  ctx.globalThis = ctx;
  ctx.global = ctx;
  vm.createContext(ctx);
  // print-date before invoice-document: the document's date formatter reaches
  // it through the global, exactly as it does in a window and on the Mac.
  for (const f of ['lib/tax.js', 'lib/order-new.js', 'lib/invoice-language.js', 'lib/content-languages.js',
                   'lib/print-date.js', 'lib/invoice-document.js']) {
    vm.runInContext(fs.readFileSync(path.join(ROOT, f), 'utf8'), ctx);
  }
  vm.runInContext(fs.readFileSync(path.join(ROOT, 'renderer/invoicing.js'), 'utf8'), ctx);
  return { ctx, area };
}

/** The HTML `renderInvoice` produces for one order. */
function render(order, opts = {}, money = {}) {
  const { ctx, area } = context(opts);
  ctx.renderInvoice(order, Object.assign({
    qrSvg: '<svg id="zatca-qr"></svg>',
    qrProblem: null,
    payQrSvg: '<svg id="pay-qr"></svg>',
    total: '1150.00',
    vatAmount: '150.00',
    subtotal: '1000.00',
    subtotalShown: '1000.00',
    vatRate: 15,
    shipping: 0,
  }, money));
  return area.innerHTML;
}

module.exports = { render, context, CURRENCIES };
