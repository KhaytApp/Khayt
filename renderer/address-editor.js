/**
 * The customer address editor — one address book row in fields.
 *
 * The rule is lib/customer-address.js (KhaytCustomerAddress), shared with the
 * Mac; this is the desktop's screen for it (Figma: Electron 52:2725, from Mac
 * 70:335 / 70:435 / 70:516). Country comes first and decides the fields and
 * their order; the National Address block shows only for Saudi Arabia;
 * nothing is required but one of line 1, the short address or the old text; a
 * value in the wrong form is a note under its field, never a refused save.
 *
 * Free text is NEVER split into fields. An old free-text row opens as its
 * text, with an offer to fill the fields in by hand.
 *
 * The pure helpers at the top are unit-tested (test/address-editor.test.js);
 * openAddressEditor is the DOM, driven by scripts/e2e-address-editor-smoke.mjs.
 */
(function (global) {
  const A = () => global.KhaytCustomerAddress;

  /** ISO 3166-1 alpha-2, every assigned code. Names come from Intl. */
  const COUNTRY_CODES = ('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ ' +
    'CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL ' +
    'GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR ' +
    'LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK ' +
    'PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR ' +
    'TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW').split(' ');

  /** The National Address block, in the order the design draws it. */
  const NATIONAL_BLOCK = ['shortAddress', 'buildingNumber', 'additionalNumber'];

  /** Fields typed left to right even in Arabic: numbers, codes and the phone. */
  const LTR_FIELDS = ['postalCode', 'buildingNumber', 'additionalNumber', 'shortAddress', 'recipientPhone'];
  const NUMERIC_FIELDS = ['postalCode', 'buildingNumber', 'additionalNumber'];

  const str = (v) => (typeof v === 'string' ? v : v == null ? '' : String(v));

  /** A country's name in a language, the code when Intl does not know it. */
  const namers = new Map();
  function countryName(code, lang) {
    const c = str(code).toUpperCase();
    if (!c) return '';
    try {
      const l = lang || 'en';
      if (!namers.has(l)) namers.set(l, new Intl.DisplayNames([l], { type: 'region' }));
      return namers.get(l).of(c) || c;
    } catch (_) {
      return c;
    }
  }

  /** The country picker's options, sorted by name in `lang`; `current` is
   *  kept even when it is not a known code (an older or imported row). */
  function countryOptions(lang, current) {
    const codes = COUNTRY_CODES.slice();
    const cur = str(current).toUpperCase();
    if (cur && !codes.includes(cur)) codes.push(cur);
    const named = codes.map((code) => ({ code, name: countryName(code, lang) }));
    let coll;
    try { coll = new Intl.Collator(lang || 'en'); } catch (_) { coll = new Intl.Collator('en'); }
    return named.sort((a, b) => coll.compare(a.name, b.name));
  }

  /**
   * What the form draws for a country: the National Address block (Saudi
   * Arabia only) and then the other fields in the module's order.
   *   → { national: [...], fields: [...] }  (country itself is drawn first, apart)
   */
  function editorLayout(country) {
    const c = str(country).toUpperCase();
    const order = A().fieldOrder(c);
    const national = c === 'SA' ? NATIONAL_BLOCK.slice() : [];
    const fields = order.filter((f) => f !== 'country' && !A().NATIONAL_ADDRESS.includes(f));
    return { national, fields };
  }

  /** The i18n key of a field's label; line 1 and the region read differently
   *  in Saudi Arabia (the stored key is the same everywhere). */
  function fieldLabelKey(field, country) {
    const sa = str(country).toUpperCase() === 'SA';
    if (field === 'line1' && sa) return 'addr.f.line1_sa';
    if (field === 'region' && !sa) return 'addr.f.region_intl';
    return 'addr.f.' + field;
  }

  /** The i18n key of a validate() warning. */
  function warningKey(code) {
    return 'addr.warn.' + str(code);
  }

  /**
   * A row as one line on screen: the fields formatted for display when they
   * are current, else the row's text as it is. Never parsed, never stored.
   */
  function oneLine(row, opts) {
    if (!row || typeof row !== 'object') return '';
    const st = A().stateOf(row);
    const text = st === 'structured'
      ? A().formatAddress(row, Object.assign({}, opts || {}, { display: true }))
      : str(row.address);
    return text.split('\n').map((s) => s.trim()).filter(Boolean).join(', ');
  }

  /** What a row in the customer editor says under its address:
   *  → { badge: 'check' | null, note: i18n key | null, tone: 'muted' | 'warn' } */
  function rowHint(row) {
    const st = A().stateOf(row);
    if (st === 'unstructured') return { badge: null, note: 'addr.unsplit', tone: 'muted' };
    if (st === 'edited_elsewhere') return { badge: 'check', note: 'addr.edited_elsewhere', tone: 'warn' };
    return { badge: null, note: null, tone: 'muted' };
  }

  /**
   * The row to store from what the editor holds.
   *   row     — the row as it was ({ id } for a new one)
   *   form    — { label, country, text, fields: {…} } where `text` is the
   *             free text (only while the row is shown as text) and `fields`
   *             every field the form draws or holds
   *   mode    — 'fields' | 'text'
   *  → { row, empty, warnings }  (empty: nothing says where — do not save)
   * Fields the form no longer draws (the National Address after leaving
   * Saudi Arabia) are cleared, so a stale building number never prints.
   */
  function rowFromForm(row, form, mode, opts) {
    const f = form && typeof form === 'object' ? form : {};
    const base = Object.assign({}, row && typeof row === 'object' ? row : {});
    if (mode === 'text') base.address = str(f.text);
    const fields = { label: str(f.label) };
    for (const k of A().DELIVERY) fields[k] = str((f.fields || {})[k]);
    if (mode === 'fields') {
      const country = str(f.country).toUpperCase();
      const shown = editorLayout(country);
      const keep = new Set(shown.national.concat(shown.fields));
      for (const k of A().ADDRESS_FIELDS) {
        if (k === 'country') fields.country = country;
        else fields[k] = keep.has(k) ? str((f.fields || {})[k]) : '';
      }
      // A country and nothing else is not an address: the row keeps its text.
      const anyOther = A().ADDRESS_FIELDS.some((k) => k !== 'country' && fields[k].trim() !== '');
      if (!anyOther) fields.country = '';
    }
    const out = A().applyFields(base, fields, opts);
    const v = A().validate(out, opts);
    return { row: out, empty: v.empty, warnings: v.warnings };
  }

  /* ============================================================
     The editor (DOM)
     ============================================================ */

  function tt(k, vars) { return global.t(k, vars); }
  function esc(s) { return global.escapeHtml(str(s)); }

  /**
   * Open the editor over the customer editor.
   *   row          — the row to edit, or null for a new one (`newId` names it)
   *   shopCountry  — the country a new address starts on
   *   isDefault    — whether this row is the customer's default for shipping
   *   onSave(row, { isDefault }) — the row to store; called once, then closed
   *   onRemove()   — remove the row (not offered for a new one)
   */
  function openAddressEditor(opts) {
    const o = opts || {};
    const Lib = A();
    const lang = (global.i18n && global.i18n.current) || 'en';
    const shopCountry = str(o.shopCountry).toUpperCase() || 'SA';
    const isNew = !o.row;
    const row = o.row ? Object.assign({}, o.row) : { id: o.newId, label: '', address: '' };
    const state = Lib.stateOf(row);
    let mode = state === 'unstructured' ? 'text' : 'fields';
    const values = {};
    for (const k of Lib.ALL_FIELDS) values[k] = str(row[k]);
    values.country = str(row.country).toUpperCase() || shopCountry;
    let text = str(row.address);
    const fmtOpts = { shopCountry, countryName: (c) => countryName(c, lang) };

    const inputHtml = (k, country) => {
      const ltr = LTR_FIELDS.includes(k);
      const type = k === 'recipientPhone' ? 'tel' : 'text';
      const im = NUMERIC_FIELDS.includes(k) ? ' inputmode="numeric"' : '';
      const cap = Lib.CAPS[k] ? ` maxlength="${Lib.CAPS[k]}"` : '';
      const ph = k === 'shortAddress' ? ' placeholder="RRRD2929"' : '';
      return `<div class="addr-fld${k === 'line1' || k === 'deliveryNotes' ? ' addr-wide' : ''}">
        <label for="addrF_${k}">${esc(tt(fieldLabelKey(k, country)))}</label>
        <input type="${type}" id="addrF_${k}" data-addr="${k}"${ltr ? ' dir="ltr"' : ''}${im}${cap}${ph} value="${esc(values[k])}" autocomplete="off">
        <small class="addr-warn" data-warn-for="${k}" hidden></small>
      </div>`;
    };

    const fieldsHtml = () => {
      const c = values.country;
      const lay = editorLayout(c);
      const na = lay.national.length ? `<div class="addr-na">
          <div class="addr-kicker">${esc(tt('addr.national'))}</div>
          <div class="addr-na-grid">${lay.national.map((k) => inputHtml(k, c)).join('')}</div>
        </div>` : '';
      return na + `<div class="addr-grid">${lay.fields.map((k) => inputHtml(k, c)).join('')}</div>`;
    };

    const elsewhereHtml = state === 'edited_elsewhere' ? `<div class="addr-elsewhere" data-addr-state="edited_elsewhere">
        <div class="addr-text-ref">${esc(row.address)}</div>
        <small>${esc(tt('addr.edited_elsewhere'))} ${esc(tt('addr.edited_elsewhere_save'))}</small>
      </div>` : '';

    const bodyHtml = () => {
      const top = `<div class="addr-grid">
          <div class="addr-fld"><label for="addrLabel">${esc(tt('addr.label'))}</label>
            <input type="text" id="addrLabel" maxlength="${Lib.CAPS.label}" value="${esc(row.label)}" placeholder="${esc(tt('addr.label_ph'))}"></div>
          <div class="addr-fld"><label for="addrCountry">${esc(tt('addr.country'))}</label>
            <select id="addrCountry"${mode === 'text' ? ' disabled' : ''}>${countryOptions(lang, values.country).map((c) =>
              `<option value="${esc(c.code)}"${c.code === values.country ? ' selected' : ''}>${esc(c.name)}</option>`).join('')}</select></div>
        </div>`;
      const main = mode === 'text'
        ? `<div class="addr-fld addr-wide" data-addr-state="unstructured">
            <label for="addrText">${esc(tt('addr.text'))}</label>
            <textarea id="addrText" rows="3" maxlength="${Lib.CAPS.address}">${esc(text)}</textarea>
            <small class="addr-muted">${esc(tt('addr.unsplit'))} ${esc(tt('addr.fill_hint'))}</small>
            <div><button type="button" class="btn small" id="addrFillFields">${esc(tt('addr.fill_fields'))}</button></div>
          </div>`
        : (state === 'unstructured' ? `<div class="addr-elsewhere"><div class="addr-text-ref">${esc(text)}</div>
            <small>${esc(tt('addr.fill_hint'))}</small></div>` : '') + `<div id="addrFields">${fieldsHtml()}</div>`;
      const delivery = `<div class="addr-sec">
          <div class="addr-kicker">${esc(tt('addr.deliver_else'))}</div>
          <div class="addr-grid">${['recipientName', 'recipientPhone', 'deliveryNotes'].map((k) => inputHtml(k, values.country)).join('')}</div>
        </div>`;
      const prints = `<div class="addr-sec">
          <div class="addr-kicker">${esc(tt('addr.prints_as'))}</div>
          <div class="addr-prints" id="addrPrints"></div>
        </div>`;
      return `<div class="addr-need" id="addrNeed" hidden>${esc(tt('addr.need_where'))}</div>` + elsewhereHtml + top + main + delivery + prints;
    };

    const overlay = global.appendStackedModal(`
      <div class="modal modal-form addr-editor" role="dialog" aria-modal="true" aria-labelledby="addrEdTitle">
        <div class="modal-header">
          <h3 id="addrEdTitle">${esc(tt('addr.title'))}</h3>
          <label class="addr-default"><input type="checkbox" id="addrDefault"${o.isDefault ? ' checked' : ''}> ${esc(tt('addr.default_shipping'))}</label>
        </div>
        <div class="modal-body" id="addrBody"></div>
        <div class="modal-footer">
          ${isNew ? '' : `<button type="button" class="btn ghost addr-remove" data-act="addr-remove">${esc(tt('addr.remove'))}</button>`}
          <button type="button" class="btn ghost" data-act="addr-cancel">${esc(tt('common.cancel'))}</button>
          <button type="button" class="btn primary" data-act="addr-save">${esc(tt('common.save'))}</button>
        </div>
      </div>`, { zIndex: 10040 });
    const modal = overlay.querySelector('.modal');
    const body = overlay.querySelector('#addrBody');

    /** Everything the form holds right now. */
    const readForm = () => {
      body.querySelectorAll('[data-addr]').forEach((inp) => { values[inp.dataset.addr] = inp.value; });
      const ta = body.querySelector('#addrText');
      if (ta) text = ta.value;
      const lab = body.querySelector('#addrLabel');
      if (lab) row.label = lab.value;
      return { label: row.label, country: values.country, text, fields: Object.assign({}, values) };
    };

    const refresh = () => {
      const r = rowFromForm(row, readForm(), mode, { shopCountry });
      const shown = mode === 'fields' && Lib.isStructured(r.row)
        ? Lib.formatAddress(r.row, Object.assign({ display: true }, fmtOpts))
        : str(r.row.address);
      const pr = body.querySelector('#addrPrints');
      if (pr) pr.textContent = shown;
      const byField = {};
      for (const w of r.warnings) byField[w.field] = w.code;
      body.querySelectorAll('[data-warn-for]').forEach((el) => {
        const code = byField[el.dataset.warnFor];
        el.hidden = !code;
        el.textContent = code ? tt(warningKey(code)) : '';
      });
      return r;
    };

    const draw = () => {
      body.innerHTML = bodyHtml();
      if (typeof global.wireFormLabels === 'function') global.wireFormLabels(body);
      refresh();
    };
    draw();

    body.addEventListener('input', () => { refresh(); });
    body.addEventListener('change', (e) => {
      if (e.target && e.target.id === 'addrCountry') {
        readForm();
        values.country = e.target.value;
        const wrap = body.querySelector('#addrFields');
        if (wrap) wrap.innerHTML = fieldsHtml();
        refresh();
      }
    });
    body.addEventListener('click', (e) => {
      if (e.target && e.target.id === 'addrFillFields') {
        readForm();
        mode = 'fields';
        draw();
        body.querySelector('#addrFields input')?.focus();
      }
    });

    const close = () => {
      document.removeEventListener('keydown', escH);
      const i = global._escHandlerStack.indexOf(escH);
      if (i !== -1) global._escHandlerStack.splice(i, 1);
      overlay.remove();
    };
    const escH = (e) => {
      if (e.key !== 'Escape') return;
      if (global._escHandlerStack[global._escHandlerStack.length - 1] !== escH) return;
      close();
    };
    global._escHandlerStack.push(escH);
    document.addEventListener('keydown', escH);
    overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
    modal.querySelector('[data-act="addr-cancel"]').addEventListener('click', close);
    modal.querySelector('[data-act="addr-remove"]')?.addEventListener('click', () => {
      close();
      if (typeof o.onRemove === 'function') o.onRemove();
    });
    modal.querySelector('[data-act="addr-save"]').addEventListener('click', () => {
      const r = refresh();
      const need = body.querySelector('#addrNeed');
      if (r.empty) { if (need) need.hidden = false; return; }
      const isDefault = !!modal.querySelector('#addrDefault')?.checked;
      close();
      if (typeof o.onSave === 'function') o.onSave(r.row, { isDefault });
    });
    return overlay;
  }

  const api = {
    COUNTRY_CODES, NATIONAL_BLOCK, LTR_FIELDS,
    countryName, countryOptions, editorLayout, fieldLabelKey, warningKey, oneLine, rowHint, rowFromForm,
    openAddressEditor,
  };
  global.KhaytAddressEditor = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
