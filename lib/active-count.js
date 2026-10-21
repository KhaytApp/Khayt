'use strict';
/**
 * The anonymous active-install count (khayt-cloud docs/api-contract.md,
 * "Active-install count"; khaytapp.com/privacy §11).
 *
 * The one thing Khayt sends without asking first (Turki, 2026-10-21; the single
 * exception to TELEMETRY-SPEC §3), so it is held to exactly what the privacy
 * page names: six fields, no id. Once a UTC day at most; the three flags say
 * whether this is the install's first COUNTED day this ISO week, this UTC month
 * and ever, which is how the cloud counts weekly and monthly actives without
 * ever knowing which install is which.
 *
 * PURE: no clock, no network, no disk. main.js owns those.
 */

/**
 * On since 2026-10-21: khaytapp.com/privacy#active-count-en (and -ar) describes
 * it, and Turki confirmed on-by-default to the desktop lane himself. Set it back
 * to false and nothing is sent and the Settings switch is hidden.
 */
const READY = true;

const ENDPOINT = 'https://cloud.khaytapp.com/v1/active';
const FIELDS = ['platform', 'channel', 'version', 'firstThisWeek', 'firstThisMonth', 'firstEver'];
const VERSION_RE = /^\d+\.\d+\.\d+(-[a-z]+\.\d+)?$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

/** "YYYY-MM-DD" of a Date in UTC. */
function utcDay(date) {
  return new Date(date).toISOString().slice(0, 10);
}

function isDay(d) {
  return typeof d === 'string' && DAY_RE.test(d) && !Number.isNaN(Date.parse(d + 'T00:00:00Z'));
}

/** ISO 8601 week ("2026-W43") of a UTC day: Monday start, the week's Thursday names the year. */
function isoWeek(day) {
  const d = new Date(day + 'T00:00:00Z');
  const dow = (d.getUTCDay() + 6) % 7;            // Monday 0 … Sunday 6
  d.setUTCDate(d.getUTCDate() - dow + 3);          // that week's Thursday
  const year = d.getUTCFullYear();
  const jan4 = new Date(Date.UTC(year, 0, 4));
  const week = 1 + Math.round(((d - jan4) / 86400000 - 3 + ((jan4.getUTCDay() + 6) % 7)) / 7);
  return `${year}-W${String(week).padStart(2, '0')}`;
}

/** The three flags, from the last counted day (or none). */
function flags(lastCounted, today) {
  if (!isDay(lastCounted)) return { firstThisWeek: true, firstThisMonth: true, firstEver: true };
  return {
    firstThisWeek: isoWeek(lastCounted) !== isoWeek(today),
    firstThisMonth: lastCounted.slice(0, 7) !== today.slice(0, 7),
    firstEver: false,
  };
}

function platformOf(nodePlatform) {
  return nodePlatform === 'win32' ? 'win' : nodePlatform === 'darwin' ? 'mac' : 'linux';
}

/** The channel the RUNNING build is on, read off its version. */
function channelOf(version) {
  const m = /-(alpha|beta)\./.exec(String(version || ''));
  return m ? m[1] : 'stable';
}

/**
 * The body, or null when it must not be sent: a version the cloud would refuse
 * is a sender bug, and sending it would only be refused.
 */
function buildBody({ platform, version, lastCounted, today }) {
  const v = String(version || '');
  if (!VERSION_RE.test(v) || !isDay(today)) return null;
  return {
    platform: platformOf(platform),
    channel: channelOf(v),
    version: v,
    ...flags(lastCounted, today),
  };
}

/**
 * Whether to send now. `state` is this install's own file
 * ({ off, lastCounted, doneDay }); it never lives in the shop's book, which
 * syncs between machines.
 */
function due(state, today, ready = READY) {
  const s = state || {};
  return !!ready && !s.off && isDay(today) && s.doneDay !== today;
}

/**
 * The state after an answer. 200 (counted or capped) is done for the day and
 * moves lastCounted; 422 is a bug in this sender, so the day is done but
 * nothing was counted; anything else (404 while the cloud is off, 5xx, no
 * network) was not counted and is tried again.
 */
function after(state, today, status) {
  const s = { ...(state || {}) };
  if (status === 200) return { ...s, lastCounted: today, doneDay: today };
  if (status === 422) return { ...s, doneDay: today };
  return s;
}

const api = { READY, ENDPOINT, FIELDS, VERSION_RE, utcDay, isoWeek, flags, platformOf, channelOf, buildBody, due, after };
module.exports = api;
