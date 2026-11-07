'use strict';
/**
 * What a Sentry event may carry off the device.
 *
 * Crash reports to Sentry are opt-in (main.js beforeSend), and /privacy says
 * personal data — e-mails, phone numbers, IBANs, long digit runs — and
 * secrets are removed before anything is stored. Khayt Cloud's own crash
 * reports were scrubbed (lib/telemetry-scrub.js); what went to Sentry was not.
 * This runs the same scrubber over every free-text field of a Sentry event:
 * the message, each exception's value and frames, breadcrumbs, the request
 * URL, and the `extra` the renderer forwards (its URL and line).
 *
 * Mutates and returns the event. Fails CLOSED: if scrubbing throws, the
 * caller drops the event (returns null), never sends it raw.
 */
const Scrub = require('../telemetry-scrub.js');

const text = (v, cap) => (typeof v === 'string' ? Scrub.scrubText(v, cap || 2000) : v);

function scrubFrame(f) {
  if (!f || typeof f !== 'object') return;
  for (const k of ['filename', 'abs_path', 'module', 'function', 'context_line']) {
    if (typeof f[k] === 'string') f[k] = text(f[k], 500);
  }
  delete f.vars;
  delete f.pre_context;
  delete f.post_context;
}

function scrubSentryEvent(event) {
  if (!event || typeof event !== 'object') return event;
  if (typeof event.message === 'string') event.message = text(event.message);
  else if (event.message && typeof event.message === 'object') {
    event.message.message = text(event.message.message);
    event.message.formatted = text(event.message.formatted);
    delete event.message.params;
  }
  const values = event.exception && Array.isArray(event.exception.values) ? event.exception.values : [];
  for (const ex of values) {
    if (!ex) continue;
    ex.value = text(ex.value);
    if (ex.stacktrace && Array.isArray(ex.stacktrace.frames)) ex.stacktrace.frames.forEach(scrubFrame);
  }
  const crumbs = Array.isArray(event.breadcrumbs) ? event.breadcrumbs
    : (event.breadcrumbs && Array.isArray(event.breadcrumbs.values) ? event.breadcrumbs.values : []);
  for (const b of crumbs) {
    if (!b) continue;
    b.message = text(b.message);
    // A breadcrumb's data is whatever the instrumentation caught (a fetch URL
    // with its query, a console argument): keep only scrubbed strings.
    if (b.data && typeof b.data === 'object') {
      const out = {};
      for (const [k, v] of Object.entries(b.data)) {
        if (Scrub.isSecretKey(k)) continue;
        if (typeof v === 'string') out[k] = text(v, 500);
        else if (typeof v === 'number' || typeof v === 'boolean') out[k] = v;
      }
      b.data = out;
    }
  }
  if (event.request && typeof event.request === 'object') {
    if (typeof event.request.url === 'string') event.request.url = text(event.request.url.split('?')[0], 500);
    delete event.request.query_string;
    delete event.request.cookies;
    delete event.request.headers;
    delete event.request.data;
  }
  if (event.extra && typeof event.extra === 'object') {
    for (const [k, v] of Object.entries(event.extra)) {
      if (Scrub.isSecretKey(k)) delete event.extra[k];
      else if (typeof v === 'string') event.extra[k] = text(v, 500);
    }
  }
  // No user, no device name: the SDK should not add them (sendDefaultPii is
  // off), and nothing here needs them.
  delete event.user;
  if (event.server_name) delete event.server_name;
  return event;
}

module.exports = { scrubSentryEvent };
