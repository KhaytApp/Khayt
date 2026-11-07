const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

/**
 * Crash reporting is opt-in, and it has to actually BE opt-in.
 *
 * Khayt's own telemetry queue was correctly consent-gated — e2e-telemetry-smoke
 * proves consent-off writes no queue file at all. Sentry was a second, parallel
 * path that nobody had gated: it initialised on `app.isPackaged` alone and
 * captured regardless of the checkbox, so stack traces left the device while
 * Settings promised "Khayt sends nothing by default" and the website said
 * "No telemetry".
 */

const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');

test('Sentry drops events unless crash reporting was opted into', () => {
  // Consent first, then the scrubber (lib/main/sentry-scrub.js): an event
  // with no consent is dropped before anything reads it.
  const init = main.slice(main.indexOf('beforeSend:'), main.indexOf('beforeSend:') + 300);
  assert.match(init, /beforeSend:\s*\(event\)\s*=>\s*\{\s*if \(!telemetryConsent\(\)\.crash\) return null;/,
    'no beforeSend consent gate on the Sentry init');
});

test('the renderer error bridge checks consent too', () => {
  const handler = main.slice(main.indexOf("ipcMain.handle('hub:report-error'"),
                             main.indexOf("ipcMain.handle('hub:report-error'") + 700);
  assert.match(handler, /telemetryConsent\(\)\.crash/,
    'hub:report-error forwards to Sentry without checking consent');
});

test('the gate fails closed, not open', () => {
  // telemetryConsent() coerces a missing store to {} → crash:false, so an error
  // raised before the store loads is dropped rather than sent. Pin that shape.
  const fn = main.slice(main.indexOf('function telemetryConsent'),
                        main.indexOf('function readTelemetryQueue'));
  assert.match(fn, /!!tm\.crashOptIn/, 'consent is not coerced to a strict boolean');
  assert.match(fn, /\|\| \{\}/, 'a missing store must resolve to no-consent');
});

test('crash reporting still defaults to off', () => {
  const state = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app-state.js'), 'utf8');
  assert.match(state, /crashOptIn:\s*false/, 'crash reporting must default to off');
  assert.match(state, /usageOptIn:\s*false/, 'usage reporting must default to off');
});
