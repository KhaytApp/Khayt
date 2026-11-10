'use strict';

/**
 * A customer's address, in fields: Turki, Nov 10 — "address line 1 2 and 3,
 * city, country, zip code, state and anything I might have missed". The
 * design is ~/Khayt-proposals/customer-address-design.md (accepted Nov 10).
 *
 * A row of `client.addresses[]` was `{ id, label, address }`, the address one
 * free text. It gains fields; the text stays, ALWAYS written, because every
 * build already in a shop reads it, and the old desktop's save drops a row
 * whose label and address are both blank (and throws on one that is not a
 * string). So:
 *
 *  - A row with no field filled in is UNSTRUCTURED. Its text is the address,
 *    exactly as today. Nothing here ever parses it into fields: a guessed
 *    split of a free-text address is a wrong address.
 *  - Saving fields writes them, writes `address` = the fields formatted, and
 *    writes `textOf` = that same text.
 *  - When `address` no longer equals `textOf`, an older build has edited the
 *    text since. Whole-record sync cannot see that, so this does: the TEXT is
 *    then the address (it is the newer edit), and the row says so until the
 *    shop saves its fields again.
 *
 * Which row is the default for shipping and for billing is an id on the
 * client (`defaultShippingId`, `defaultBillingId`), not a flag on a row — a
 * flag can end up true on two rows; an id cannot. A missing or dangling id
 * falls back to the first row, today's rule.
 *
 * No coordinates and no map pin: that would be Location data in the App Store
 * label and on /privacy.
 *
 * PURE: no globals, no clock, no I/O. Rows are never changed in place; every
 * writer returns a new object and keeps every key it does not know.
 */
(function (global) {

  /** The fields, in the order the form shows them by default. */
  const FIELDS = ['line1', 'line2', 'line3', 'district', 'city', 'region', 'postalCode', 'country'];
  /** Saudi National Address: shown when the country is SA. */
  const NATIONAL_ADDRESS = ['buildingNumber', 'additionalNumber', 'shortAddress'];
  /** Who receives it, and how to find the door. */
  const DELIVERY = ['recipientName', 'recipientPhone', 'deliveryNotes'];
  /** Every field that makes a row structured. Recipient and notes do not: a
   *  free-text row with a recipient on it is still an unsplit address. */
  const ADDRESS_FIELDS = FIELDS.concat(NATIONAL_ADDRESS);
  const ALL_FIELDS = ADDRESS_FIELDS.concat(DELIVERY);

  /** Saudi forms: postal code 5 digits, building and additional 4, the short
   *  address 4 letters then 4 digits (RRRD2929). */
  const SA_RULES = {
    postalCode: /^\d{5}$/,
    buildingNumber: /^\d{4}$/,
    additionalNumber: /^\d{4}$/,
    shortAddress: /^[A-Z]{4}\d{4}$/,
  };
  const DIGIT_FIELDS = ['postalCode', 'buildingNumber', 'additionalNumber'];

  /** The longest each field may be, the same as Khayt Cloud's. A field is cut
   *  to its cap when it is saved. The `address` text is never cut here: an
   *  unsplit address the shop typed long ago is kept whole, and an editor
   *  shows CAPS.address as the field's limit for new text. */
  const CAPS = {
    id: 64, label: 60, line1: 200, line2: 200, line3: 200, district: 200,
    city: 100, region: 100, postalCode: 20, country: 2,
    buildingNumber: 10, additionalNumber: 10, shortAddress: 12,
    recipientName: 120, recipientPhone: 40, deliveryNotes: 300, address: 500,
  };

  const str = (v) => (typeof v === 'string' ? v : v == null ? '' : String(v));
  const has = (v) => str(v).trim() !== '';

  /** Arabic-Indic and Persian digits to ASCII; a shop types what its keyboard has. */
  function asciiDigits(s) {
    return str(s).replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
      .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06F0));
  }

  /** The shop's country: the tax country it chose, else Saudi Arabia. */
  function shopCountry(settings) {
    const s = settings && typeof settings === 'object' ? settings : {};
    const c = (s.tax && s.tax.country) || s.country || 'SA';
    return str(c).trim().toUpperCase() || 'SA';
  }

  /** The row's country, else the shop's. */
  function countryOf(row, opts) {
    const c = str(row && row.country).trim().toUpperCase();
    return c || str(opts && opts.shopCountry).trim().toUpperCase() || 'SA';
  }

  /** True when any address field is filled in. */
  function isStructured(row) {
    if (!row || typeof row !== 'object') return false;
    return ADDRESS_FIELDS.some((k) => has(row[k]));
  }

  /**
   * One row tidied: strings trimmed, the country upper-cased, digits made
   * ASCII where a field is a number, the short address upper-cased with no
   * spaces. Keys this module does not know are kept as they are.
   */
  function normalise(row) {
    const out = Object.assign({}, row && typeof row === 'object' ? row : {});
    for (const k of ALL_FIELDS) {
      if (!(k in out)) continue;
      let v = str(out[k]).trim();
      if (DIGIT_FIELDS.includes(k) || k === 'shortAddress' || k === 'recipientPhone') v = asciiDigits(v);
      if (DIGIT_FIELDS.includes(k)) v = v.replace(/\s+/g, '');
      if (k === 'country') v = v.toUpperCase();
      if (k === 'shortAddress') v = v.replace(/\s+/g, '').toUpperCase();
      // The country is not cut: "Saudi" cut to two letters would be a real
      // code (SA) by accident. A country that is not two letters is a warning.
      out[k] = CAPS[k] && k !== 'country' ? Array.from(v).slice(0, CAPS[k]).join('') : v;
    }
    return out;
  }

  /**
   * What is wrong with a row, leniently: nothing is required except that the
   * row says where — a first line, a Saudi short address, or the old text.
   * A field in the wrong form is a WARNING the editor shows on the field; the
   * row still saves.
   *   → { ok, empty, warnings: [{ field, code }] }
   */
  function validate(row, opts) {
    const r = normalise(row);
    const warnings = [];
    const empty = !has(r.line1) && !has(r.shortAddress) && !has(r.address);
    if (countryOf(r, opts) === 'SA') {
      for (const k of Object.keys(SA_RULES)) {
        if (has(r[k]) && !SA_RULES[k].test(r[k])) warnings.push({ field: k, code: 'sa_' + k });
      }
    }
    if (has(r.country) && !/^[A-Z]{2}$/.test(r.country)) warnings.push({ field: 'country', code: 'country' });
    return { ok: !empty, empty, warnings };
  }

  /** The form's field order for a country. Saudi Arabia leads with the
   *  National Address; elsewhere the general order. */
  function fieldOrder(country) {
    const c = str(country).toUpperCase();
    if (c === 'SA') {
      return ['country', 'shortAddress', 'buildingNumber', 'line1', 'line2', 'line3', 'district',
        'city', 'postalCode', 'additionalNumber', 'region'];
    }
    return ['country', 'line1', 'line2', 'line3', 'district', 'city', 'region', 'postalCode'];
  }

  /**
   * The fields as an address a person reads, one line per '\n'.
   * Saudi Arabia follows the National Address:
   *   8228 Imam Abdullah Ibn Saud Rd     (building number + street)
   *   Al Mursalat                         (district)
   *   Riyadh 12345-6789                   (city, postal code - additional number)
   *   RRRD2929                            (short address)
   * Elsewhere: lines, district, "city, region postal code".
   * The country is named only when it is not the shop's, through
   * `opts.countryName(code)` when given (the code otherwise).
   */
  function formatAddress(row, opts) {
    const o = opts && typeof opts === 'object' ? opts : {};
    const r = normalise(row);
    const country = countryOf(r, o);
    const lines = [];
    const push = (s) => { if (has(s)) lines.push(str(s).trim()); };
    if (country === 'SA') {
      push([r.buildingNumber, r.line1].filter(has).join(' '));
      push(r.line2); push(r.line3); push(r.district);
      const postal = [r.postalCode, r.additionalNumber].filter(has).join('-');
      push([r.city, postal].filter(has).join(' '));
      push(r.region);
      push(r.shortAddress);
    } else {
      push(r.line1); push(r.line2); push(r.line3); push(r.district);
      const place = [r.city, r.region].filter(has).join(', ');
      push([place, r.postalCode].filter(has).join(' '));
    }
    const home = str(o.shopCountry).toUpperCase() || 'SA';
    if (has(r.country) && r.country !== home) {
      push(typeof o.countryName === 'function' ? (o.countryName(r.country) || r.country) : r.country);
    }
    return lines.join('\n');
  }

  /** An older build has changed the text since the fields were saved. */
  function textEditedElsewhere(row) {
    if (!isStructured(row) || !has(row.textOf)) return false;
    return str(row.address) !== str(row.textOf);
  }

  /** How the editor shows a row: 'empty' | 'unstructured' | 'structured' |
   *  'edited_elsewhere'. */
  function stateOf(row) {
    if (!row || typeof row !== 'object') return 'empty';
    if (!isStructured(row)) return has(row.address) ? 'unstructured' : 'empty';
    return textEditedElsewhere(row) ? 'edited_elsewhere' : 'structured';
  }

  /** The address as text, whatever the row's state. The fields when they are
   *  current; the text when the row is unsplit or was edited elsewhere since. */
  function textOf(row, opts) {
    if (!row || typeof row !== 'object') return '';
    const st = stateOf(row);
    if (st === 'structured') return formatAddress(row, opts);
    return str(row.address).trim();
  }

  /**
   * Save fields onto a row: a new row with the fields tidied, `address` and
   * `textOf` both set to the formatted text. `fields` may hold any of
   * ALL_FIELDS and `label`; a field given as '' is cleared. Keys the row
   * already had that this does not know are kept.
   * Saving no address field at all leaves the row's text as the address
   * (the shop cleared the fields of an unsplit row): `textOf` is removed so
   * the row reads as unstructured again.
   */
  function applyFields(row, fields, opts) {
    const base = Object.assign({}, row && typeof row === 'object' ? row : {});
    const f = fields && typeof fields === 'object' ? fields : {};
    for (const k of ALL_FIELDS.concat(['label'])) {
      if (k in f) base[k] = str(f[k]);
    }
    const out = normalise(base);
    for (const k of ALL_FIELDS) if (k in out && out[k] === '') delete out[k];
    if (isStructured(out)) {
      const text = formatAddress(out, opts);
      out.address = text;
      out.textOf = text;
    } else {
      delete out.textOf;
      if (!('address' in out)) out.address = '';
    }
    return rowForOldBuilds(out);
  }

  /**
   * A row as every build can read it. The desktop's save before Nov 2026
   * runs `a.label.trim() || a.address.trim()` over every row and THROWS on a
   * row that is null, or whose label or address is missing or not a string —
   * one bad row and the shop cannot save that customer on that computer.
   * Every row a new build writes goes through here: `label` and `address` are
   * strings (blank allowed), and every other key is kept.
   */
  function rowForOldBuilds(row) {
    const out = Object.assign({}, row && typeof row === 'object' ? row : {});
    out.label = str(out.label);
    out.address = str(out.address);
    return out;
  }

  /** A client's rows, each readable by every build, with rows that are not
   *  objects left out (they cannot be read by any build). */
  function rowsForOldBuilds(rows) {
    return (Array.isArray(rows) ? rows : []).filter((r) => r && typeof r === 'object').map(rowForOldBuilds);
  }

  /** The rows of a client that say anything. */
  function rowsOf(client) {
    const rows = client && Array.isArray(client.addresses) ? client.addresses : [];
    return rows.filter((r) => r && typeof r === 'object' && stateOf(r) !== 'empty');
  }

  /**
   * The client's default row for 'shipping' or 'billing': the row its id
   * names, else the first row that says anything, else — for a client whose
   * only address is the old top-level text a CSV import wrote — that text as
   * an unsplit row with no id. null when there is none.
   */
  function defaultRow(client, kind) {
    if (!client || typeof client !== 'object') return null;
    const rows = rowsOf(client);
    const id = kind === 'billing' ? client.defaultBillingId : client.defaultShippingId;
    if (has(id)) {
      const hit = rows.find((r) => r.id === id);
      if (hit) return hit;
    }
    if (rows.length) return rows[0];
    if (has(client.address)) {
      const legacy = { id: null, label: '', address: str(client.address).trim(), legacy: true };
      if (has(client.city)) legacy.city = str(client.city).trim();
      return legacy;
    }
    return null;
  }

  /**
   * What a job keeps of the address it ships to: a copy, not a link, so a
   * later edit to the customer does not move a job already shipped.
   *   → { addressId, text, ...fields that are set } | null
   * The recipient falls back to the customer's own name and phone when the
   * row names nobody else (`opts.nameOf(client)` gives the name).
   */
  function shipTo(row, client, opts) {
    if (!row || typeof row !== 'object') return null;
    const o = opts && typeof opts === 'object' ? opts : {};
    const snap = { addressId: has(row.id) ? row.id : null, text: textOf(row, o) };
    const current = stateOf(row) === 'structured';
    for (const k of ADDRESS_FIELDS) {
      // An unsplit row has no fields to copy, and one edited elsewhere has
      // fields that no longer match its text: the text is the address.
      if (current && has(row[k])) snap[k] = normalise(row)[k];
    }
    if (current && !has(snap.country)) snap.country = countryOf(row, o);
    if (row.legacy && has(row.city)) snap.city = str(row.city).trim();
    const name = has(row.recipientName) ? str(row.recipientName).trim()
      : (client && typeof o.nameOf === 'function' ? str(o.nameOf(client)).trim() : '');
    const phone = has(row.recipientPhone) ? asciiDigits(row.recipientPhone).trim() : str(client && client.phone).trim();
    if (name) snap.recipientName = name;
    if (phone) snap.recipientPhone = phone;
    if (has(row.deliveryNotes)) snap.deliveryNotes = str(row.deliveryNotes).trim();
    return snap.text || name || phone ? snap : null;
  }

  /**
   * Where a job goes, as text — the one answer the phone, the packing slip
   * and the delivery note all give: the job's own snapshot (`order.shipTo`),
   * else the text typed on the job (`order.deliveryAddress`), else the
   * customer's default shipping row. '' when there is none.
   */
  function shipAddressOf(order, client, opts) {
    const o = order && typeof order === 'object' ? order : {};
    if (o.shipTo && typeof o.shipTo === 'object' && has(o.shipTo.text)) return str(o.shipTo.text).trim();
    if (has(o.deliveryAddress)) return str(o.deliveryAddress).trim();
    return textOf(defaultRow(client, 'shipping'), opts);
  }

  const api = {
    FIELDS, NATIONAL_ADDRESS, DELIVERY, ADDRESS_FIELDS, ALL_FIELDS, SA_RULES, CAPS,
    rowForOldBuilds, rowsForOldBuilds, shipAddressOf,
    asciiDigits, shopCountry, countryOf, isStructured, normalise, validate, fieldOrder,
    formatAddress, textEditedElsewhere, stateOf, textOf, applyFields, rowsOf, defaultRow, shipTo,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytCustomerAddress = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
