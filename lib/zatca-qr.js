'use strict';

/**
 * The QR a Saudi tax invoice must carry.
 *
 * ZATCA Phase 1: five fields — the seller, their VAT number, the moment, the
 * total and the tax — packed as BER-TLV and base64'd. A scanner reads it and a
 * tax officer checks it against the paper.
 *
 * It lived in `renderer/invoicing.js`, so the only thing that could produce a
 * compliant invoice was the Electron window. Nothing about it needs a browser:
 * `TextEncoder` and `Uint8Array` are the language, and the base64 step is the
 * one platform call, taken through `ctx.base64` because Node, the renderer and
 * JavaScriptCore each spell it differently.
 *
 * A QR MISSING A REQUIRED TAG SCANS AND IS INVALID, which is worse than no QR
 * at all: a code that reads invites no question. `readiness` is what refuses to
 * draw one, and it names the field that is missing so the document can say it.
 */
(function (global) {

/**
 * May a QR be drawn for this shop at all?
 *
 * `sellerName` is passed in rather than read off the settings, because the
 * shop's name lives in whichever content language it writes and only the app
 * knows how to resolve that. The message codes are Khayt's own, so the document
 * names the missing field in the shop's language.
 */
function readiness(settings, sellerName) {
  const cfg = settings || {};
  const missing = [];
  if (!String(cfg.bizName || cfg.shopName || '').trim() && !String(sellerName || '').trim()) {
    missing.push('inv.qr_missing_seller');
  }
  if (!String(cfg.vat || '').trim()) missing.push('inv.qr_missing_vat');
  return { ok: missing.length === 0, missing };
}

/**
 * The five tags, packed and base64'd.
 *
 * `ctx.base64` turns bytes into base64 — `btoa` in a browser, a Buffer in Node,
 * whatever the host has. Passed in rather than sniffed for, because a module
 * that silently produces no QR on a platform it did not recognise is the
 * failure this whole file exists to prevent.
 */
/**
 * UTF-8 bytes, without `TextEncoder`.
 *
 * JavaScriptCore has no `TextEncoder` — the Mac app's first attempt at a QR
 * threw `Can't find variable: TextEncoder`, which for a legally required tax
 * artefact is a document that cannot be issued. A shop's own name is the field
 * most likely to be non-ASCII, so this is not a corner case in Saudi Arabia.
 *
 * Surrogate pairs are joined before encoding, so an emoji in a shop name is one
 * four-byte character rather than two broken three-byte ones.
 */
function utf8(str) {
  const s = String(str == null ? '' : str);
  const out = [];
  for (let i = 0; i < s.length; i++) {
    let c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const next = s.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        c = 0x10000 + ((c - 0xd800) << 10) + (next - 0xdc00);
        i++;
      }
    }
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f),
                  0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
  }
  return out;
}

/**
 * Base64, without `btoa` or `Buffer`.
 *
 * Same reason: JavaScriptCore has neither. A host may still supply its own
 * through `ctx.base64` — the renderer passes `btoa` — but a module that can
 * only work where somebody remembered to hand it one is a module that produces
 * no QR on the platform nobody tested.
 */
const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function base64(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
    out += B64[a >> 2];
    out += B64[((a & 3) << 4) | (b === undefined ? 0 : b >> 4)];
    out += b === undefined ? '=' : B64[((b & 15) << 2) | (c === undefined ? 0 : c >> 6)];
    out += c === undefined ? '=' : B64[c & 63];
  }
  return out;
}

/**
 * The moment an invoice was issued, as tag 3 must carry it.
 *
 * ZATCA Phase 1 tag 3 is the invoice's DATE AND TIME, ISO 8601 — ZATCA's own
 * samples read `2022-04-25T15:30:00Z`. The Mac passed the order's day,
 * "2026-07-02", which a validator reads as an incomplete stamp; Electron
 * passed `toISOString()`. Both now pass through here.
 *
 * Accepts a string or an order (`{ timestamp, date }`, timestamp first). A
 * day with no time is stamped at local NOON — the renderer's own rule, so a
 * book dated in any timezone keeps its day — and every result is UTC to the
 * second, without milliseconds. Something that will not parse is returned as
 * given rather than replaced: an honest wrong stamp beats an invented one.
 */
function issueTimestamp(input) {
  let raw = input;
  if (input && typeof input === 'object') raw = input.timestamp || input.date || '';
  const s = String(raw == null ? '' : raw).trim();
  if (!s) return '';
  const d = /^\d{4}-\d{2}-\d{2}$/.test(s) ? new Date(s + 'T12:00:00') : new Date(s);
  if (isNaN(d.getTime())) return s;
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

function buildTLV({ sellerName, vatNumber, timestamp, total, vatAmount }, ctx) {
  function tlv(tag, value) {
    const bytes = utf8(value);
    const len = bytes.length;
    // BER-TLV: use two-byte length for values > 127 bytes (0x81 + length byte)
    let header;
    if (len <= 127) {
      header = [tag, len];
    } else if (len <= 255) {
      header = [tag, 0x81, len];
    } else {
      header = [tag, 0x82, (len >> 8) & 0xff, len & 0xff];
    }
    return header.concat(bytes);
  }
  const fields = [
    tlv(1, String(sellerName || '')),
    tlv(2, String(vatNumber  || '')),
    tlv(3, issueTimestamp(timestamp)),
    tlv(4, String(total      || '')),
    tlv(5, String(vatAmount  || '')),
  ];
  const combined = [];
  for (const b of fields) for (const byte of b) combined.push(byte);
  // A host may supply its own — the renderer passes btoa — but the default is
  // this module's, so there is no platform on which it quietly produces nothing.
  if (ctx && ctx.base64) {
    let bin = '';
    for (let i = 0; i < combined.length; i++) bin += String.fromCharCode(combined[i]);
    return ctx.base64(bin);
  }
  return base64(combined);
}

// ── READING ONE BACK: a supplier's receipt, scanned ──────────────────────
//
// The same five tags, from the other side: a shop holding a Saudi supplier's
// tax invoice reads the seller, their VAT number, the moment, the total and
// the VAT off the QR — the exact input VAT, with no OCR and no typing. Phase 2
// codes add tags 6–9 (hash, signature, public key, stamp); they are skipped,
// never refused, because a valid Phase 2 receipt is still a valid receipt.
//
// STRICT, because what comes in is a stranger's bytes: every length is checked
// against the buffer, every field must be UTF-8, and each refusal says why.

const B64_INDEX = (function () {
  const m = {};
  for (let i = 0; i < B64.length; i++) m[B64[i]] = i;
  m['-'] = 62; m['_'] = 63;   // the URL-safe alphabet, which some generators use
  return m;
})();

/** A receipt QR is a few hundred bytes; Phase 2 with a certificate a few thousand. */
const MAX_TEXT = 16384;

/** base64 → bytes, or null. Whitespace is ignored; padding is optional. */
function unbase64(text) {
  const s = String(text == null ? '' : text).replace(/\s+/g, '').replace(/=+$/, '');
  if (!s || s.length % 4 === 1) return null;
  const out = [];
  let buf = 0, bits = 0;
  for (let i = 0; i < s.length; i++) {
    const v = B64_INDEX[s[i]];
    if (v === undefined) return null;
    buf = ((buf << 6) | v) & 0xffffff;
    bits += 6;
    if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 0xff); }
  }
  return out;
}

/** UTF-8 bytes → string, or null for anything that is not well-formed UTF-8. */
function fromUtf8(bytes) {
  let out = '';
  let i = 0;
  while (i < bytes.length) {
    const b = bytes[i];
    let cp, n;
    if (b < 0x80) { cp = b; n = 0; }
    else if (b >= 0xc2 && b <= 0xdf) { cp = b & 0x1f; n = 1; }
    else if (b >= 0xe0 && b <= 0xef) { cp = b & 0x0f; n = 2; }
    else if (b >= 0xf0 && b <= 0xf4) { cp = b & 0x07; n = 3; }
    else return null;
    if (i + n >= bytes.length && n > 0) return null;
    for (let k = 1; k <= n; k++) {
      const c = bytes[i + k];
      if ((c & 0xc0) !== 0x80) return null;
      cp = (cp << 6) | (c & 0x3f);
    }
    // Overlong forms, surrogates and past-Unicode are not UTF-8.
    if ((n === 2 && cp < 0x800) || (n === 3 && (cp < 0x10000 || cp > 0x10ffff)) ||
        (cp >= 0xd800 && cp <= 0xdfff)) return null;
    out += String.fromCodePoint(cp);
    i += n + 1;
  }
  return out;
}

/** An amount as a ZATCA QR writes it: digits and an optional decimal point. */
function amountOf(text) {
  const t = String(text).trim();
  if (!/^\d{1,12}(\.\d{1,6})?$/.test(t)) return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}

/**
 * What a receipt's QR says, or why it cannot be read.
 *
 * Returns `{ ok: true, receipt: { sellerName, vatNumber, timestamp, total,
 * vatAmount, phase2 } }`, or `{ ok: false, reason }` with `reason` one of:
 * `empty`, `too_long`, `not_base64`, `truncated`, `bad_tag`, `not_utf8`,
 * `missing_tag`, `bad_vat_number`, `bad_amount`, `vat_over_total`,
 * `bad_timestamp`.
 */
function decodeTLV(text) {
  const raw = String(text == null ? '' : text).trim();
  if (!raw) return { ok: false, reason: 'empty' };
  if (raw.length > MAX_TEXT) return { ok: false, reason: 'too_long' };
  const bytes = unbase64(raw);
  if (!bytes || !bytes.length) return { ok: false, reason: 'not_base64' };
  const fields = {};
  let phase2 = false;
  let i = 0;
  while (i < bytes.length) {
    if (i + 2 > bytes.length) return { ok: false, reason: 'truncated' };
    const tag = bytes[i];
    let len = bytes[i + 1];
    let at = i + 2;
    if (len === 0x81) {
      if (at + 1 > bytes.length) return { ok: false, reason: 'truncated' };
      len = bytes[at]; at += 1;
    } else if (len === 0x82) {
      if (at + 2 > bytes.length) return { ok: false, reason: 'truncated' };
      len = (bytes[at] << 8) | bytes[at + 1]; at += 2;
    } else if (len > 0x82) {
      // A longer length form would describe a value no receipt has.
      return { ok: false, reason: 'too_long' };
    }
    if (at + len > bytes.length) return { ok: false, reason: 'truncated' };
    if (tag >= 1 && tag <= 5) {
      // The same tag twice is two answers to one question.
      if (fields[tag] !== undefined) return { ok: false, reason: 'bad_tag' };
      const str = fromUtf8(bytes.slice(at, at + len));
      if (str === null) return { ok: false, reason: 'not_utf8' };
      fields[tag] = str;
    } else if (tag >= 6 && tag <= 9) {
      phase2 = true;   // hash, signature, public key, stamp: present, not ours to check
    } else {
      return { ok: false, reason: 'bad_tag' };
    }
    i = at + len;
  }
  for (let t = 1; t <= 5; t++) if (fields[t] === undefined) return { ok: false, reason: 'missing_tag' };
  const sellerName = fields[1].trim();
  const vatNumber = fields[2].trim();
  if (!sellerName) return { ok: false, reason: 'missing_tag' };
  // A Saudi VAT registration number: fifteen digits, the first and last a 3.
  if (!/^3\d{13}3$/.test(vatNumber)) return { ok: false, reason: 'bad_vat_number' };
  const total = amountOf(fields[4]);
  const vatAmount = amountOf(fields[5]);
  if (total === null || vatAmount === null) return { ok: false, reason: 'bad_amount' };
  if (vatAmount > total) return { ok: false, reason: 'vat_over_total' };
  const timestamp = fields[3].trim();
  if (!/^\d{4}-\d{2}-\d{2}/.test(timestamp)) return { ok: false, reason: 'bad_timestamp' };
  return { ok: true, receipt: { sellerName, vatNumber, timestamp, total, vatAmount, phase2 } };
}

const pad2 = (n) => String(n).padStart(2, '0');

/**
 * The receipt's day, on the shop's own (local) calendar: a stamp with a time
 * is read as the moment it names; a bare day stays that day.
 */
function receiptDay(timestamp) {
  const s = String(timestamp || '').trim();
  const day = /^(\d{4}-\d{2}-\d{2})/.exec(s);
  if (!day) return '';
  if (/[T ]\d{2}:\d{2}/.test(s) && /(Z|[+-]\d{2}:?\d{2})$/.test(s)) {
    const d = new Date(s);
    if (!isNaN(d.getTime())) return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
  }
  return day[1];
}

/** One receipt's identity in the book: the seller, the moment, the total. */
function receiptRef(receipt) {
  return 'zatca:' + receipt.vatNumber + ':' + receipt.timestamp + ':' + receipt.total;
}

/** A name compared without case, spacing or punctuation. */
function nameKey(s) {
  return String(s || '').toLowerCase().normalize('NFKC').replace(/[\s.,'"()\-_/&]+/g, '');
}

/**
 * The expense a scanned receipt proposes — for a PERSON to review, never
 * filed on its own.
 *
 * `ctx`: `{ suppliers, expenses, reclaimsTax }`. Returns
 * `{ draft: { amount, vatAmount, date, note, receiptRef }, supplier, duplicateOf }`:
 *  - `amount` is what was paid, VAT included — the expense records the money
 *    that left — and `vatAmount` is the part of it a registered shop reclaims
 *    (lib/expense-book.js). A shop that is not registered reclaims nothing,
 *    so its draft carries 0 and the whole total is its cost.
 *  - `supplier` is the matched supplier `{ id, name }` — by VAT number when a
 *    supplier record carries one (`vat`), then by name — or null.
 *  - `duplicateOf` is the id of an expense already filed from this receipt.
 *  - No category: a receipt does not say what the money was for.
 */
function receiptToExpenseDraft(receipt, ctx) {
  const c = ctx || {};
  const suppliers = Array.isArray(c.suppliers) ? c.suppliers : [];
  const byVat = suppliers.find((s) => s && String(s.vat || s.vatNumber || '').trim() === receipt.vatNumber);
  const key = nameKey(receipt.sellerName);
  const byName = key ? suppliers.find((s) => s && nameKey(s.name) === key) : null;
  const hit = byVat || byName || null;
  const supplier = hit ? { id: String(hit.id || ''), name: String(hit.name || '') } : null;
  const ref = receiptRef(receipt);
  const dup = (Array.isArray(c.expenses) ? c.expenses : []).find((e) => e && e.receiptRef === ref);
  const who = supplier ? supplier.name : receipt.sellerName;
  return {
    draft: {
      amount: receipt.total,
      vatAmount: c.reclaimsTax === false ? 0 : receipt.vatAmount,
      date: receiptDay(receipt.timestamp),
      note: who + ' · VAT ' + receipt.vatNumber,
      receiptRef: ref,
    },
    supplier,
    duplicateOf: dup ? String(dup.id || '') : null,
  };
}

  const api = { readiness, buildTLV, issueTimestamp, utf8, base64,
                decodeTLV, receiptToExpenseDraft, receiptRef, receiptDay };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytZatcaQr = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
