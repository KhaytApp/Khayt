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

  function loadedColours() {
    if (typeof require === 'function') {
      try { return require('./loaded-colours.js'); } catch (e) { /* renderer / JSC */ }
    }
    return global.KhaytLoadedColours || null;
  }

  function sensors() {
    if (typeof require === 'function') {
      try { return require('./filament-sensors.js'); } catch (e) { /* renderer / JSC */ }
    }
    return global.KhaytFilamentSensors || null;
  }

  /**
   * The objects worth asking for, as the query string Moonraker expects.
   *
   * One request rather than five: Moonraker takes them together and a printer
   * on a shop's wifi is the slowest link in this app.
   */
  // `display_status` carries the slicer's own `M73 P` — the percentage the
  // machine shows on its screen, and the only progress signal here that is
  // about time. See `moonrakerProgress`: without it Khayt told a shop seven
  // hours where the printer said three.
  //
  // `print_task_config` is Snapmaker's: the U1 reports the material and colour
  // loaded in each of its four heads there, which is what "what can I print
  // now" is asked against. Any other Klipper answers it with an empty object
  // (Moonraker does not refuse a name it does not have; measured on the U1
  // with a made-up one), so asking costs a printer without it nothing.
  //
  // `gcode_move`, `webhooks` and `fan` are the richer card: speed and flow
  // factors (`speed_factor`, `extrude_factor`), the host's own word when
  // Klippy is not ready (`webhooks.state_message`), and the part-cooling fan.
  // All three are stock Klipper objects (docs/Status_Reference.md), so every
  // Klipper machine has them and none of them needs discovering.
  const QUERY = 'print_stats&virtual_sdcard&extruder&heater_bed&toolhead&display_status&print_task_config'
    + '&gcode_move&webhooks&fan';

  /**
   * A chamber, by what it is called. Klipper has no chamber object of its own:
   * a shop adds a `heater_generic` (heated) or a `temperature_sensor`
   * (measured only) and names it. The U1 calls its one `temperature_sensor
   * cavity`; Voron and Bambu-style configs say `chamber`; some say
   * `enclosure`. A sensor named anything else — `mcu_temp`, `raspberry_pi` —
   * is a board, not the air around the print, and is not offered as one.
   */
  const CHAMBER = /^(heater_generic|temperature_sensor|temperature_fan) \S*(chamber|cavity|enclosure)\S*$/i;

  /**
   * Each head's own part fan, on a toolchanger that has one per head. The U1
   * wires `fan` to head 0 (`pin: e0:PB3`) and `fan_generic eN_fan` to the same
   * pin on head N (`pin: eN:PB3`), read from its own `configfile` — so `fan`
   * on a U1 printing with head 2 is a parked head's fan.
   */
  const HEAD_FAN = /^fan_generic e(\d+)_fan$/;

  /**
   * What to watch on this machine, from its `/printer/objects/list` reply.
   *
   * Asked once per machine: Klipper's object list changes only across a
   * firmware restart. `sensors` is `filament-sensors.sensorNames`, unchanged;
   * `chamber` is the one object to read the chamber off (a heater before a
   * bare sensor, because only a heater has a target); `headFans` are the
   * per-head part fans, empty on a machine without them.
   */
  function discover(listReply) {
    const F = sensors();
    const all = (listReply && listReply.result && Array.isArray(listReply.result.objects))
      ? listReply.result.objects.filter((n) => typeof n === 'string') : [];
    const chambers = all.filter((n) => CHAMBER.test(n));
    const chamber = chambers.find((n) => n.startsWith('heater_generic ')) || chambers[0] || null;
    return {
      sensors: F ? F.sensorNames(listReply) : [],
      chamber,
      headFans: all.filter((n) => HEAD_FAN.test(n)),
    };
  }

  /** The object names a `discover` answer (or a bare sensor list) adds. */
  function extraNames(watched) {
    if (Array.isArray(watched)) return watched;
    if (!watched || typeof watched !== 'object') return [];
    return [].concat(watched.sensors || [], watched.chamber ? [watched.chamber] : [], watched.headFans || []);
  }

  /**
   * The query with this machine's filament sensors added.
   *
   * The names are DISCOVERED — see `filament-sensors.js` for why a hardcoded
   * one finds nothing on the printer this was written against — so they arrive
   * from the caller, which asks `/printer/objects/list` once per machine.
   *
   * Takes either the sensor list on its own (what the desktop has always
   * passed) or a whole `discover` answer, which adds the chamber and the
   * per-head fans.
   */
  function queryWith(watched) {
    const names = extraNames(watched);
    const extra = names.length ? names.map((n) => encodeURIComponent(n)).join('&') : '';
    return extra ? QUERY + '&' + extra : QUERY;
  }

  /** The sensor list out of either shape `queryWith` takes. */
  function sensorList(watched) {
    if (Array.isArray(watched)) return watched;
    return (watched && Array.isArray(watched.sensors)) ? watched.sensors : [];
  }

  /**
   * The chamber, from whatever the reply carries. Found by name in the reply
   * rather than handed in, so a caller that never discovered one simply has
   * none — and a heater wins over a sensor, as in `discover`.
   */
  function chamberReading(o, S) {
    const names = Object.keys(o).filter((n) => CHAMBER.test(n) && o[n] && typeof o[n] === 'object');
    const name = names.find((n) => n.startsWith('heater_generic ')) || names[0];
    if (!name) return { tempChamber: null, targetChamber: null };
    const c = o[name];
    const read = (v) => (S ? S.reading(v) : (Number.isFinite(Number(v)) ? Number(v) : null));
    return {
      tempChamber: read(c.temperature),
      // Only a heater has a target. A `temperature_sensor` has none to report,
      // and inventing 0 would draw "37 / 0 °C" — a chamber told to switch off.
      targetChamber: name.startsWith('heater_generic ') || name.startsWith('temperature_fan ')
        ? read(c.target) : null,
    };
  }

  /**
   * The part fan of the head that is printing, as a percentage.
   *
   * On a machine with per-head fans (`fan_generic eN_fan`) head N's is the
   * one; head 0, or a machine without them, is Klipper's `fan`. When the reply
   * carries per-head fans but not the live head's, the answer is null rather
   * than head 0's fan — a parked head's fan is not this print's.
   *
   * "Has per-head fans" is read off the reply, so a caller that did not ask
   * for them (the bare sensor list `queryWith` still takes) gets Klipper's
   * `fan` — on a U1, head 0's. Query what `discover` found to get it right.
   */
  function partFan(o, liveHead, S) {
    const pct = (f) => (S && f ? S.percentOfOne(f.speed) : null);
    const m = /^extruder(\d+)$/.exec(String(liveHead || ''));
    const head = m ? Number(m[1]) : 0;
    const perHead = Object.keys(o).filter((n) => HEAD_FAN.test(n));
    if (head > 0 && perHead.length) return pct(o['fan_generic e' + head + '_fan']);
    return pct(o.fan);
  }

  /**
   * The printer's own word on what is wrong, or null when nothing is.
   *
   * `webhooks.state` is Klippy's: anything but `ready` (`startup`, `shutdown`,
   * `error`) comes with a `state_message` that names the fault — "MCU 'e2'
   * shutdown: Timer too close" — and that outranks any job message. Ready, it
   * says "Printer is ready", which is not news and is not shown. Otherwise
   * `print_stats.message`, which Klipper sets when a print errors or a macro
   * says why it paused, and leaves empty the rest of the time.
   */
  function machineMessage(o) {
    const wh = o.webhooks || {};
    if (typeof wh.state === 'string' && wh.state && wh.state !== 'ready'
        && typeof wh.state_message === 'string' && wh.state_message.trim()) {
      return wh.state_message.trim();
    }
    const m = o.print_stats && o.print_stats.message;
    return typeof m === 'string' && m.trim() ? m.trim() : null;
  }

  /**
   * Where the slicer's own estimate for a file lives.
   *
   * Moonraker keeps per-file metadata that its `metadata.py` extracts from the
   * G-code the slicer wrote — `estimated_time` in seconds, alongside layer
   * count and filament used. It is STATIC for a given file, so a caller asks
   * once per filename and holds the answer for as long as that file is
   * printing; polling it every few seconds would be a request per tick for a
   * number that cannot change.
   *
   * Returns null for no filename, which is every idle printer: there is nothing
   * to ask about and the request would 404.
   */
  function metadataPath(filename) {
    const name = String(filename || '').trim();
    if (!name) return null;
    return '/server/files/metadata?filename=' + encodeURIComponent(name);
  }

  /**
   * The slicer's estimate in seconds, out of that reply.
   *
   * Null rather than zero when it is absent — a file sliced by something that
   * wrote no estimate is not a file estimated at zero seconds, and the caller
   * falls back to extrapolating.
   */
  function slicerTotalSeconds(meta) {
    const r = meta && meta.result;
    const t = Number(r && r.estimated_time);
    return Number.isFinite(t) && t > 0 ? t : null;
  }

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
   * @param {string[]|object} [sensorNames] the filament sensors to judge a
   *                       runout by — the bare list, or a whole `discover`
   *                       answer (only its `sensors` are read here; the chamber
   *                       and head fans are found in the reply by name).
   */
  function readStatus(data, hot, hotName, sensorNames, meta) {
    const S = status();
    const F = sensors();
    const o = objects(data);
    const ps = o.print_stats || {};
    const vs = o.virtual_sdcard || {};

    // Through `S.reading` so a genuine 0 survives — see the note there.
    let nozzle = S ? S.reading(o.extruder && o.extruder.temperature)
                   : (o.extruder && o.extruder.temperature);
    let nozzleTarget = S ? S.reading(o.extruder && o.extruder.target) : null;
    if (hot && hotName) {
      const live = objects(hot)[hotName];
      const t = live && live.temperature;
      if (Number.isFinite(Number(t))) nozzle = Number(t);
      // The live head's target with its temperature, never head 0's: a parked
      // head sits at target 0, and "256 / 0 °C" reads as a heater fault.
      if (S && live) nozzleTarget = S.reading(live.target);
    }
    const liveHead = (o.toolhead && o.toolhead.extruder) || null;
    const gm = o.gcode_move || {};
    const info = ps.info || {};
    const layers = S ? S.layerPair(info.current_layer, info.total_layer) : { layer: null, totalLayers: null };
    const chamber = chamberReading(o, S);

    const prog = S ? S.moonrakerProgress(ps, vs, o.display_status) : { percent: 0, source: 'bytes' };
    return {
      state: ps.state || 'Unknown',
      progress: prog.percent,
      progressSource: prog.source,
      filename: ps.filename || '',
      // The slicer's estimate first, extrapolation only when there is none.
      // See `etaWithEstimate`: this printer said twenty-two and a half hours
      // left, two percent into a file the slicer had named `4h24m`.
      timeRemaining: S ? (S.etaWithEstimate(slicerTotalSeconds(meta), ps.print_duration, prog.percent / 100)
                          ?? S.etaSeconds(ps.print_duration, prog.percent / 100)) : null,
      tempNozzle: S ? S.reading(nozzle) : (Number.isFinite(Number(nozzle)) ? Number(nozzle) : null),
      tempBed: S ? S.reading(o.heater_bed && o.heater_bed.temperature)
                 : ((o.heater_bed && o.heater_bed.temperature) ?? null),
      // true / false / null, and the null carries weight: a machine with no
      // sensor is not a machine with filament, it is one that cannot say.
      filamentOut: F ? F.runout(o, sensorList(sensorNames), liveHead).out : null,
      // ── THE RICHER CARD ────────────────────────────────────────────────
      // Every one null when the machine did not say, never 0 — see
      // `reading` and `percentOfOne` in printer-status.js.
      targetNozzle: nozzleTarget,
      targetBed: S ? S.reading(o.heater_bed && o.heater_bed.target) : null,
      tempChamber: chamber.tempChamber,
      targetChamber: chamber.targetChamber,
      layer: layers.layer,
      totalLayers: layers.totalLayers,
      fanPart: partFan(o, liveHead, S),
      speedFactor: S ? S.percentOfOne(gm.speed_factor) : null,
      flowFactor: S ? S.percentOfOne(gm.extrude_factor) : null,
      message: machineMessage(o),
      // What is loaded, head by head, when the machine says. `[]` means it
      // does not report it, not that it is empty; see loaded-colours.js.
      loaded: (() => { const L = loadedColours(); return L ? L.fromPrintTaskConfig(o.print_task_config) : []; })(),
      type: 'moonraker',
    };
  }

  const api = { QUERY, CHAMBER, HEAD_FAN, discover, queryWith, activeExtruder, readStatus, metadataPath,
                slicerTotalSeconds };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytMoonraker = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
