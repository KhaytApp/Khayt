'use strict';

(function (global) {
/**
 * Which settings actually worked for this part.
 *
 * A print file already counts how many times it printed and how many times it
 * failed, but not WITH WHAT. So a shop reprinting a bracket six months later
 * knows it worked once and has no idea on which machine, in which material, at
 * which layer height — which is the same as not knowing.
 *
 * A setup is one combination of those things plus its record. The shop's own
 * "log a print / log a failure" buttons already exist; they now land against a
 * setup instead of a bare counter.
 *
 * Two decisions worth stating, because both could reasonably have gone the other
 * way:
 *
 * 1. Status is DERIVED from outcomes, not asked for. PrintStash makes the user
 *    mark a revision known_good. A shop that has run the same setup five times
 *    without trouble should not also have to tell us it works. An explicit
 *    override still exists, because "it printed, but I did not like the finish"
 *    is a judgement no tally can reach.
 *
 * 2. One bad print does not condemn a setup. Filament runs out, a spool tangles,
 *    somebody knocks the machine. What matters is the rate, so nine successes
 *    and one failure is still a good setup — and one success against three
 *    failures is not, however recently that success happened.
 *
 * Pure: no DOM, no store, no clock. Timestamps are passed in.
 */

const STATUS = {
  KNOWN_GOOD: 'known-good',
  NEEDS_TEST: 'needs-test',
  FAILED: 'failed',
};

/** A setup has to clear this hit rate to count as known-good. */
const GOOD_RATE = 0.75;

const int = (v) => {
  const n = Math.trunc(Number(v));
  return Number.isFinite(n) && n > 0 ? n : 0;
};

/**
 * What the record says about this setup, ignoring any override.
 *
 * Never printed is NOT a failure — it is the honest "nobody has tried this yet",
 * and a shop reading "failed" against a setup they have never run would be being
 * told something untrue.
 */
function deriveStatus(setup) {
  const ok = int(setup && setup.ok);
  const failed = int(setup && setup.failed);
  if (ok === 0 && failed === 0) return STATUS.NEEDS_TEST;
  if (ok === 0) return STATUS.FAILED;
  const rate = ok / (ok + failed);
  if (rate >= GOOD_RATE) return STATUS.KNOWN_GOOD;
  // It has worked at least once, so it is not hopeless — but it is not something
  // to reach for either.
  return STATUS.NEEDS_TEST;
}

/** The shop's own verdict if they gave one, otherwise the record's. */
function statusOf(setup) {
  const override = setup && setup.status;
  if (override === STATUS.KNOWN_GOOD || override === STATUS.NEEDS_TEST || override === STATUS.FAILED) {
    return override;
  }
  return deriveStatus(setup);
}

/** How often this setup has come off the bed intact, 0..1, or null if untried. */
function successRate(setup) {
  const ok = int(setup && setup.ok);
  const failed = int(setup && setup.failed);
  if (ok + failed === 0) return null;
  return ok / (ok + failed);
}

/**
 * Record one print against a setup. Returns a NEW setup — callers own persistence.
 * @param {object} setup
 * @param {boolean} ok
 * @param {string} atIso  when it happened, supplied by the caller
 */
function recordOutcome(setup, ok, atIso) {
  const s = Object.assign({}, setup || {});
  if (ok) {
    s.ok = int(s.ok) + 1;
    s.lastOkAt = atIso || s.lastOkAt || null;
  } else {
    s.failed = int(s.failed) + 1;
    s.lastFailedAt = atIso || s.lastFailedAt || null;
  }
  return s;
}

const time = (iso) => {
  const t = Date.parse(iso || '');
  return Number.isFinite(t) ? t : 0;
};

/**
 * The one setup to reach for.
 *
 * Deliberately returns null rather than a best-of-a-bad-lot: if every setup has
 * failed, the answer a shop needs is "change something", not "try the least
 * broken one again". Recommending a known-failing setup would waste a spool and
 * a night.
 *
 * The ordering is total, so the recommendation does not flip between two equally
 * good setups from one render to the next.
 */
function recommendSetup(setups) {
  const list = Array.isArray(setups) ? setups.filter((s) => s && typeof s === 'object') : [];
  const eligible = list.filter((s) => statusOf(s) !== STATUS.FAILED);
  if (!eligible.length) return null;

  const rank = (s) => (statusOf(s) === STATUS.KNOWN_GOOD ? 0 : 1);
  const sorted = eligible.slice().sort((a, b) => {
    // Known-good beats untested, however many times the untested one is listed.
    const r = rank(a) - rank(b);
    if (r !== 0) return r;
    // Then whichever has worked more often.
    const ok = int(b.ok) - int(a.ok);
    if (ok !== 0) return ok;
    // Then whichever worked most recently.
    const recent = time(b.lastOkAt) - time(a.lastOkAt);
    if (recent !== 0) return recent;
    // Then oldest-defined first, so the answer is stable across renders.
    const made = time(a.createdAt) - time(b.createdAt);
    if (made !== 0) return made;
    return String(a.id || '').localeCompare(String(b.id || ''));
  });
  return sorted[0];
}

/** A short human line: "0.2mm · 0.4 nozzle · PLA on Prusa MK4". */
function describeSetup(setup, machineName) {
  if (!setup || typeof setup !== 'object') return '';
  const bits = [];
  if (setup.layerHeightMm > 0) bits.push(`${setup.layerHeightMm}mm layers`);
  if (setup.nozzleMm > 0) bits.push(`${setup.nozzleMm}mm nozzle`);
  const material = [setup.material, setup.colour].filter(Boolean).join(' ');
  if (material) bits.push(material);
  const line = bits.join(' · ');
  const where = machineName || setup.machineName || '';
  if (line && where) return `${line} on ${where}`;
  return line || where || '';
}

/** Counts for a file's badge row. */
function summarize(setups) {
  const list = Array.isArray(setups) ? setups.filter((s) => s && typeof s === 'object') : [];
  const out = { total: list.length, knownGood: 0, needsTest: 0, failed: 0, prints: 0, failures: 0 };
  for (const s of list) {
    const st = statusOf(s);
    if (st === STATUS.KNOWN_GOOD) out.knownGood += 1;
    else if (st === STATUS.FAILED) out.failed += 1;
    else out.needsTest += 1;
    out.prints += int(s.ok);
    out.failures += int(s.failed);
  }
  return out;
}

const api = {
  STATUS, GOOD_RATE,
  deriveStatus, statusOf, successRate,
  recordOutcome, recommendSetup, describeSetup, summarize,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytPrintSetups = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
