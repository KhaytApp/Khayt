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

  const api = { readiness, buildTLV, issueTimestamp, utf8, base64 };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytZatcaQr = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
