'use strict';
/**
 * The workshop's temperature and humidity, written down by hand.
 *
 * `envLogs` is a top-level collection of the book. Each reading is
 *
 *   { id, timestamp, temperature, humidity, machineId, notes }
 *
 * `timestamp` an ISO instant, `temperature` in °C and `humidity` in % (either
 * may be null, never both), `machineId` null for the room as a whole. That
 * shape is FROZEN: the desktop wrote it first, a book carries it between the
 * desktop and the Mac, and sync merges it record by record — so neither app may
 * rename a field.
 *
 * This was renderer/operations-extras.js's save handler and table, inline, so
 * only the Electron window could log a reading. It is here so the Mac logs the
 * same record and reads the same trend.
 *
 * ONE FIX ON THE WAY. The desktop's check read the typed temperature into a
 * local called `t` — the same name as the translation function — and then
 * called `t('env.temp_range')` to say it was out of range. That threw, so a
 * reading of 150 °C was neither refused with a message nor saved: the button
 * simply did nothing. The check returns the key now and the caller says it.
 *
 * PURE: no DOM, no clock. The id and the time are handed in.
 */
(function (global) {

  const TEMP_MIN = -50;
  const TEMP_MAX = 100;
  const HUMIDITY_MIN = 0;
  const HUMIDITY_MAX = 100;

  /** How many readings the list shows, newest first. */
  const LIST_LIMIT = 50;
  /** How many readings the temperature line draws, oldest first. */
  const TREND_LIMIT = 20;

  /** A typed value: null when blank, NaN when it is not a number. */
  function reading(v) {
    if (v == null) return null;
    if (typeof v === 'number') return Number.isFinite(v) ? v : NaN;
    const s = String(v).trim();
    if (s === '') return null;
    const n = parseFloat(s);
    return Number.isFinite(n) ? n : NaN;
  }

  /**
   * Why a form cannot be logged, as a translation key, or null when it can.
   * `form` is `{ temperature, humidity }`, typed text or numbers.
   */
  function check(form) {
    const f = form || {};
    const temp = reading(f.temperature);
    const hum = reading(f.humidity);
    if (temp === null && hum === null) return 'env.need_value';
    if (temp !== null && (Number.isNaN(temp) || temp < TEMP_MIN || temp > TEMP_MAX)) return 'env.temp_range';
    if (hum !== null && (Number.isNaN(hum) || hum < HUMIDITY_MIN || hum > HUMIDITY_MAX)) return 'env.humidity_range';
    return null;
  }

  /**
   * The record to append to `envLogs`, or null when `check` refuses the form.
   * `ctx` is `{ id, now }` — the new id and the moment, in milliseconds or as
   * anything `Date` takes.
   */
  function entry(form, ctx) {
    if (check(form) !== null) return null;
    const f = form || {};
    const c = ctx || {};
    const temp = reading(f.temperature);
    const hum = reading(f.humidity);
    const machine = f.machineId == null ? '' : String(f.machineId).trim();
    return {
      id: String(c.id || ''),
      timestamp: new Date(c.now).toISOString(),
      temperature: temp,
      humidity: hum,
      machineId: machine || null,
      notes: String(f.notes == null ? '' : f.notes).trim(),
    };
  }

  const isRecord = (r) => r && typeof r === 'object' && !Array.isArray(r);
  const stampOf = (r) => (typeof r.timestamp === 'string' ? r.timestamp : '');

  /** The readings the list shows: newest first, at most `limit`. */
  function recent(logs, limit) {
    const n = limit == null ? LIST_LIMIT : Math.max(0, +limit || 0);
    return (Array.isArray(logs) ? logs : []).filter(isRecord)
      .slice().sort((a, b) => stampOf(b).localeCompare(stampOf(a)))
      .slice(0, n);
  }

  /**
   * The temperature line: the last `limit` readings that have one, oldest
   * first, with the range they span. Null when there are fewer than two, which
   * is not a line.
   */
  function temperatureTrend(logs, limit) {
    const n = limit == null ? TREND_LIMIT : Math.max(0, +limit || 0);
    const rows = (Array.isArray(logs) ? logs : []).filter(isRecord)
      .filter((r) => r.temperature != null && Number.isFinite(+r.temperature))
      .slice().sort((a, b) => stampOf(a).localeCompare(stampOf(b)));
    const readings = rows.slice(Math.max(0, rows.length - n)).map((r) => +r.temperature);
    if (readings.length < 2) return null;
    return { readings, min: Math.min(...readings), max: Math.max(...readings) };
  }

  const api = {
    TEMP_MIN, TEMP_MAX, HUMIDITY_MIN, HUMIDITY_MAX, LIST_LIMIT, TREND_LIMIT,
    check, entry, recent, temperatureTrend,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytEnvLog = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
