/**
 * Measured filament and duration, offered when a Bed Ready job completes.
 *
 * lib/printer-actuals.js already decides what counts as a measurement; that is tested
 * elsewhere. What is tested here is the join: whether Bed Ready asks at the right moment,
 * stays quiet when there is nothing measured to offer, and — the one that matters most —
 * whether it says WHICH JOB the numbers came off.
 *
 * A completion stays offerable for 24 hours. A shop running five-hour prints back to back
 * will have started another one well inside that window, so the figures can belong to the
 * previous print while wearing a green "Measured" label. That is not hypothetical: it is
 * the bug #566 fixed in Khayt, and this is the same data with a different dialog around it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const ACTUALS = fs.readFileSync(path.join(ROOT, 'renderer/bedready-actuals.js'), 'utf8');
const PA = fs.readFileSync(path.join(ROOT, 'lib/printer-actuals.js'), 'utf8');

const HOUR = 3600 * 1000;

/** A renderer scope with only what Bed Ready ships. */
function boot({ completion = null, machineId = 'M1' } = {}) {
  const shown = [];
  const ctx = {
    machineStatusCache: machineId ? { [machineId]: { lastCompleted: completion } } : {},
    escapeHtml: (s) => String(s == null ? '' : s),
    t: (k) => k,
    saveAll: () => { ctx.saved = (ctx.saved || 0) + 1; },
    renderKanban: () => {},
    openFormModal: (opts) => { shown.push(opts); },
    module: undefined,
  };
  ctx.globalThis = ctx;
  // Share this realm's clock. A contextified object gets its OWN intrinsics, so
  // without this the code under test reads a different `Date` from the fixture
  // that feeds it — harmless while both are the real clock, and wrong the moment
  // anything moves one of them. `npm run test:future` moves one of them, and all
  // eight tests here failed on a measurement that looked like it arrived from the
  // future. The bug was the split clock, not the code.
  ctx.Date = globalThis.Date;
  vm.createContext(ctx);
  vm.runInContext(PA, ctx);            // provides KhaytPrinterActuals
  vm.runInContext(ACTUALS, ctx);
  return { ctx, shown };
}

const job = (over) => Object.assign(
  { id: 'J1', machineId: 'M1', printTime: 5, parts: [{ printWeight: 100, qty: 1 }] }, over || {});

const measured = (over) => Object.assign({
  at: Date.now() - 60 * 1000,
  filename: 'dragon_v3.gcode',
  actuals: { durationS: 18517, filamentGrams: 140.96, source: 'moonraker' },
}, over || {});

/** Drive the modal's save handler with whatever the fields currently hold. */
function save(opts, values) {
  const fields = {};
  const modal = { querySelector: (sel) => ({ get value() { return fields[sel]; }, set value(v) { fields[sel] = v; } }) };
  // seed from the rendered markup so "unedited" means what the dialog actually showed
  for (const [sel, re] of [['#brActTime', /id="brActTime" value="([^"]+)"/], ['#brActWeight', /id="brActWeight" value="([^"]+)"/]]) {
    const m = opts.bodyHtml.match(re);
    fields[sel] = m ? m[1] : '';
  }
  Object.assign(fields, values || {});
  opts.onSave(modal);
  return fields;
}

test('it asks when the printer measured the job', () => {
  const { ctx, shown } = boot({ completion: measured() });
  assert.equal(ctx.brOfferActuals(job()), true, 'a measurement should be offered');
  assert.equal(shown.length, 1);
});

test('it stays quiet when there is nothing measured to offer', () => {
  for (const [why, completion] of [
    ['no completion at all', null],
    ['a completion carrying no figures', measured({ actuals: {} })],
    ['a completion too old to trust', measured({ at: Date.now() - 48 * HOUR })],
  ]) {
    const { ctx, shown } = boot({ completion });
    assert.equal(ctx.brOfferActuals(job()), false, why + ': should not open a dialog');
    assert.equal(shown.length, 0, why + ': nothing to show but the estimate the maker already has');
  }
});

test('a job with no machine is never offered another machine\'s numbers', () => {
  const { ctx, shown } = boot({ completion: measured() });
  assert.equal(ctx.brOfferActuals(job({ machineId: null })), false);
  assert.equal(shown.length, 0);
});

test('the dialog names the file the figures were measured on', () => {
  // The whole point. A completion stays offerable for 24h, so these numbers can belong to
  // the print BEFORE this one — and nothing else on screen would say so.
  const { ctx, shown } = boot({ completion: measured({ filename: 'previous_job.gcode' }) });
  ctx.brOfferActuals(job());
  assert.match(shown[0].bodyHtml, /previous_job\.gcode/,
    'the dialog must name the job it measured, or a stale figure looks like this one');
});

test('measured figures are recorded as measured, and the estimate is not', () => {
  const { ctx, shown } = boot({ completion: measured() });
  const order = job();
  ctx.brOfferActuals(order);
  save(shown[0]);
  assert.equal(order.actualPrintTime, 5.14, '18517s is 5.14h, not the 5h estimate');
  assert.equal(order.actualWeight, 141, '140.96g rounds to 141');
  assert.equal(order.actualsSource.time, 'moonraker');
  assert.equal(order.actualsSource.weight, 'moonraker');
});

test('editing a measured figure re-labels it as the maker\'s, not the printer\'s', () => {
  const { ctx, shown } = boot({ completion: measured() });
  const order = job();
  ctx.brOfferActuals(order);
  save(shown[0], { '#brActTime': '7.5' });
  assert.equal(order.actualPrintTime, 7.5);
  assert.equal(order.actualsSource.time, 'manual',
    'a typed figure taught to the estimator as a measurement would drift it toward what the shop already believed');
  assert.equal(order.actualsSource.weight, 'moonraker', 'the untouched one is still a measurement');
});

test('a printer that measures only one axis says so on each field', () => {
  // PrusaLink reports duration and no filament. Claiming either way would be a lie.
  const { ctx, shown } = boot({ completion: measured({ actuals: { durationS: 7200, source: 'prusalink' } }) });
  const order = job();
  assert.equal(ctx.brOfferActuals(order), true);
  const html = shown[0].bodyHtml;
  // Assert what the maker reads, not the lookup key: T() falls back to English when the
  // locale has no entry, which is exactly what a fresh install shows.
  assert.match(html, /Measured/, 'the measured axis should say so');
  assert.match(html, /Estimated/, 'and the one nothing measured must not claim otherwise');
  const timeBlock = html.slice(html.indexOf('brActTime'), html.indexOf('brActWeight'));
  assert.match(timeBlock, /Measured/, 'duration came off the printer');
  assert.ok(!/>Measured</.test(html.slice(html.indexOf('brActWeight'))), 'filament did not');
  save(shown[0]);
  assert.equal(order.actualsSource.time, 'prusalink');
  assert.equal(order.actualsSource.weight, 'manual', 'nothing measured the filament, so it is not a measurement');
});

test('the filename survives a real locale, not just the English fallback', () => {
  // The bug this pins: the stub above returns the key, so T() fell back to English and the
  // filename appeared. The SHIPPED locale returns "...measured on {file}..." and t() only
  // substitutes when given params — so the dialog rendered a literal {file} and the one
  // thing this feature must not get wrong was wrong in the app and right in the test.
  const { ctx, shown } = boot({ completion: measured({ filename: 'kingfix.gcode' }) });
  ctx.t = (k, params) => {
    const S = {
      'act.from_printer_file': 'These figures came from {source}, measured on {file} — not the estimate.',
      'act.measured': 'Measured', 'act.est': 'Estimated',
    };
    let out = S[k];
    if (!out) return k;
    if (params) for (const [n, v] of Object.entries(params)) out = out.split('{' + n + '}').join(v);
    return out;
  };
  ctx.brOfferActuals(job());
  const html = shown[0].bodyHtml;
  assert.match(html, /kingfix\.gcode/, 'the filename must appear with the locale in play');
  assert.match(html, /moonraker/, 'and the instrument that read it');
  assert.ok(!/\{file\}|\{source\}/.test(html), 'no placeholder may reach the screen');
});

test('an unfilled placeholder falls back rather than showing braces to the maker', () => {
  const { ctx, shown } = boot({ completion: measured({ filename: 'kingfix.gcode' }) });
  ctx.t = (k) => (k === 'act.from_printer_file' ? 'measured on {file}' : k);   // params ignored
  ctx.brOfferActuals(job());
  const html = shown[0].bodyHtml;
  assert.ok(!/\{file\}/.test(html), 'a line reading "{file}" is worse than one in English');
  assert.match(html, /kingfix\.gcode/, 'and the filename still has to be there');
});

test('recording persists, because an unsaved actual is not an actual', () => {
  const { ctx, shown } = boot({ completion: measured() });
  ctx.brOfferActuals(job());
  save(shown[0]);
  assert.ok(ctx.saved > 0, 'saveAll should have been called');
});

test('the queue offers it on completion, and only on completion', () => {
  const src = fs.readFileSync(path.join(ROOT, 'renderer/bedready-queue.js'), 'utf8');
  assert.match(src, /newStatus === 'completed' && typeof brOfferActuals === 'function'/,
    'the completion path should offer measured actuals');
  // After the save/repaint, never before: a dismissed dialog must not strand the card.
  const offerAt = src.indexOf('brOfferActuals(order)');
  const saveAt = src.indexOf('saveAll();');
  assert.ok(saveAt !== -1 && offerAt > saveAt,
    'offering must come after the completion is persisted, or dismissing it loses the move');
});

test('bedready.html loads printer-actuals before the code that calls it', () => {
  const html = fs.readFileSync(path.join(ROOT, 'renderer/bedready.html'), 'utf8');
  const lib = html.indexOf('lib/printer-actuals.js');
  const mod = html.indexOf('bedready-actuals.js');
  const queue = html.indexOf('bedready-queue.js');
  assert.ok(lib !== -1, 'printer-actuals.js is not loaded — every completion would be silent');
  assert.ok(mod > lib && queue > mod, 'load order: lib -> offer -> queue');
});
