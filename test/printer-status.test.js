const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { normalizeProgress, fileProgressPct, etaSeconds, layerProgressPct, moonrakerProgress, explainPrinterHttp, vendorMessage } = require('../lib/printer-status.js');
const S = require('../lib/printer-status.js');
const { duetHeaterTemp } = require('../lib/duet.js');

/**
 * Six adapters, six different notions of "progress", none of them bounded.
 * The Duet one could produce a genuinely absurd number; the rest simply trusted
 * whatever the printer said.
 */

test('progress is clamped to a whole 0-100', () => {
  assert.equal(normalizeProgress(61.4), 61);
  assert.equal(normalizeProgress(0), 0);
  assert.equal(normalizeProgress(100), 100);
  assert.equal(normalizeProgress(140), 100, 'a printer over-reporting must not exceed the bar');
  assert.equal(normalizeProgress(-5), 0);
});

test('junk progress becomes 0 rather than NaN on screen', () => {
  for (const junk of [undefined, null, '', 'nearly done', NaN, Infinity, {}]) {
    assert.equal(normalizeProgress(junk), 0, `${JSON.stringify(junk)} leaked through`);
  }
});

test('THE DUET BUG: a byte offset with no file size is not a percentage', () => {
  // (job.filePosition || 0) / (job.file?.size || 1) * 100 — with size absent the
  // divisor fell back to 1, so a 500 KB offset rendered as 50,000,000%.
  assert.equal(fileProgressPct(500_000, undefined), 0);
  assert.equal(fileProgressPct(500_000, 0), 0, 'zero size must not divide');
  assert.equal(fileProgressPct(500_000, null), 0);
});

test('a byte offset with a real size is a real percentage', () => {
  assert.equal(fileProgressPct(500_000, 1_000_000), 50);
  assert.equal(fileProgressPct(0, 1_000_000), 0);
  assert.equal(fileProgressPct(1_000_000, 1_000_000), 100);
  assert.equal(fileProgressPct(2_000_000, 1_000_000), 100, 'past the end still caps at 100');
});

test('ETA extrapolates from elapsed time and progress', () => {
  // Half done after an hour → about an hour left.
  assert.equal(etaSeconds(3600, 0.5), 3600);
  assert.equal(etaSeconds(3600, 0.75), 1200);
  assert.equal(etaSeconds(3600, 1), 0, 'finished means nothing left');
});

test('ETA refuses to guess rather than printing a wild number', () => {
  // The old inline version used `progress || 1`, so 0% produced an ETA equal to
  // the elapsed time — a confident answer built on nothing.
  assert.equal(etaSeconds(60, 0), null, 'no progress yet — cannot extrapolate');
  assert.equal(etaSeconds(60, 0.005), null, 'under 1% is noise, not a signal');
  assert.equal(etaSeconds(0, 0.5), null, 'no elapsed time to extrapolate from');
  assert.equal(etaSeconds(undefined, 0.5), null);
  assert.equal(etaSeconds(3600, undefined), null);
});

test('every adapter routes its progress through the normaliser', () => {
  // Structural: a seventh adapter added later must not reintroduce raw arithmetic.
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const fn = main.slice(main.indexOf('async function fetchPrinterStatus'),
                        main.indexOf('function defaultPrinterPort'));
  // The allowlist is "helpers that clamp internally", not "lines I want to pass".
  // moonrakerProgress calls normalizeProgress on both of its branches, and
  // `prog` is its return value — so `progress: prog.percent` IS clamped, just
  // one call away. A raw `vs.progress * 100` still fails, which is the point.
  const rawProgress = fn.split('\n').filter(l =>
    /^\s*progress:/.test(l)
    && !/normalizeProgress\(|fileProgressPct\(/.test(l)
    && !/^\s*progress:\s*prog\.percent,?\s*$/.test(l));
  assert.deepEqual(rawProgress, [],
    `these bypass the clamp: ${rawProgress.map(s => s.trim()).join(' | ')}`);
});

test('the unreachable Bambu HTTP header is gone', () => {
  // Bambu returns earlier via MQTT, so this line never ran — but it implied
  // Bambu used HTTP bearer auth, which would mislead the next person to touch it.
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.ok(!/type === 'bambu'\)\s+headers\['Authorization'\]/.test(main),
    'dead Bambu HTTP auth header is back');
});

/* ── Moonraker authentication ────────────────────────────────────────────── */

const mainSrc = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');

test('Moonraker sends its API key like every other authenticated adapter', () => {
  // Moonraker accepts X-Api-Key from untrusted clients. Without it Khayt only
  // worked when the printer listed this machine in `trusted_clients`; a shop
  // running `force_logins: True` got a blanket 401 and no explanation.
  const statusBlock = mainSrc.slice(
    mainSrc.indexOf('async function fetchPrinterStatus'),
    mainSrc.indexOf('const get = async'),
  );
  assert.match(statusBlock, /'moonraker'\) headers\['X-Api-Key'\]|moonraker'\)\s*headers/,
    'moonraker is absent from the status auth headers');
});

test('the upload path authenticates Moonraker too', () => {
  const upload = mainSrc.slice(
    mainSrc.indexOf("fd.set('root', 'gcodes')") - 200,
    mainSrc.indexOf("fd.set('root', 'gcodes')") + 260,
  );
  assert.match(upload, /X-Api-Key/, 'moonraker upload sends no key');
});

test('an unset key is not sent as the string "undefined"', () => {
  // The old lines assigned apiKey unconditionally, so a machine saved without a
  // key sent `X-Api-Key: undefined` — worse than sending nothing, because
  // Moonraker in trusted-client mode needs no key at all.
  assert.ok(!/headers\['X-Api-Key'\] = apiKey;\n\s*if \(type === 'prusalink'\)/.test(mainSrc),
    'unguarded header assignment is back');
  assert.match(mainSrc, /if \(apiKey\) \{/, 'the non-empty-key guard is gone');
});

/**
 * Moonraker progress. The fixture below is a REAL payload, captured from a
 * Snapmaker U1 on 2026-08-01 while it printed a 31 MB relief — not a shape I
 * invented, which matters because the whole defect was that the invented shape
 * never showed the problem.
 *
 * At that moment the job was 19.4% done by the clock (65 min of the slicer's
 * 5h17m). Bytes said 0.7%; layers said 17.9%.
 */
const LIVE_U1 = {
  print_stats: {
    filename: 'KING-Abdulaziz-ART-200mm-U1_PLA_5h17m.gcode',
    total_duration: 4259.78, print_duration: 3688.72, filament_used: 16950.31,
    state: 'printing', info: { total_layer: 28, current_layer: 5 },
  },
  virtual_sdcard: { progress: 0.00668172566645534, is_active: true, file_position: 208363, file_size: 31184010 },
};

test('a real printing U1 does not report a five-hour job as 1% done', () => {
  const p = moonrakerProgress(LIVE_U1.print_stats, LIVE_U1.virtual_sdcard);
  assert.equal(p.source, 'layers');
  assert.equal(p.percent, 18, 'layer 5 of 28');
  // The byte figure this replaces. Guard the specific number so nobody
  // "simplifies" back to virtual_sdcard.progress.
  assert.notEqual(p.percent, normalizeProgress(LIVE_U1.virtual_sdcard.progress * 100));
});

test('and its ETA is hours, not weeks', () => {
  const p = moonrakerProgress(LIVE_U1.print_stats, LIVE_U1.virtual_sdcard);
  const eta = etaSeconds(LIVE_U1.print_stats.print_duration, p.percent / 100);
  const hours = eta / 3600;
  // ~4.2 h genuinely remained. Anything in the right ballpark is fine; what
  // must never come back is the 178 hours the inline arithmetic produced.
  assert.ok(hours > 2 && hours < 8, `ETA was ${hours.toFixed(1)} h`);

  // What the old inline expression did with this very payload.
  const vs = LIVE_U1.virtual_sdcard, ps = LIVE_U1.print_stats;
  const old = Math.round((ps.total_duration / (vs.progress || 1)) * (1 - (vs.progress || 0)));
  assert.ok(old / 3600 > 100, 'the old path really did produce a triple-digit-hour ETA');
});

test('layers are used only when Klipper actually reports them', () => {
  assert.equal(layerProgressPct({ current_layer: 5, total_layer: 28 }), 18);
  assert.equal(layerProgressPct({ current_layer: 0, total_layer: 28 }), 0, 'first layer is not "no data"');
  // Anything unusable falls through to bytes rather than inventing a number.
  for (const info of [null, undefined, {}, { total_layer: 0, current_layer: 3 }, { current_layer: 'x', total_layer: 10 }]) {
    assert.equal(layerProgressPct(info), null, JSON.stringify(info));
  }
  const noLayers = moonrakerProgress({ info: {} }, { progress: 0.5 });
  assert.deepEqual(noLayers, { percent: 50, source: 'bytes' });
});

test('a printer that reports neither reads as 0, not as NaN', () => {
  assert.deepEqual(moonrakerProgress({}, {}), { percent: 0, source: 'bytes' });
  assert.deepEqual(moonrakerProgress(null, null), { percent: 0, source: 'bytes' });
});

// ---------------------------------------------------------------------------
// The vendor-documentation audit of 2026-08-25. Each test below fixes a shape
// that a vendor's own documentation or firmware source says is real, against a
// reader that assumed a different one. See docs/PRINTER-PROTOCOL-AUDIT.md.
// ---------------------------------------------------------------------------

test('THE DUET BUG, second act: flags=f removes the file the percentage needs', () => {
  // rr_model's `f` flag sets includeNonLive=false (ObjectModel.cpp) and job.file
  // is tagged ObjectModelEntryFlags::none (PrintMonitor.cpp), so this is what a
  // Duet actually returns to `rr_model?key=&flags=d99fn` — a job forty minutes in
  // with no file object anywhere in it.
  const live = { result: { state: { status: 'processing' },
    job: { duration: 2400, filePosition: 337942, rawExtrusion: 9100, timesLeft: { file: 900 } } } };
  assert.equal(fileProgressPct(live.result.job.filePosition, live.result.job.file?.size), 0,
    'this is what every Duet showed: a running job at 0%');

  // The second query, without `f`, is the one that carries it.
  const fileQuery = { key: 'job.file', result: { fileName: '0:/gcodes/bracket.gcode', size: 1468987 } };
  assert.equal(fileProgressPct(live.result.job.filePosition, fileQuery.result.size), 23);
  assert.equal(fileQuery.result.fileName, '0:/gcodes/bracket.gcode');
});

test('Duet heaters are resolved from the machine, not from index 0 and 1', () => {
  const heaters = [{ current: 59.8 }, { current: 212.4 }];

  // A stock config publishes no mapping and must keep working unchanged.
  assert.equal(duetHeaterTemp({ heaters }, undefined, 'bed'), 59.8);
  assert.equal(duetHeaterTemp({ heaters }, undefined, 'tool'), 212.4);

  // The same machine, describing itself. Same answers.
  assert.equal(duetHeaterTemp({ heaters, bedHeaters: [0] }, [{ heaters: [1] }], 'bed'), 59.8);
  assert.equal(duetHeaterTemp({ heaters, bedHeaters: [0] }, [{ heaters: [1] }], 'tool'), 212.4);

  // A bedless machine with its hotend on heater 0. The old read showed the
  // hotend's 212 degrees under "bed", and index 1 — which does not exist — as the
  // nozzle. RRF documents bedHeaters entries as "may be -1 if unconfigured".
  const bedless = { heaters: [{ current: 212.4 }], bedHeaters: [-1] };
  assert.equal(duetHeaterTemp(bedless, [{ heaters: [0] }], 'bed'), null, 'no bed means no bed temperature');
  assert.equal(duetHeaterTemp(bedless, [{ heaters: [0] }], 'tool'), 212.4);
});

test('Klipper reports "not set" as null, and null is not layer zero', () => {
  // print_stats.py leaves info_current_layer as None until a slicer sends
  // SET_PRINT_STATS_INFO CURRENT_LAYER. Number(null) is 0 and 0 is finite, so a
  // slicer announcing only TOTAL_LAYER used to pin the job at 0% AND suppress the
  // byte fallback, because layers had "answered".
  assert.equal(layerProgressPct({ current_layer: null, total_layer: 500 }), null);
  assert.deepEqual(moonrakerProgress({ info: { current_layer: null, total_layer: 500 } }, { progress: 0.44 }),
    { percent: 44, source: 'bytes' });

  // Neither set: unchanged, still falls back to bytes.
  assert.deepEqual(moonrakerProgress({ info: { current_layer: null, total_layer: null } }, { progress: 0.44 }),
    { percent: 44, source: 'bytes' });

  // Both set: unchanged. This is the U1 measurement the fallback was built from.
  assert.deepEqual(moonrakerProgress({ info: { current_layer: 5, total_layer: 28 } }, { progress: 0.00668 }),
    { percent: 18, source: 'layers' });
});

test('Repetier stateList is keyed by slug, and carries no job at all', () => {
  // What this test used to do is worth recording, because it is why the adapter
  // stayed broken through an audit that reported it fixed: it built its own
  // fixture with `job` and `done` sitting on the stateList entry, asserted
  // against a re-implementation of the adapter written inline, and passed. Both
  // halves were wrong. Repetier does not send those fields on this call — they
  // are on `?a=listPrinter` — and a test that re-implements the code under test
  // can only ever prove the fixture agrees with itself.
  //
  // What survives here is the one claim that was true and is this file's
  // business: the envelope. `{error:"", data:{ "<slug>": {...} }}` is an object
  // keyed by slug, and indexing it with [0] is undefined.
  //
  // The adapter itself is now driven, with two real payload shapes, in
  // test/repetier.test.js.
  const body = { error: '', data: { irapid: {
    activeExtruder: 0, layer: 87,
    extruder: [{ tempRead: 212.4 }], heatedBeds: [{ tempRead: 59.8 }],
  } } };
  assert.equal(body.data[0], undefined, 'the read that was there');

  const state = body.data.irapid;
  assert.equal(state.extruder[state.activeExtruder].tempRead, 212.4);
  assert.equal(state.done, undefined, 'progress is not on this call, and never was');
  assert.equal(state.job, undefined, 'nor is the job');
});

/**
 * What a shop is told when a printer's server refuses the poll.
 *
 * Every HTTP adapter threw `HTTP <status>` and that string is rendered raw on
 * the dashboard card, so the two most ordinary conditions in the field —
 * "OctoPrint is up but no printer is connected" and "your key is wrong" —
 * reached the owner as HTTP 409 and HTTP 403.
 */

test('a status code is turned into something the owner can act on', () => {
  const oct = explainPrinterHttp('octoprint', 409, '{"error":"Printer is not operational"}');
  assert.match(oct, /not connected to a printer/i);
  assert.match(oct, /Printer is not operational/, "the vendor's own words are quoted, not paraphrased");

  const moon = explainPrinterHttp('moonraker', 503, '{"error":{"code":503,"message":"Klippy Host not connected"}}');
  assert.match(moon, /Klipper is not running/i);
  assert.match(moon, /Klippy Host not connected/, 'the message names WHICH failure it is');

  assert.match(explainPrinterHttp('octoprint', 403, ''), /API key/i);
  assert.match(explainPrinterHttp('moonraker', 401, ''), /trusted_clients/);
  assert.match(explainPrinterHttp('prusalink', 401, ''), /Settings → Network → PrusaLink/);
});

test('nothing is invented for a status that has no known meaning', () => {
  // Returning null hands the caller back its own `HTTP <status>`, which is
  // useless but true. A confident sentence about the wrong cause is worse: the
  // Bambu timeout message spent a release naming three settings that were all
  // correct.
  assert.equal(explainPrinterHttp('octoprint', 500, ''), null);
  assert.equal(explainPrinterHttp('moonraker', 404, ''), null);
  assert.equal(explainPrinterHttp('duet', 401, ''), null, 'Duet reads 401 as a transport signal, not an error');
  assert.equal(explainPrinterHttp('repetier', 503, ''), null);
  assert.equal(explainPrinterHttp('', 409, ''), null);
});

test('a printer error body cannot run away with the status line', () => {
  // The body comes off a device on the LAN and lands in a one-line status on a
  // card, so its length is not something this end controls.
  assert.equal(vendorMessage({ error: 'a\nb   c' }), 'a b c');
  const long = vendorMessage(JSON.stringify({ error: 'x'.repeat(500) }));
  assert.equal(long.length, 198, 'capped, with an ellipsis');
  assert.ok(long.endsWith('…'));
  assert.equal(vendorMessage(''), '');
  assert.equal(vendorMessage('not json at all'), 'not json at all');
  assert.equal(vendorMessage('{"nothing":"useful"}'), '');
});

/**
 * Zero is a reading, and four adapters used to say it was not.
 *
 * `(obj && obj.field) || null` turns a genuine 0 into "nothing reported",
 * because `0 || null` is `null`. It was written four times across two
 * adapters, and once — Moonraker's nozzle line — it was written correctly two
 * lines from a wrong one, which is how it survived.
 */
test('reading: zero is a number, absence is null', () => {
  assert.equal(S.reading(0), 0, 'a genuine zero must survive');
  assert.equal(S.reading(-5), -5);
  assert.equal(S.reading('21.4'), 21.4, 'firmwares send numbers as strings');
  assert.equal(S.reading(null), null);
  assert.equal(S.reading(undefined), null);
  assert.equal(S.reading(''), null, 'an unread sensor is not a sensor at 0');
  assert.equal(S.reading('nan'), null);
  assert.equal(S.reading(NaN), null);
  assert.equal(S.reading(Infinity), null);
});

test('reading: the empty string is not zero, which Number() disagrees with', () => {
  // The trap this guards: `Number('')` is 0, so a coercion without the guard
  // invents a reading for a sensor that reported none.
  assert.equal(Number(''), 0);
  assert.equal(S.reading(''), null);
});

test('a print with zero seconds left says zero, not unknown', () => {
  // OctoPrint's own value at the instant a print finishes. Reported as null,
  // the 48-hour band fell back to estimating from a percentage of 100.
  const O = require('../lib/octoprint.js');
  const got = O.readStatus(
    { state: { text: 'Operational' }, temperature: { tool0: { actual: 0 }, bed: { actual: 0 } } },
    { progress: { completion: 100, printTimeLeft: 0 }, job: { file: { name: 'a.gcode' } } });
  assert.equal(got.timeRemaining, 0, 'a finished print reported no time left at all');
  assert.equal(got.tempNozzle, 0, 'a cold nozzle read as a silent one');
  assert.equal(got.tempBed, 0);
});

test('a Klipper bed at zero reads zero, like the nozzle beside it', () => {
  const M = require('../lib/moonraker.js');
  const at = (t) => ({ result: { status: {
    print_stats: { state: 'standby' }, virtual_sdcard: {}, toolhead: {},
    extruder: { temperature: t }, heater_bed: { temperature: t } } } });
  const cold = M.readStatus(at(0), null, null);
  assert.equal(cold.tempNozzle, 0);
  assert.equal(cold.tempBed, 0, 'the bed line disagreed with the nozzle line above it');

  // And a machine that reports no heaters at all still reports nothing.
  const silent = M.readStatus(
    { result: { status: { print_stats: { state: 'standby' }, virtual_sdcard: {}, toolhead: {} } } },
    null, null);
  assert.equal(silent.tempNozzle, null);
  assert.equal(silent.tempBed, null);
});
