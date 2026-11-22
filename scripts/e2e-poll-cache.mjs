#!/usr/bin/env node
/**
 * Prove the completion history is reachable FROM THE RENDERER.
 *
 * lib/printer-poll-cache.js is merged in the main process, and until now was
 * never loaded as a renderer script — so `KhaytPollCache` would have been
 * undefined and promptActuals would have silently fallen back to "whatever
 * finished last", forever, with no error. That is #578's bug exactly: a global
 * read in one place that nothing loaded, working everywhere it was tested.
 *
 * Unit tests cannot catch it, because in Node the require() always succeeds.
 * This asserts the renderer sees it, and that it picks by filename there.
 */
import { dismissWizard, launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
let electronApp;

try {
  let window;
  ({ electronApp, window } = await launchApp(userData));
  await dismissWizard(window);

  const r = await window.evaluate(() => {
    if (typeof KhaytPollCache === 'undefined') return { loaded: false };
    const entry = {
      completions: [
        { at: 4000, filename: 'newest.gcode', actuals: { filamentGrams: 222, durationS: 7200 } },
        { at: 2000, filename: 'wanted.gcode', actuals: { filamentGrams: 111, durationS: 3600 } },
      ],
    };
    entry.lastCompleted = entry.completions[0];
    return {
      loaded: true,
      exports: Object.keys(KhaytPollCache).sort(),
      byName: KhaytPollCache.findCompletion(entry, { filename: 'wanted.gcode' })?.actuals?.filamentGrams,
      fallback: KhaytPollCache.findCompletion(entry, {})?.actuals?.filamentGrams,
      // The bug this whole change exists to stop.
      pauseIsNotCompletion: KhaytPollCache.isInJob('paused'),
    };
  });

  if (!r.loaded) throw new Error('KhaytPollCache is not defined in the renderer — the script tag is missing, and findCompletion would never run');
  if (!r.exports.includes('findCompletion')) throw new Error(`findCompletion not exported to the renderer: ${r.exports.join(',')}`);
  if (r.byName !== 111) throw new Error(`findCompletion did not pick the named job in the renderer (got ${r.byName}, wanted 111)`);
  if (r.fallback !== 222) throw new Error(`fallback should be the newest (got ${r.fallback}, wanted 222)`);
  if (r.pauseIsNotCompletion !== true) throw new Error('isInJob("paused") is false in the renderer — a paused job would be recorded as finished');

  console.log(`e2e-poll-cache: ok (renderer sees ${r.exports.length} exports; picked the named job, not the newest)`);
} finally {
  if (electronApp) await electronApp.close();
}
