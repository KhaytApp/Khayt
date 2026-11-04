'use strict';
/**
 * What a shop's Telegram bot says when a job moves.
 *
 * The message was built inline in renderer/integrations.js, so the Mac app —
 * which refuses any move that would reach outside the shop precisely because
 * it could not send one — had no way to say the same thing. A shop whose only
 * integration is a Telegram bot could not finish a job on the Mac at all.
 *
 * PURE: no DOM, no network, no clock. `fmtPrice` is passed in, because how a
 * shop writes money is the app's business and not this module's.
 *
 * The transport is NOT here. Sending is a platform's job — Electron has its
 * main process, the Mac has URLSession — and both send exactly this.
 */
(function (global) {

  /**
   * Strip control characters and truncate.
   *
   * A project name is customer-supplied text going into a message someone
   * reads on a phone: newlines and tabs let it forge a second line that looks
   * like it came from the shop.
   */
  function safe(s) {
    return String(s == null ? '' : s).replace(/[\r\n\t]/g, ' ').slice(0, 200);
  }

  /**
   * The message for a status change, or null when the shop has not asked for
   * one — no bot configured, or this move is not one it wants told about.
   *
   * `ctx`: `{ settings, fmtPrice }`.
   * Returns `{ botToken, chatId, message }`.
   */
  function forStatus(order, newStatus, ctx) {
    const c = ctx || {};
    const tg = (c.settings || {}).telegram;
    if (!tg || !tg.botToken || !tg.chatId) return null;
    const money = typeof c.fmtPrice === 'function' ? c.fmtPrice : ((n) => String(n));
    const o = order || {};
    let message = '';
    if (newStatus === 'completed' && tg.notifyOnComplete) {
      message = `✅ Order completed: ${safe(o.project || o.jobNumber || o.id)} (${money(o.price)})`;
    } else if (newStatus === 'on_hold' && tg.notifyOnHold) {
      message = `⏸ Order on hold: ${safe(o.project || o.jobNumber || o.id)}${o.holdReason ? ' — ' + safe(o.holdReason) : ''}`;
    }
    if (!message) return null;
    return { botToken: tg.botToken, chatId: tg.chatId, message };
  }

  /**
   * Whether a bot token is one Telegram could possibly accept.
   *
   * The same shape the Electron main process checks before it sends. A token
   * that cannot be valid is a mistyped setting, and finding that out here
   * rather than from a 401 is the difference between a message a shop can act
   * on and a silence.
   */
  function isBotToken(token) {
    return /^[0-9]+:[A-Za-z0-9_-]+$/.test(String(token || ''));
  }

  /**
   * A chat id, as Telegram will accept one — or null when it is not one.
   *
   * Telegram's `chat_id` is either a numeric id (negative for a group or
   * channel) or a public `@username`. Khayt used to run every value through
   * `[^0-9@-]`, which keeps the @ and THROWS THE NAME AWAY: a shop that typed
   * `@khaytshop` was sending to `@`, getting a 400 back, and being told
   * nothing. That had been true for as long as the feature existed.
   *
   * So: recognise the two shapes Telegram documents, trim, and refuse
   * anything else rather than mangle it into something that cannot work. A
   * refusal a shop can see beats a silent send to nowhere.
   *
   * A username is 5–32 characters of letters, digits and underscores, which is
   * Telegram's own rule; the leading @ is optional when typing and always
   * present in what is sent.
   */
  function chatId(value) {
    const raw = String(value == null ? '' : value).trim();
    if (!raw) return null;
    if (/^-?[0-9]+$/.test(raw)) return raw;
    const name = raw.replace(/^@/, '');
    if (/^[A-Za-z0-9_]{5,32}$/.test(name) && /[A-Za-z_]/.test(name)) return '@' + name;
    return null;
  }

  /** Whether a shop's chat id is one Telegram could deliver to. */
  function isChatId(value) {
    return chatId(value) !== null;
  }

  /** Telegram's own limit. A longer message is refused, not truncated by them. */
  const MAX_MESSAGE = 4096;

  const api = { forStatus, safe, isBotToken, chatId, isChatId, MAX_MESSAGE };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytTelegramMessage = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
