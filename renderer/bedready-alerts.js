'use strict';
/**
 * Bed Ready's printer alerts.
 *
 * app-boot.js already calls `dispatchPrinterAlerts(machineStatusCache)` after every poll —
 * it has always been called in Bed Ready too. The function lives in integrations.js, which
 * is business-only, so bedready-shim.js declared it one of its no-ops. Bed Ready polled its
 * printers, watched them go offline or throw an error, and said nothing.
 *
 * The detection is not rewritten here: lib/printer-alerts.js already diffs the previous and
 * current status caches and decides what is worth firing, including the debounce that stops
 * one flapping printer shouting every poll. What this adds is somewhere for an alert to go.
 *
 * Khayt's version fans out to Telegram and webhooks. A maker at the bench wants neither —
 * they want the app to say it, and the OS to say it when the app is behind another window.
 * So: a toast, and a desktop notification when the page is hidden.
 */
(function (global) {
  const AL = () => global.KhaytPrinterAlerts || null;

  let prevCache = {};
  let alertState = {};

  const say = (msg, kind) => { try { if (typeof toast === 'function') toast(msg, kind, 7000); } catch (_) {} };

  /** The OS notification, only when the app is not the thing being looked at. */
  function notifyOS(alert) {
    try {
      if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return;
      if (typeof document !== 'undefined' && !document.hidden) return;   // the toast is enough
      new Notification('Bed Ready', { body: alert.message, tag: 'printer-' + alert.machineId });
    } catch (_) { /* notifications are a courtesy, never a requirement */ }
  }

  /**
   * The library gates every alert on `!!settings.telegram` — it was written for Khayt, where
   * an alert exists to be SENT and having nowhere to send it means there is nothing to do.
   * Bed Ready has nowhere to send and somewhere to show, which is not the same thing: the
   * destination is the app. Declaring a (possibly empty) telegram object says "there is a
   * destination" without inventing a channel, and the per-type `!== false` preferences the
   * maker sets still decide what fires.
   */
  function alertSettings() {
    const s = (typeof settings !== 'undefined' && settings) ? settings : {};
    return Object.assign({}, s, { telegram: s.telegram || {} });
  }

  const KIND = { offline: 'error', error: 'error', done: 'success' };

  function dispatchPrinterAlerts(currCache) {
    const al = AL();
    const curr = currCache || {};
    if (!al || typeof al.computePrinterAlerts !== 'function') { prevCache = curr; return; }

    let result;
    try {
      result = al.computePrinterAlerts(prevCache, curr, alertSettings(), Date.now(), {
        alertState,
        machines: (typeof machines !== 'undefined') ? machines : undefined,
      });
    } catch (_) {
      // A failed diff must not stop the next poll from trying: advance the baseline or
      // every subsequent poll re-reports the same transition forever.
      prevCache = curr;
      return;
    }

    alertState = result.state || {};
    prevCache = curr;
    for (const alert of (result.alerts || [])) {
      say(alert.message, KIND[alert.type] || 'warning');
      notifyOS(alert);
    }
  }

  global.dispatchPrinterAlerts = dispatchPrinterAlerts;
  global.KhaytBedReadyAlerts = { dispatchPrinterAlerts, _reset: () => { prevCache = {}; alertState = {}; } };
})(typeof globalThis !== 'undefined' ? globalThis : window);
