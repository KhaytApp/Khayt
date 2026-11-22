/**
 * The one way the renderer calls the AI bridge.
 *
 * Every response carries a `usage` block and the app used to discard it, so a
 * shop running on its own Anthropic key had no way to tell what the AI features
 * cost them. Recording it here — rather than in each of the six call sites —
 * means a new call site is covered for free.
 *
 * This is a wrapper function and not a patch on `window.hubAPI`, because
 * contextBridge.exposeInMainWorld returns a FROZEN object: assigning over
 * `hubAPI.aiExtract` silently does nothing (verified — no throw, no effect).
 */
(function (global) {
  async function khaytAiExtract(opts) {
    const res = await global.hubAPI.aiExtract(opts);
    try {
      if (res && res.ok && res.usage && global.KhaytAiUsage && typeof settings !== 'undefined') {
        settings.aiUsage = KhaytAiUsage.record(settings.aiUsage, {
          task: (opts && opts.task) || 'quote',
          model: res.model || (opts && opts.model),
          usage: res.usage,
          now: Date.now(),
        });
        if (typeof saveAll === 'function') saveAll();
      }
    } catch (e) {
      // Accounting must never break the feature it is measuring.
      console.error('AI usage record failed:', e);
    }
    return res;
  }
  global.khaytAiExtract = khaytAiExtract;
  if (typeof module !== 'undefined' && module.exports) module.exports = { khaytAiExtract };
})(typeof globalThis !== 'undefined' ? globalThis : window);
