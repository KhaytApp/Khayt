'use strict';

/**
 * The message a shop gets when filament is running out.
 *
 * ── WHY THIS IS A MODULE ──────────────────────────────────────────────────
 *
 * It was twelve lines inside `renderer/integrations.js`, which meant the Mac
 * app offered the switch that turns it on and had nothing to send — a control
 * that cannot do the thing it names. The words and the conditions are here now
 * and both hosts ask for them; the SENDING stays with each host, the way
 * `telegram-message.js` and `order-email.js` are split.
 *
 * WHICH SPOOLS ARE LOW is not decided here. `KhaytOrderDeduction.isLowStock`
 * already answers that for the shelf, both apps already use it, and a second
 * opinion about the threshold is how one app warns and the other does not.
 *
 * PURE: no DOM, no network, no clock.
 */
(function (global) {

  /** At most this many named before the message says "and N more". */
  const NAMED = 5;

  /**
   * Strip anything that would break a Telegram message or run away with it.
   *
   * A material name is typed by the shop and pasted from a supplier's site, so
   * it holds whatever was on the clipboard — newlines included, which would
   * split one alert into several lines that each look like a separate warning.
   */
  function oneLine(value) {
    return String(value == null ? '' : value).replace(/[\r\n\t]+/g, ' ').trim().slice(0, 100);
  }

  /**
   * Would this shop be told, and what would it say?
   *
   * `ctx`: `{ settings, low }` — `low` is the rows `lib/low-stock.js` picked.
   * Returns `{ send, message, chatId, botToken }`, `send` false and the rest
   * empty when it would not.
   *
   * The conditions are exactly the ones `checkTelegramLowStock` opened with: a
   * bot, a chat, the switch on, and something actually low.
   */
  function wouldWarn(ctx) {
    const c = ctx || {};
    const tg = (c.settings || {}).telegram || {};
    const none = { send: false, message: '', chatId: '', botToken: '' };
    if (!tg.botToken || !tg.chatId || !tg.notifyOnLowStock) return none;

    const low = Array.isArray(c.low) ? c.low : [];
    if (low.length === 0) return none;

    // NAME EVERYTHING FIRST, then take five. Slicing first and dropping the
    // nameless afterwards counted them in the remainder, so a list of one
    // named spool and one blank row read "PLA and 1 more" — a shop hunting a
    // second spool that was never there.
    const named = low
      .map((row) => oneLine((row && (row.material || row.name)) || ''))
      .filter(Boolean);
    if (named.length === 0) return none;

    const names = named.slice(0, NAMED);
    const rest = named.length - names.length;
    const message = `⚠️ Low stock alert: ${names.join(', ')}`
      + (rest > 0 ? ` and ${rest} more` : '');
    return { send: true, message, chatId: String(tg.chatId), botToken: String(tg.botToken) };
  }

  const api = { NAMED, oneLine, wouldWarn };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytLowStockAlert = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
