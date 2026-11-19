'use strict';
/**
 * Whether crash reporting may START, read from the store on disk before the
 * app is ready (main.js), and what Sentry may run once it has.
 *
 * Sentry was initialised on every packaged launch with consent checked only
 * in beforeSend, and its default MainProcessSession integration sends
 * release-health SESSION envelopes that never pass through beforeSend: a
 * desktop that never opted in still told sentry.io its release, environment
 * and session status (and its IP) on every launch, against "Khayt sends
 * nothing by default" and /privacy (Mac outbound audit, Nov 19). Now the SDK
 * is not initialised at all unless the shop opted in to crash reports, and
 * sessions are left out even then. Turning consent ON takes effect at the
 * next launch; turning it OFF is still honoured at once by beforeSend.
 *
 * Fails CLOSED: no store, an unreadable one, a parse error or anything but
 * `settings.telemetry.crashOptIn === true` is "no".
 */

const MAX_BYTES = 50 * 1024 * 1024;   // the store's own read limit (hub:load-store)

function crashConsentAtStartup(fs, file) {
  try {
    const st = fs.statSync(file);
    if (!st.isFile() || st.size > MAX_BYTES) return false;
    const raw = fs.readFileSync(file, 'utf8');
    // Most shops never opt in: one string search, no parse, for them. The
    // parse below is the decision; this only skips it when it cannot be yes.
    if (raw.indexOf('"crashOptIn":true') === -1 && raw.indexOf('"crashOptIn": true') === -1) return false;
    const store = JSON.parse(raw);
    const tm = store && store.settings && store.settings.telemetry;
    return !!(tm && tm.crashOptIn === true);
  } catch (_) {
    return false;
  }
}

/**
 * The default integrations without release-health sessions: their envelopes
 * bypass beforeSend. The two names @sentry/electron 7 gives them.
 */
const SESSION_INTEGRATIONS = ['MainProcessSession', 'BrowserWindowSession'];
function withoutSessions(defaults) {
  return (Array.isArray(defaults) ? defaults : []).filter((i) => !(i && SESSION_INTEGRATIONS.includes(i.name)));
}

module.exports = { crashConsentAtStartup, withoutSessions, SESSION_INTEGRATIONS, MAX_BYTES };
