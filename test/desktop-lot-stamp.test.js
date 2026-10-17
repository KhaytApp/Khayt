/**
 * The desktop's two draws that do not go through lib/order-deduction.js —
 * a spool switched in partway through a job, and a test print — stamp the
 * spool's lot the same way the shared draws do.
 *
 * Without it, a recall still finds those rows (lib/lot-trace.js falls back to
 * the spool's CURRENT lot), but marks them `inferred`, and gets them wrong
 * once the shop edits the spool's lot.
 *
 * Comments are stripped before matching, so the prose here cannot satisfy
 * an assertion meant for the code.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const decomment = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

const { lotStamp } = require('../lib/order-deduction.js');
const Trace = require('../lib/lot-trace.js');

test('the spool switch stamps the lot on the row it writes', () => {
  const src = decomment(read('renderer/order-flows.js'));
  assert.ok(/invItem\.usageHistory\.unshift\(Object\.assign\(\{ orderId: order\.id[^\n]*\},\s*KhaytOrderDeduction\.lotStamp\(invItem\)\)\)/.test(src),
    'the spool-switch row is written without the lot stamp');
});

test('a test print stamps the lot on the row it writes', () => {
  const src = decomment(read('renderer/inventory.js'));
  assert.ok(/item\.usageHistory\.unshift\(Object\.assign\(\{ orderId: newTp\.id[^\n]*\},\s*Deduction\(\)\.lotStamp\(item\)\)\)/.test(src),
    'the test-print row is written without the lot stamp');
});

test('both pages load order-deduction before the scripts that call it', () => {
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) {
    const html = read(page);
    const lib = html.indexOf('<script src="../lib/order-deduction.js"></script>');
    const inv = html.indexOf('<script src="inventory.js"></script>');
    assert.ok(lib >= 0 && inv > lib, page);
  }
});

test('a stamped row stays on its lot after the spool is relabelled', () => {
  const spool = { id: 'sp1', lot: ' 2406-A ', poId: 'PO-7', weight: 800 };
  // What the spool-switch handler writes.
  spool.usageHistory = [Object.assign(
    { orderId: 'O1', project: 'Bracket', weightUsed: 40, date: '2026-10-17' }, lotStamp(spool))];
  spool.lot = '2410-B';
  const book = { printLog: [{ id: 'O1', project: 'Bracket' }], inventory: [spool] };

  const [d] = Trace.allDraws(book);
  assert.equal(d.lot, '2406-A');
  assert.equal(d.inferred, false);
  assert.equal(d.poId, 'PO-7');
  assert.deepEqual(Trace.jobsForLot(book, '2406-a').map((j) => j.orderId), ['O1']);
  assert.equal(Trace.jobsForLot(book, '2410-B').length, 0);
});

test('a spool with no lot writes exactly the row it wrote before', () => {
  const row = Object.assign(
    { orderId: 'TP1', project: 'Test print (temp)', weightUsed: 12, date: '2026-10-17' },
    lotStamp({ id: 'sp2', lot: '   ' }));
  assert.deepEqual(Object.keys(row), ['orderId', 'project', 'weightUsed', 'date']);
});
