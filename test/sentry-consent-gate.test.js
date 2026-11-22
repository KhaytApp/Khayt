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
  // Since P8 the decision is lib/outbound.js's (the opt-in AND the "make no
  // internet calls" switch): an unread book is settings-unknown, which is no,
  // and anything that throws is no.
  assert.match(fn, /let crash = false, usage = false;/, 'no consent until the gate says yes');
  assert.match(fn, /crash = outboundGate\.check\('crash-reports'\)\.allowed;/);
  assert.match(fn, /\} catch \(_\) \{ crash = false; usage = false; \}/, 'a throw is no-consent');
  const O = require('../lib/outbound.js');
  assert.equal(O.allowed(null, 'crash-reports').allowed, false, 'the book not read yet');
  assert.equal(O.allowed({ telemetry: {} }, 'crash-reports').allowed, false, 'not opted in');
  assert.equal(O.allowed({ telemetry: { crashOptIn: 'yes' } }, 'crash-reports').allowed, false, 'strictly true');
});

test('crash reporting still defaults to off', () => {
  const state = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app-state.js'), 'utf8');
  assert.match(state, /crashOptIn:\s*false/, 'crash reporting must default to off');
  assert.match(state, /usageOptIn:\s*false/, 'usage reporting must default to off');
});
