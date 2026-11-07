'use strict';
/**
 * Care plans, "Not needed" and "Parts to buy" on the desktop.
 *
 * lib/care-plans.js and deferTask are tested in care-plans.test.js; this is the
 * desktop's wiring around them. A correct module with no caller is the bug this
 * repo keeps having, so: both entry points load the lib, the maintenance window
 * calls it the way the PR promises, and every word it shows exists in all nine
 * languages.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const CP = require('../lib/care-plans');

const root = path.join(__dirname, '..');
const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');
const LOCALES = ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh'];
function locale(loc) {
  const ctx = { globalThis: {} };
  ctx.window = ctx.globalThis;
  vm.runInNewContext(read(`renderer/locales/${loc}.js`), ctx);
  return ctx.globalThis.KhaytLocales[loc];
}

test('both entry points load care-plans.js after maintenance.js', () => {
  for (const f of ['renderer/index.html', 'renderer/bedready.html']) {
    const h = read(f);
    const m = h.indexOf('<script src="../lib/maintenance.js"></script>');
    const c = h.indexOf('<script src="../lib/care-plans.js"></script>');
    assert.ok(m > 0 && c > m, `${f} loads care-plans.js after maintenance.js`);
    assert.ok(c < h.indexOf('<script src="machines.js"></script>'), `${f} loads it before machines.js`);
  }
});

test('the maintenance window applies a plan the way the Mac does', () => {
  const js = read('renderer/machines.js');
  assert.match(js, /CP\.matchPlan\(machine\.vendor, machine\.printerModelName \|\| machine\.printerModel, machine\.name\)/);
  assert.match(js, /CP\.comparePlan\(machMaintTasks, machineId, p\.id, cpNamesById\(p\.id\)\)/);
  assert.match(js, /confirm: usePlan \? cmp\.differ\.map\(x => x\.recordId\) : \[\]/, 'own intervals change only when ticked');
  assert.match(js, /newId: \(\) => uid\('MTASK'\)/);
  assert.match(js, /machMaintTasks = r\.tasks;\s*saveAll\(\);/);
});

test('"Not needed" defers without a done and without a log row', () => {
  const js = read('renderer/machines.js');
  const at = js.indexOf("if (deferBtn) {");
  const body = js.slice(at, js.indexOf('} else if (doneBtn)', at));
  assert.match(body, /KhaytMaintenance\.deferTask\(tk, machineHoursMeter\(machineId\), new Date\(\)\.toISOString\(\)\)/);
  assert.doesNotMatch(body, /machMaintLog|markDone/);
  assert.match(js, /const notNeeded = st\.status !== 'ok'/, 'offered only on a task asking for attention');
});

test('Parts to buy reads partsBuyList and is reachable from the Printers settings', () => {
  const js = read('renderer/machines.js');
  assert.match(js, /KhaytCarePlans\.partsBuyList\(\{\s*machines, tasks: [^,]+machMaintTasks[^,]*: \[\],\s*jobs: printLog, now: Date\.now\(\),\s*\}\)/);
  assert.match(read('renderer/index.html'), /id="btnPartsToBuy"[^>]*data-i18n="maint\.pb_title"/);
  assert.match(read('renderer/wire-events.js'), /\$\('#btnPartsToBuy'\)\?\.addEventListener\('click', \(\) => openPartsToBuy\(\)\)/);
});

test('every word the plans can show exists in all nine languages, with its placeholders', () => {
  const keys = ['maint.cp_apply', 'maint.cp_brand', 'maint.cp_model', 'maint.cp_source', 'maint.cp_open_source',
    'maint.cp_source_starter', 'maint.cp_task_starter', 'maint.cp_parts_used', 'maint.cp_have', 'maint.cp_differ_title',
    'maint.cp_use_plan', 'maint.cp_differ_keep', 'maint.cp_apply_btn', 'maint.cp_applied', 'maint.cp_nothing',
    'maint.not_needed', 'maint.not_needed_help', 'maint.deferred',
    'maint.pb_title', 'maint.pb_none', 'maint.pb_order_by', 'maint.pb_due', 'maint.pb_late', 'maint.pb_copy', 'maint.pb_hint'];
  for (const p of CP.allPlans()) for (const tk of p.tasks) keys.push('maint.t_' + tk.id);
  for (const pt of CP.parts()) keys.push('maint.part_' + pt.id);
  const en = locale('en');
  for (const loc of LOCALES) {
    const L = locale(loc);
    for (const k of new Set(keys)) {
      assert.equal(typeof L[k], 'string', `${loc} has ${k}`);
      assert.ok(L[k].trim(), `${loc} ${k} is not empty`);
      for (const ph of (en[k].match(/\{[a-z]+\}/g) || [])) assert.ok(L[k].includes(ph), `${loc} ${k} keeps ${ph}`);
    }
  }
});
