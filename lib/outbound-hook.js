'use strict';
/**
 * The one place a library module asks the "make no internet calls" gate
 * (P8 PR 4). Main sets the gate once (lib/main/outbound-fetch.js gateFor);
 * a module that makes an internet call does `await ask('<purpose>', url)`
 * before its fetch, which throws OutboundBlocked when refused.
 *
 * Unset (unit tests, a script outside main) means no gate: today's
 * behaviour. Node only: none of the modules that use it is in the Mac's
 * JavaScriptCore bundle (the Mac asks its own Outbound in Swift).
 */
let gate = null;

function setOutboundGate(fn) { gate = typeof fn === 'function' ? fn : null; }

/** Ask before a call. `url` lets a call to the shop's own network count as `lan`. */
async function ask(purpose, url) {
  if (gate) return gate(purpose, url);
  // Inside Electron's main process there must be a gate (review of #2628):
  // missing, it fails CLOSED there. Tests and scripts outside Electron run as
  // before.
  if (typeof process !== 'undefined' && process.type === 'browser') {
    const e = new Error(`outbound blocked: ${purpose} (no gate)`); e.code = 'outbound.blocked'; e.purpose = purpose; e.reason = 'settings-unknown';
    throw e;
  }
  return undefined;
}

module.exports = { setOutboundGate, ask };
