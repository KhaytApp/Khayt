'use strict';
/**
 * A printer's smart plug on Windows/Linux — the Mac's SmartPlug.swift, over the
 * shared rule in lib/smart-plug.js (which builds the request, reads the answer
 * and owns the one rule that matters: power is never cut while the printer is
 * printing, paused, not answering, or hot).
 *
 * THE RULE IS CHECKED HERE, not only in the window. A Turn off that arrives
 * from the window is refused unless the poller's own last reading of that
 * printer says it is safe — the window's copy of the reading could be stale.
 *
 * THE ADDRESS IS THE LAN'S. The plug's host is resolved and pinned the way a
 * printer's is (lib/main/printer-target.js): a token or password goes to the
 * private address the name resolved to, never to a public one.
 *
 * AUTO-OFF: a machine whose plug says "turn off after a print, once cooled" is
 * switched off by this process — once per finished print — when the poller
 * has seen it leave printing at least `delayMin` minutes ago and the rule says
 * it is safe now. Nothing here turns anything ON by itself.
 */
const Plug = require('../smart-plug.js');

const TICK_MS = 60 * 1000;
const BUSY = /print|paus|busy|running|prepare|heating|cancelling/;

function registerSmartPlug({ ipcMain, fill, resolveTarget, statusCache, readMachines, notify, log = console }) {
  async function send(machine, action) {
    const m = fill(machine);
    const req = Plug.request(m, action);
    if (!req) return { ok: false, reason: 'splug.unreachable' };
    let url;
    try { url = new URL(req.url); } catch (_) { return { ok: false, reason: 'splug.unreachable' }; }
    const target = await resolveTarget(url.hostname);
    if (!target.ok) return { ok: false, error: target.error };
    // Pinned for http; https keeps its name for the certificate, after the
    // name was checked to resolve onto the LAN.
    if (url.protocol === 'http:') url.hostname = target.urlHost.replace(/^\[|\]$/g, '');
    try {
      const res = await fetch(url.toString(), {
        method: req.method, headers: req.headers, body: req.body || undefined,
        redirect: 'manual', signal: AbortSignal.timeout(8000),
      });
      if (res.status >= 300 && res.status < 400) return { ok: false, error: 'The plug redirected; check its address' };
      if (!res.ok) return { ok: false, error: `The plug answered HTTP ${res.status}` };
      let json = null;
      try { json = await res.json(); } catch (_) { json = null; }
      return { ok: true, ...Plug.readAnswer(m, json) };
    } catch (e) {
      return { ok: false, reason: 'splug.unreachable', error: String((e && e.message) || e) };
    }
  }

  ipcMain.handle('hub:smart-plug', async (_e, { machine, action } = {}) => {
    if (!machine || !['status', 'on', 'off'].includes(action)) return { ok: false, reason: 'splug.unreachable' };
    if (action === 'off') {
      const safe = Plug.canTurnOff(statusCache()[machine.id] || null);
      if (!safe.ok) return { ok: false, reason: 'splug.' + String(safe.reason).replace(/^plug\./, '') };
    }
    return send(machine, action);
  });

  // ── auto-off ────────────────────────────────────────────────────────────
  const finishedAt = {};   // machineId → ms the poller saw it leave printing
  const wasBusy = {};
  const doneFor = {};      // machineId → the finishedAt already acted on
  async function tick() {
    const now = Date.now();
    const cache = statusCache() || {};
    for (const m of readMachines() || []) {
      if (!m || !m.id || !m.smartPlug) continue;
      const live = cache[m.id] || null;
      const busy = !!(live && !live.error && BUSY.test(String(live.state || '').toLowerCase()));
      if (busy) { wasBusy[m.id] = true; continue; }
      if (wasBusy[m.id] && live && !live.error) { finishedAt[m.id] = now; wasBusy[m.id] = false; }
      const f = finishedAt[m.id];
      if (!Number.isFinite(f) || doneFor[m.id] === f) continue;
      if (!Plug.autoOffDue(m, live, f, now)) continue;
      doneFor[m.id] = f;
      const r = await send(m, 'off').catch(() => ({ ok: false }));
      if (r.ok && typeof notify === 'function') notify(m);
      else if (!r.ok) log.warn && log.warn('smart plug auto-off failed for a machine');
    }
  }
  const timer = setInterval(() => { tick().catch(() => {}); }, TICK_MS);
  if (timer.unref) timer.unref();
  return { send, tick, stop() { clearInterval(timer); } };
}

module.exports = { registerSmartPlug };
