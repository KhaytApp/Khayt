/**
 * Uncaught errors and dead promises — installed BEFORE anything else loads.
 *
 * This used to live at the bottom of app-boot.js, which is the 148th of 149
 * scripts. Everything that failed while the app was still assembling itself
 * therefore failed with no handler installed at all: not reported, not shown,
 * and in the one window where the app has no other way to say anything. Boot is
 * where a missing module or a bad migration surfaces, so it is exactly the
 * wrong stretch to leave unwatched.
 *
 * Two jobs, in order of who needs it more:
 *
 *   1. Report to the main process, where Sentry runs. The renderer is
 *      non-bundled under a strict CSP and cannot load the SDK itself. No-op
 *      unless a build configures Sentry — which is most builds, and is why job
 *      2 exists.
 *
 *   2. TELL THE SHOP. An unhandled rejection means a handler died mid-flight and
 *      the person looking at the screen is the one holding the result. Reporting
 *      to a Sentry that is switched off left the cloud panel sitting on
 *      "Connecting…" forever with nothing on screen, nothing in a log the shop
 *      could reach, and no way to describe it beyond "it's stuck". A release
 *      shipped on top of that.
 */
if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') (function () {
  const report = (message, stack, extra) => {
    try { window.hubAPI?.reportError?.(Object.assign({ message, stack }, extra)); } catch (e) { /* ignore */ }
  };
  window.addEventListener('error', (e) => {
    report((e.error && e.error.message) || e.message || 'error', e.error && e.error.stack, { url: e.filename, line: e.lineno });
  });

  // Deduped by message: a loop that rejects would otherwise bury the app in
  // toasts. Only for things that look like thrown errors — a bare
  // `reject('cancelled')` is control flow, not a fault.
  //
  // Duck-typed rather than `instanceof Error` on purpose. An Error thrown in
  // another realm — a preload bridge, a worker, an automation context — is not
  // an instance of THIS realm's Error, so instanceof silently drops exactly the
  // cross-boundary failures this exists to surface. It dropped them in test.
  const shown = new Set();
  window.addEventListener('unhandledrejection', (e) => {
    const r = e.reason;
    const message = (r && r.message) || String(r) || 'unhandledrejection';
    report(message, r && r.stack);
    const looksLikeError = !!r && typeof r === 'object' && typeof r.message === 'string' && !!r.message;
    if (!looksLikeError || shown.has(message)) return;
    shown.add(message);
    try {
      // Both are set up by later scripts; before then there is nothing to say it
      // with, and the report above has already gone out.
      const say = (typeof t === 'function' && t('common.unexpected_error'))
        || 'Something went wrong and this action stopped partway';
      if (typeof toast === 'function') toast('\u26a0 ' + say + ' \u2014 ' + message, 'error', 9000);
    } catch (_) { /* nothing to show it with yet */ }
  });

  // Lets a test wait for the handlers rather than race them. They are installed
  // first precisely so nothing else has to know about this.
  window.__khaytErrorHandlersInstalled = true;
})();
