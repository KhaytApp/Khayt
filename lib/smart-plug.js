'use strict';
/**
 * A printer's smart plug: read it, switch it, and never cut a print (KhaytSmartPlug).
 *
 * A shop that runs printers overnight wants two things from the plug they sit
 * on: turn it off once a print has finished and the hot end has cooled, and
 * turn it on again from the app in the morning. The first is the dangerous
 * one, so this module owns the one rule that must hold everywhere it is used:
 *
 *     power is never cut while the printer is printing, paused, or has not
 *     been heard from — and not until the nozzle is cool.
 *
 * "Not heard from" is refused on purpose. A printer that stopped answering may
 * be mid-print on a flaky Wi-Fi link; the plug is the one thing that would
 * actually stop it.
 *
 * Four kinds of plug, each spoken over plain HTTP on the shop's network, as
 * their makers document it:
 *
 *   shelly         Shelly Gen1        GET /relay/0            {"ison": true, "power"?}
 *                                     GET /relay/0?turn=on|off
 *   shelly-rpc     Shelly Gen2+/Plus  GET /rpc/Switch.GetStatus?id=0   {"output": true, "apower": 12.3}
 *                                     GET /rpc/Switch.Set?id=0&on=true|false
 *   tasmota        Tasmota            GET /cm?cmnd=Power      {"POWER": "ON"}
 *                                     GET /cm?cmnd=Power%20On|Off
 *   homeassistant  Home Assistant     GET  /api/states/<entity>          {"state": "on"}
 *                                     POST /api/services/switch/turn_on|off {"entity_id": …}
 *                                     Authorization: Bearer <long-lived token>
 *
 * Pure: builds requests and reads answers; the caller owns the socket and the
 * clock. Shared by the desktop and, bundled, the Mac.
 */
(function (global) {
  const KINDS = ['shelly', 'shelly-rpc', 'tasmota', 'homeassistant'];

  /** States that mean a print is on the plate, across the pollers Khayt has. */
  const BUSY = ['printing', 'paused', 'pausing', 'resuming', 'busy', 'running', 'prepare',
    'printing from sd', 'sdprinting', 'cancelling', 'heating'];

  /** Cool enough to cut power without leaving a hot end to heat-creep. */
  const COOL_C = 50;
  /** How long after a print ends before an automatic switch-off. */
  const DEFAULT_DELAY_MIN = 10;

  function text(v) { return v == null ? '' : String(v).trim(); }
  function lower(v) { return text(v).toLowerCase(); }

  /** The plug as this module reads it, or null when there is none. */
  function config(machine) {
    const p = machine && machine.smartPlug;
    if (!p || !KINDS.includes(p.type)) return null;
    const host = text(p.host).replace(/\/+$/, '');
    if (!host) return null;
    const base = /^https?:\/\//i.test(host) ? host : 'http://' + host;
    return {
      type: p.type,
      base,
      entity: text(p.entity),
      token: text(p.token),
      user: text(p.user),
      password: text(p.password),
      autoOff: p.autoOff === true,
      delayMin: Number.isFinite(+p.delayMin) && +p.delayMin >= 0 ? +p.delayMin : DEFAULT_DELAY_MIN,
    };
  }

  function tasmotaAuth(c) {
    return c.user ? '&user=' + encodeURIComponent(c.user) + '&password=' + encodeURIComponent(c.password) : '';
  }

  /**
   * The request that reads the plug, or switches it.
   *
   * @param {object} machine  a machine record carrying `smartPlug`
   * @param {'status'|'on'|'off'} action
   * @returns {{method, url, headers, body}|null}  null when the machine has no
   *          usable plug, or Home Assistant is missing its entity or token
   */
  function request(machine, action) {
    const c = config(machine);
    if (!c || !['status', 'on', 'off'].includes(action)) return null;
    const on = action === 'on';
    switch (c.type) {
      case 'shelly':
        return { method: 'GET', headers: {}, body: null,
          url: c.base + '/relay/0' + (action === 'status' ? '' : '?turn=' + (on ? 'on' : 'off')) };
      case 'shelly-rpc':
        return { method: 'GET', headers: {}, body: null,
          url: c.base + (action === 'status'
            ? '/rpc/Switch.GetStatus?id=0'
            : '/rpc/Switch.Set?id=0&on=' + (on ? 'true' : 'false')) };
      case 'tasmota':
        return { method: 'GET', headers: {}, body: null,
          url: c.base + '/cm?cmnd=' + (action === 'status' ? 'Power' : 'Power%20' + (on ? 'On' : 'Off')) + tasmotaAuth(c) };
      case 'homeassistant': {
        if (!c.entity || !c.token) return null;
        const headers = { Authorization: 'Bearer ' + c.token, 'Content-Type': 'application/json' };
        if (action === 'status') {
          return { method: 'GET', headers, body: null,
            url: c.base + '/api/states/' + encodeURIComponent(c.entity) };
        }
        const domain = c.entity.split('.')[0] || 'switch';
        return { method: 'POST', headers,
          url: c.base + '/api/services/' + domain + '/turn_' + (on ? 'on' : 'off'),
          body: JSON.stringify({ entity_id: c.entity }) };
      }
    }
    return null;
  }

  /**
   * What a plug's answer says: on, off, or unknown; and its draw in watts
   * when the plug measures it.
   */
  function readAnswer(machine, json) {
    const c = config(machine);
    const j = json || {};
    let on = null, watts = null;
    if (!c) return { on, watts };
    switch (c.type) {
      case 'shelly':
        if (typeof j.ison === 'boolean') on = j.ison;
        if (Number.isFinite(+j.power)) watts = +j.power;
        break;
      case 'shelly-rpc':
        if (typeof j.output === 'boolean') on = j.output;
        if (Number.isFinite(+j.apower)) watts = +j.apower;
        break;
      case 'tasmota': {
        const v = lower(j.POWER != null ? j.POWER : j.POWER1);
        if (v === 'on') on = true; else if (v === 'off') on = false;
        break;
      }
      case 'homeassistant': {
        // A switch-service call answers with the list of changed states.
        const s = Array.isArray(j) ? (j.find((x) => x && x.entity_id === c.entity) || {}) : j;
        const v = lower(s.state);
        if (v === 'on') on = true; else if (v === 'off') on = false;
        const w = s.attributes && (s.attributes.current_power_w ?? s.attributes.power);
        if (Number.isFinite(+w)) watts = +w;
        break;
      }
    }
    return { on, watts };
  }

  /**
   * May power be cut now? The rule this module exists for.
   *
   * @param {object|null} live  the printer's last reading (state, tempNozzle,
   *        error), as the poller keeps it; null when never heard from
   * @returns {{ok: true}|{ok: false, reason: string}}  reason is a locale key
   */
  function canTurnOff(live) {
    if (!live) return { ok: false, reason: 'plug.no_reading' };
    // A failed poll keeps the last state (printer-poll-cache): the printer may
    // be printing on a bad link, and the plug would be the thing that stops it.
    if (live.error) return { ok: false, reason: 'plug.not_answering' };
    const state = lower(live.state);
    if (!state) return { ok: false, reason: 'plug.no_reading' };
    if (BUSY.includes(state)) return { ok: false, reason: 'plug.printing' };
    const t = Number(live.tempNozzle);
    if (Number.isFinite(t) && t >= COOL_C) return { ok: false, reason: 'plug.hot' };
    return { ok: true };
  }

  /**
   * Is an automatic switch-off due?
   *
   * @param {object} machine
   * @param {object|null} live
   * @param {number|null} finishedAt  ms, when the last print was seen to end
   * @param {number} now  ms
   * @returns {boolean}
   */
  function autoOffDue(machine, live, finishedAt, now) {
    const c = config(machine);
    if (!c || !c.autoOff || !Number.isFinite(finishedAt)) return false;
    if (now - finishedAt < c.delayMin * 60000) return false;
    return canTurnOff(live).ok;
  }

  const api = { KINDS, COOL_C, DEFAULT_DELAY_MIN, config, request, readAnswer, canTurnOff, autoOffDue };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSmartPlug = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
