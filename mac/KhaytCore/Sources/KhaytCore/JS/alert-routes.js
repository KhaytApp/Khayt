'use strict';
/**
 * Where a printer alert goes: Telegram, ntfy, both or neither.
 *
 * `lib/printer-alerts.js` decides WHAT has gone wrong. This decides WHO is told,
 * from the shop's own switches, so every app sending an alert asks one rule.
 *
 * ── WHY IT EXISTS ─────────────────────────────────────────────────────────
 *
 * The Mac raised printer alerts as notifications on the Mac and nowhere else.
 * Its Telegram settings drew three switches — printer error, offline, stalled —
 * that saved and were never read, so a shop that set Telegram up on the Mac was
 * never told about a printer by it. And the Mac asked for alerts with a fixed
 * set that had no filament RUNOUT in it, so a spool running out mid-print
 * raised nothing at all.
 *
 * ntfy (ntfy.sh) is a second channel: a push to a phone with no account and no
 * bot to set up — pick a topic, subscribe to it in the ntfy app. Self-hosted
 * servers and protected topics take an access token.
 *
 * Pure: no network, no clock.
 */
(function (global) {
  const TYPES = ['error', 'offline', 'stall', 'runout'];
  /** What each channel sends when the shop has not said: a fault, a silent
   *  printer and an empty spool interrupt; "stuck at 47%" might be a long layer. */
  const DEFAULT_ON = { error: true, offline: true, stall: false, runout: true };
  const DEFAULT_SERVER = 'https://ntfy.sh';

  const str = (v) => (v == null ? '' : String(v)).trim();

  /** Does the shop's Telegram want this alert? The same defaults the settings
   *  screens draw (`notifyPrinterError ?? true`, stall off). */
  function telegramWants(type, settings) {
    const tg = (settings && settings.telegram) || {};
    if (!str(tg.botToken) || !str(tg.chatId)) return false;
    switch (type) {
      case 'error': return tg.notifyPrinterError !== false;
      case 'offline': return tg.notifyPrinterOffline !== false;
      case 'stall': return !!tg.notifyPrinterStall;
      case 'runout': return tg.notifyPrinterRunout !== false;
      default: return false;
    }
  }

  /** ntfy topics are letters, digits, `_` and `-`, up to 64 — ntfy's own rule. */
  function validTopic(topic) { return /^[A-Za-z0-9_-]{1,64}$/.test(str(topic)); }

  /** An http(s) server, without a trailing slash; ntfy.sh when blank. Null when
   *  what was typed is not one. */
  function server(settings) {
    const n = (settings && settings.ntfy) || {};
    const s = str(n.server) || DEFAULT_SERVER;
    if (!/^https?:\/\/[^\s/?#]+(\/[^\s?#]*)?$/i.test(s)) return null;
    return s.replace(/\/+$/, '');
  }

  function ntfyWants(type, settings) {
    const n = (settings && settings.ntfy) || {};
    if (!n.enabled || !validTopic(n.topic) || !server(settings)) return false;
    if (TYPES.indexOf(type) === -1) return false;
    const events = n.events || {};
    return events[type] === undefined ? DEFAULT_ON[type] : !!events[type];
  }

  /** The channels this alert goes to. */
  function routes(type, settings) {
    return { telegram: telegramWants(type, settings), ntfy: ntfyWants(type, settings) };
  }

  /**
   * Which alert TYPES to compute at all, as `printer-alerts`' `enable` takes
   * them: what the local notification always wants (everything but a stall),
   * plus whatever a channel has asked for — so a stall a shop asked Telegram
   * for is computed even though the Mac's own notification leaves it out.
   */
  function enable(settings) {
    const out = {};
    for (const t of TYPES) out[t] = DEFAULT_ON[t] || telegramWants(t, settings) || ntfyWants(t, settings);
    return out;
  }

  const PRIORITY = { error: 'high', runout: 'high', offline: 'default', stall: 'low' };
  const TAGS = { error: 'rotating_light', runout: 'warning', offline: 'electric_plug', stall: 'hourglass' };

  /**
   * The ntfy request for one alert: `{ url, headers, body }` — a POST of the
   * message as plain text to `<server>/<topic>`, with the title, a priority and
   * an emoji tag in ntfy's headers. Null when ntfy is not set up. The access
   * token, if any, is the caller's to add: it is sealed in the book.
   */
  function ntfyRequest(alert, settings) {
    const a = alert || {};
    const base = server(settings);
    const topic = str(((settings && settings.ntfy) || {}).topic);
    if (!base || !validTopic(topic)) return null;
    // Header values must be one line; a filename with a newline in it must not
    // become a second header.
    const oneLine = (s, n) => str(s).replace(/[\r\n\t]+/g, ' ').slice(0, n);
    return {
      url: `${base}/${encodeURIComponent(topic)}`,
      headers: {
        Title: oneLine(a.title, 200),
        Priority: PRIORITY[a.type] || 'default',
        Tags: TAGS[a.type] || 'bell',
      },
      body: oneLine(a.body, 1000) || oneLine(a.title, 200),
    };
  }

  const api = { TYPES, DEFAULT_ON, DEFAULT_SERVER, telegramWants, ntfyWants, routes, enable,
                validTopic, server, ntfyRequest };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytAlertRoutes = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
