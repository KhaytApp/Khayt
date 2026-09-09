/**
 * Whether a Klipper machine has run out of filament, and which head did.
 *
 * ── WHY THIS IS NOT A HARDCODED OBJECT NAME ───────────────────────────────
 *
 * The obvious implementation, and the one another Moonraker client on GitHub
 * ships, is to query `filament_switch_sensor filament_sensor` and read
 * `filament_detected`. On the Snapmaker U1 on this bench that object DOES NOT
 * EXIST, and the query returns nothing at all — no error, no sensor, silence.
 * What the U1 actually publishes, from its own `/printer/objects/list`:
 *
 *     filament_motion_sensor e0_filament   { filament_detected, enabled }
 *     filament_motion_sensor e1_filament   …one per head, four of them
 *     filament_entangle_detect e0_filament { detect_factor: 1.0 }
 *     filament_detect                      { info: [ …RFID tray data… ] }
 *
 * Three lessons, each of which a hardcoded name gets wrong:
 *
 * 1. **Motion sensors count too.** Klipper has `filament_switch_sensor` and
 *    `filament_motion_sensor`; they publish the same two fields and mean the
 *    same thing to a shop. This printer has only the second kind.
 * 2. **`filament_entangle_detect` is not one of them.** It is Snapmaker's own,
 *    it reports a float rather than a boolean, and reading `filament_detected`
 *    off it gives `undefined` — which is not `false`, and must not become it.
 *    Nor is bare `filament_detect`, which is the RFID tray reader.
 * 3. **`enabled` is half the answer.** A sensor switched off still publishes
 *    `filament_detected`, and the value is meaningless. Ignoring `enabled` is
 *    how you tell a shop to go and load a spool that is already loaded.
 *
 * ── AND WHICH HEAD ────────────────────────────────────────────────────────
 *
 * A toolchanger has one sensor per head, and only the printing head's answer
 * is news: head 3 having no filament while the job prints happily on head 1 is
 * not a runout, it is an empty slot. Klipper names the live head in
 * `toolhead.extruder`, and this printer pairs `extruderN` with `eN_filament`
 * (`extruder`, with no digit, is head zero). Where that pairing does not hold —
 * any other vendor's naming — the answer falls back to "any enabled sensor
 * that says no", which is the safe direction: better a shop checks a machine
 * that was fine than misses one that stopped.
 *
 * ── THE THREE-WAY ANSWER ──────────────────────────────────────────────────
 *
 * `true` / `false` / **null**, and the null is load-bearing. A machine with no
 * sensor is not a machine with filament; it is a machine that cannot tell you.
 * Reporting `false` for it would put "filament fine" on a screen that has no
 * idea, which is the failure this codebase keeps finding in other shapes.
 */
(function (global) {

  /** The two Klipper sections that are runout sensors, and nothing else. */
  const KINDS = ['filament_switch_sensor', 'filament_motion_sensor'];

  /**
   * The sensor object names in a `/printer/objects/list` reply.
   *
   * @param {object} listReply the parsed body of `/printer/objects/list`
   * @returns {string[]} full object names, e.g. `filament_motion_sensor e1_filament`
   */
  function sensorNames(listReply) {
    const all = listReply && listReply.result && listReply.result.objects;
    if (!Array.isArray(all)) return [];
    return all.filter((name) => typeof name === 'string'
      && KINDS.some((k) => name.startsWith(k + ' ')));
  }

  /** Those names as a query string fragment, URL-encoded (the space matters). */
  function queryFor(names) {
    return (names || []).map((n) => encodeURIComponent(n)).join('&');
  }

  /**
   * The bare sensor name without its section — `e1_filament`.
   */
  function shortName(objectName) {
    const i = String(objectName).indexOf(' ');
    return i < 0 ? String(objectName) : String(objectName).slice(i + 1);
  }

  /**
   * The sensor belonging to the live head, or null when the pairing does not
   * hold. `extruder` → `e0_…`, `extruder2` → `e2_…`.
   */
  function sensorForHead(names, activeExtruder) {
    const head = String(activeExtruder || 'extruder');
    const m = /^extruder(\d*)$/.exec(head);
    if (!m) return null;
    const n = m[1] === '' ? '0' : m[1];
    const want = 'e' + n + '_';
    return (names || []).find((full) => shortName(full).startsWith(want)) || null;
  }

  /**
   * Has this machine run out?
   *
   * @param {object} statusObjects the `result.status` of an objects query
   * @param {string[]} names       the sensor object names being watched
   * @param {string} [activeExtruder] `toolhead.extruder`, when known
   * @returns {{out: boolean|null, sensor: string|null, watched: number}}
   *          `out` is null when nothing can answer — no sensors, or every one
   *          of them switched off.
   */
  function runout(statusObjects, names, activeExtruder) {
    const status = statusObjects || {};
    const all = (names || []).filter((n) => status[n] && typeof status[n] === 'object');
    // A sensor that is off publishes a reading that means nothing.
    const live = all.filter((n) => status[n].enabled !== false
      && typeof status[n].filament_detected === 'boolean');
    if (!live.length) return { out: null, sensor: null, watched: 0 };

    // The printing head's sensor is the only one whose answer is news.
    const mine = sensorForHead(live, activeExtruder);
    if (mine) {
      return { out: status[mine].filament_detected === false, sensor: mine, watched: live.length };
    }
    const empty = live.find((n) => status[n].filament_detected === false);
    return { out: !!empty, sensor: empty || null, watched: live.length };
  }

  const api = { KINDS, sensorNames, queryFor, shortName, sensorForHead, runout };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytFilamentSensors = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
