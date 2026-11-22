/**
 * Kits, as wired into the print log.
 *
 * lib/print-kits.js is where the totalling is tested. What can only go wrong
 * here is the plumbing, and three of those failures are quiet enough to ship:
 *
 *   1. A kit that does not survive a Settings save. `settings` is REBUILT from
 *      the form by saveSettingsFromForm(), so anything written elsewhere is
 *      dropped unless it is carried across explicitly — silently, on the next
 *      unrelated visit to Settings. printLibrary carries a comment about exactly
 *      this; kits is the second field to need it.
 *   2. A rollup shown without saying how much of it was measured. The whole
 *      point of lib/print-kits.js is that a total can omit jobs; printing the
 *      total and hiding the count puts the bug back at the last step.
 *   3. A button wired to a function the other IIFE cannot see, or a listener
 *      bound to a node that is re-rendered out from under it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const logs = read('renderer/logs.js');
const settingsJs = read('renderer/settings.js');
const wire = read('renderer/wire-events.js');
const html = read('renderer/index.html');
const brHome = read('renderer/bedready-home.js');
const brHtml = read('renderer/bedready.html');

test('a kit survives a Settings save', () => {
  // The Settings save rebuilds the record from the form. A kit is created by
  // the log's batch bar and has no field on that page, so unless the rule
  // carries it across, it is dropped the next time anyone saves Settings for
  // an unrelated reason. The rule is lib/settings-edit.js now (it was a literal
  // in settings.js), so this asks the rule rather than reading the source.
  require('../lib/tax.js');
  const { apply } = require('../lib/settings-edit.js');
  const kits = [{ id: 'k1', name: 'Kings', jobs: ['J1'] }];
  const after = apply({ kits }, { phone: '050' }, { year: 2026 });
  assert.deepEqual(after.kits, kits,
    'kits are not carried across the settings rebuild — they vanish on the next Settings save');
  assert.deepEqual(apply({}, {}, { year: 2026 }).kits, [], 'and a shop with none gets the empty list its readers expect');
});

test('the rollup never shows a total without saying what is behind it', () => {
  const at = logs.indexOf('function renderKitStrip(');
  const body = logs.slice(at, logs.indexOf('\n}', at));
  assert.match(body, /r\.measuredTime < r\.jobs/,
    'a partly-measured kit is displayed as if every job counted');
  assert.match(body, /mixedCurrency/, 'two currencies would be shown added together');
});

test('the strip reads the tested module rather than totalling inline', () => {
  // A second implementation of the sum is a second place for the null bug.
  const at = logs.indexOf('function renderKitStrip(');
  const body = logs.slice(at, logs.indexOf('\n}', at));
  assert.match(body, /KhaytPrintKits\.groupByKit\(printLog, settings\.kits/);
  assert.doesNotMatch(body, /reduce\(/, 'the strip totals things itself instead of using the module');
});

test('the module is actually loaded, or the strip is dead on arrival', () => {
  assert.match(html, /<script src="\.\.\/lib\/print-kits\.js"><\/script>/,
    'lib/print-kits.js is never loaded, so KhaytPrintKits is undefined at render time');
});

test('the strip is guarded for the flavour that does not load the module', () => {
  // bedready.html does not ship logs-tab and does not load this lib. The guard
  // is what stops a ReferenceError if renderLogs is ever reached there.
  const at = logs.indexOf('function renderKitStrip(');
  const body = logs.slice(at, logs.indexOf('\n}', at));
  assert.match(body, /typeof KhaytPrintKits === 'undefined'/, 'no guard for a shell without the module');
});

test('every kit control is wired to something that exists and is exported', () => {
  assert.match(html, /id="btnBatchKit"/, 'the batch-bar button is not in the markup');
  assert.match(html, /id="kitStrip"/, 'the strip has nowhere to render');
  assert.match(wire, /#btnBatchKit'\)\?\.addEventListener/, 'a dead button');
  // The strip is re-rendered on every renderLogs(), so per-button listeners
  // would be lost on the next draw — the disband click has to be delegated.
  assert.match(wire, /#kitStrip'\)\?\.addEventListener\('click'/,
    'disband is bound to buttons that get replaced on the next render');
  const at = logs.indexOf('const api = {');
  assert.ok(at > -1, "logs.js's export object moved — this check is anchored on it");
  const api = logs.slice(at, at + 1600);
  for (const fn of ['batchAddToKit', 'renderKitStrip', 'disbandKit']) {
    assert.match(logs, new RegExp(`function ${fn}\\(`), `${fn} is not defined`);
    assert.match(api, new RegExp(`\\b${fn},`), `${fn} is not exported — its control does nothing`);
  }
});

test('the strip is drawn whenever the log is', () => {
  const at = logs.indexOf('function renderLogs(');
  const body = logs.slice(at, logs.indexOf('\n}\n', at));
  assert.ok(body.includes('renderKitStrip()'), 'the strip only appears if something else redraws it');
});

test('disbanding a kit does not touch the prints', () => {
  const at = logs.indexOf('async function disbandKit(');
  const body = logs.slice(at, logs.indexOf('\n}', at));
  assert.match(body, /delete o\.kitId/, 'jobs keep pointing at a kit that no longer exists');
  assert.doesNotMatch(body, /printLog\s*=\s*|splice\(|\.filter\(\(o\)/,
    'disbanding removes print-log entries — it must only unfile them');
  assert.match(body, /confirmModal/, 'a kit is disbanded with no confirmation');
});

test('a job in a deleted kit still shows as filed', () => {
  // groupByKit keeps orphans; the row badge has to agree, or the same job reads
  // as "in a kit" in the strip and "not in one" in the table.
  assert.match(logs, /log\.kitId\s*\n?\s*\?/, 'the badge is keyed on the definition rather than the link');
  assert.match(logs, /kitOf \? kitOf\.name : \(t\('kit\.orphaned'\)/,
    'an orphaned job shows a blank badge instead of saying the kit is gone');
});

test('two kits are not created for the same name', () => {
  // The rule used to be an inline string comparison here AND another one in
  // bedready-home.js, and the two copies had already drifted over what to do
  // about a clash. It now lives in lib/print-kits.js, where it has tests of its
  // own — so what this guards is that both call sites still go through it rather
  // than growing a third opinion.
  const at = logs.indexOf('async function batchAddToKit(');
  const body = logs.slice(at, logs.indexOf('\n}\n', at));
  assert.match(body, /resolveKitName\(/,
    'the print log mints kits without asking which one the name means');
  assert.match(brHome, /resolveKitName\(/,
    'BedReady mints kits without asking which one the name means');
});

test('adding to a kit that already exists is a pick, not a retype', () => {
  // The case kits are FOR is retroactive: three parts filed last week, the
  // fourth printed today. Asking for the name again is asking the shop to
  // reproduce a string from memory, and a near miss does not fail loudly — it
  // quietly splits the rollup.
  assert.match(html, /id="batchKitSelect"/, 'no way to choose a kit that already exists');
  assert.match(logs, /#batchKitSelect/, 'the picker is in the markup but nothing reads it');

  const at = logs.indexOf('function renderBatchBar(');
  const body = logs.slice(at, logs.indexOf('\n}\n', at));
  assert.match(body, /settings\.kits/, 'the picker is never populated from the shop’s kits');
});

test('a job can be taken back out of a kit without disbanding it', () => {
  // Grouping after the fact means grouping the wrong thing sometimes. Disbanding
  // the whole kit to correct ONE job is why anyone would leave it wrong.
  const at = logs.indexOf('async function batchAddToKit(');
  const body = logs.slice(at, logs.indexOf('\n}\n', at));
  assert.match(body, /delete o\.kitId/, 'nothing removes a single job from its kit');
  assert.match(body, /emptyKitIds\(/,
    'removing the last job leaves a kit name attached to nothing');
});

test('the section is translated everywhere, placeholders intact', () => {
  const keys = ['kit.add_to', 'kit.name_prompt', 'kit.jobs', 'kit.measured', 'kit.vs_estimate',
    'kit.mixed_currency', 'kit.orphaned', 'kit.disband', 'kit.disband_confirm', 'kit.disbanded',
    'kit.opt_new', 'kit.opt_remove', 'kit.near_confirm'];
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const loc = read(`renderer/locales/${code}.js`);
    for (const k of keys) assert.ok(loc.includes(`"${k}":`), `${code} is missing ${k}`);
    const line = loc.split('\n').find((l) => l.includes('"kit.disband_confirm"'));
    assert.ok(line.includes('{name}'), `${code}'s kit.disband_confirm dropped {name}`);
    // Both placeholders matter: the confirm names the kit it would use AND the
    // one it would otherwise create, and a translation that drops either leaves
    // the shop agreeing to something it cannot see.
    const near = loc.split('\n').find((l) => l.includes('"kit.near_confirm"'));
    assert.ok(near.includes('{name}') && near.includes('{typed}'),
      `${code}'s kit.near_confirm dropped a placeholder`);
  }
});

test('the Bed Ready card is guarded and loaded, and declares its own helpers', () => {
  // Only reachable by source: the running Bed Ready app always loads the module,
  // so its e2e cannot exercise the undefined branch. Everything else about this
  // card is driven for real in scripts/e2e-bedready-smoke.mjs.
  const at = brHome.indexOf('function kitsHtml(');
  assert.ok(at > -1, 'kitsHtml went missing');
  const body = brHome.slice(at, brHome.indexOf('\n  function ', at + 10));
  assert.match(body, /typeof KhaytPrintKits === 'undefined'/,
    'no guard — a shell without the module would throw while drawing the home');
  // `esc` is not file-scoped in bedready-home.js and `tr` does not exist in it.
  // Assuming either takes the whole home down with a ReferenceError.
  assert.match(body, /var esc = \(typeof escapeHtml === 'function'\)/, 'esc is assumed rather than declared');
  assert.match(body, /var tr = function \(key, fallback\)/, 'tr is assumed rather than declared');
  assert.match(brHtml, /<script src="\.\.\/lib\/print-kits\.js"><\/script>/,
    'the Bed Ready shell never loads the module');
});

test('a part finished after the kit was made can still be added to it', () => {
  // Found by driving the tray rather than reading it: the threshold was ">= 2
  // unfiled prints", so the ordinary case — group what you have, then the last
  // part finishes — left that part with nowhere to go.
  const at = brHome.indexOf('function kitsHtml(');
  const body = brHome.slice(at, brHome.indexOf('\n  function ', at + 10));
  assert.match(body, /done\.length >= \(g\.kits\.length \? 1 : 2\)/,
    'a single unfiled print cannot be added to an existing kit');
});

test('rename refuses a name another kit already holds', () => {
  // "Reuse the kit with this name" is an ADD rule — the shop has just chosen
  // which jobs are involved. Applying it to rename would move somebody else's
  // jobs on the strength of a typo.
  const at = logs.indexOf('async function renameKit(');
  assert.ok(at > -1, 'renameKit went missing');
  const body = logs.slice(at, logs.indexOf('\n}', at));
  assert.match(body, /k\.id !== kitId\s*\n?\s*&& String\(k\.name\)\.trim\(\)\.toLowerCase\(\) === clean\.toLowerCase\(\)/,
    'renaming onto an existing name is allowed, so two kits share it');
  assert.match(body, /if \(clash\) \{[\s\S]{0,200}return;/, 'the clash is detected and then ignored');
});

test('renaming an orphan adopts it rather than leaving it unnameable', () => {
  // groupByKit keeps orphans on purpose. Without this branch a kit whose
  // definition was deleted can never be named again — the jobs are stuck.
  const at = logs.indexOf('async function renameKit(');
  const body = logs.slice(at, logs.indexOf('\n}', at));
  assert.match(body, /else settings\.kits = kits\.concat\(\[\{ id: kitId, name: clean \}\]\)/,
    'an orphan rename writes nothing, so the name is silently discarded');
});

test('rename is wired on both surfaces, and delegated in the log', () => {
  assert.match(logs, /data-kit-rename=/, 'no rename control on the log strip');
  assert.match(wire, /data-kit-rename\]'\)\?\.dataset\?\.kitRename/, 'the log rename is not handled');
  const api = logs.slice(logs.indexOf('const api = {'), logs.indexOf('const api = {') + 1700);
  assert.match(api, /\brenameKit,/, 'renameKit is not exported — a dead button');
  assert.match(brHome, /data-kit-rename/, 'no rename control on the Bed Ready card');
});

test('the rename strings are translated everywhere', () => {
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const loc = read(`renderer/locales/${code}.js`);
    for (const k of ['kit.rename', 'kit.rename_prompt', 'kit.renamed', 'kit.name_taken']) {
      assert.ok(loc.includes(`"${k}":`), `${code} is missing ${k}`);
    }
    const line = loc.split('\n').find((l) => l.includes('"kit.name_taken"'));
    assert.ok(line.includes('{name}'), `${code}'s kit.name_taken dropped {name}`);
  }
});
