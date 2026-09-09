'use strict';
/**
 * Reading a Klipper printer's answer.
 *
 * Moonraker's `/printer/objects/query` returns the firmware's own object tree,
 * and turning that into "what is this machine doing" carries four corrections
 * that were each found on a real printer:
 *
 * - **Layers before bytes.** `virtual_sdcard.progress` is a byte position, and
 *   bytes are not work. See `moonrakerProgress` in printer-status.js for the
 *   measurement that settled it — a 31 MB relief read 0.7% done when it was
 *   19.4% done, and the ETA extrapolated from that said 176 hours on a
 *   five-hour print.
 * - **The live toolhead, not toolhead zero.** On a toolchanger `extruder` is
 *   head 0 and nothing else; Klipper names the rest `extruder1`, `extruder2`…
 *   and publishes the live one as `toolhead.extruder`. A U1 printing on its
 *   third head showed a nozzle sitting at room temperature.
 * - **`print_duration`, not `total_duration`.** The latter includes heating and
 *   idling either side of the job.
 * - **The ETA goes through `etaSeconds`**, which refuses to extrapolate from
 *   noise rather than returning an absurd number.
 *
 * All four live here, once, because the Mac app polls the same printer as the
 * Electron app and a second reading of the same JSON would be a second opinion
 * about whether a shop's print is nearly done.
 */
(function (global) {

  function status() {
    if (typeof require === 'function') {
      try { return require('./printer-status.js'); } catch (e) { /* renderer / JSC */ }
    }
    return global.KhaytPrinterStatus || null;
  }

  /**
   * The objects worth asking for, as the query string Moonraker expects.
   *
   * One request rather than five: Moonraker takes them together and a printer
   * on a shop's wifi is the slowest link in this app.
   */
  const QUERY = 'print_stats&virtual_sdcard&extruder&heater_bed&toolhead';

  function objects(data) {
    return (data && data.result && data.result.status) || {};
  }

  /**
   * Which extruder is printing, when it is not toolhead zero.
   *
   * Null for a single-head machine, and null for `"extruder"` itself — both mean
   * "the reading already in front of you is the right one", and only the
   * machines that need it pay for a second request.
   */
  function activeExtruder(data) {
    const name = objects(data).toolhead && objects(data).toolhead.extruder;
    if (typeof name !== 'string' || !name || name === 'extruder') return null;
    return name;
  }

  /**
   * What the machine is doing.
   *
   * @param {object} data  the reply to `/printer/objects/query?` + QUERY
   * @param {object} [hot] the reply to a second query for `activeExtruder(data)`,
   *                       when there was one. A failed second request is passed
   *                       as null: toolhead zero's reading is a worse answer
   *                       than the live head's and a far better one than none.
   * @param {string} [hotName] the name that second query asked for.
   */
  function readStatus(data, hot, hotName) {
    const S = status();
    const o = objects(data);
    const ps = o.print_stats || {};
    const vs = o.virtual_sdcard || {};

    // Through `S.reading` so a genuine 0 survives — see the note there.
    let nozzle = S ? S.reading(o.extruder && o.extruder.temperature)
                   : (o.extruder && o.extruder.temperature);
    if (hot && hotName) {
      const live = objects(hot)[hotName];
      const t = live && live.temperature;
      if (Number.isFinite(Number(t))) nozzle = Number(t);
    }

    const prog = S ? S.moonrakerProgress(ps, vs) : { percent: 0, source: 'bytes' };
    return {
      state: ps.state || 'Unknown',
      progress: prog.percent,
      progressSource: prog.source,
      filename: ps.filename || '',
      timeRemaining: S ? S.etaSeconds(ps.print_duration, prog.percent / 100) : null,
      tempNozzle: S ? S.reading(nozzle) : (Number.isFinite(Number(nozzle)) ? Number(nozzle) : null),
      tempBed: S ? S.reading(o.heater_bed && o.heater_bed.temperature)
                 : ((o.heater_bed && o.heater_bed.temperature) ?? null),
      type: 'moonraker',
    };
  }

  const api = { QUERY, activeExtruder, readStatus };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytMoonraker = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
