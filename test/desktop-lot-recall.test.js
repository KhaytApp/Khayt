/**
 * Lot recall on the desktop: the spool history shows each use's lot, and
 * "Lot recall" lists every job a lot went into (lib/lot-trace.js decides
 * which; the renderer only draws it).
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

const inv = decomment(read('renderer/inventory.js'));
const wire = decomment(read('renderer/wire-events.js'));
const PAGES = ['renderer/index.html', 'renderer/bedready.html'];

test('both pages load lot-trace before inventory.js, and have the button', () => {
  for (const page of PAGES) {
    const html = read(page);
    const lib = html.indexOf('<script src="../lib/lot-trace.js"></script>');
    const invAt = html.indexOf('<script src="inventory.js"></script>');
    assert.ok(lib >= 0, `${page} never loads lib/lot-trace.js`);
    assert.ok(invAt > lib, `${page} loads inventory.js before lib/lot-trace.js`);
    assert.match(html, /id="btnLotRecall"/, `${page} has no Lot recall button`);
  }
  assert.match(wire, /\$\('#btnLotRecall'\)\?\.addEventListener\('click', \(\) => openLotRecall\(\)\)/);
});

test('openLotRecall and lotRecallJobs are exported to the page', () => {
  const api = inv.slice(inv.lastIndexOf('const api'));
  assert.match(api, /\bopenLotRecall,/);
  assert.match(api, /\blotRecallJobs,/);
});

test('the recall asks lib/lot-trace.js, not its own copy of the rule', () => {
  const body = inv.slice(inv.indexOf('function lotRecallJobs'), inv.indexOf('function openLotRecall'));
  assert.match(body, /LotTrace\(\)\.jobsForLot\(/);
  // Desktop jobs carry clientId; without this the Client column is blank.
  assert.match(body, /o\.clientId/);
  const open = inv.slice(inv.indexOf('function openLotRecall'));
  assert.match(open, /T\.knownLots\(/);
  assert.match(open, /T\.csvForJobs\(jobs\)/);
});

test('spool history shows each row\'s lot, and the spool\'s lot opens the recall', () => {
  const hist = inv.slice(inv.indexOf('function openSpoolHistory'), inv.indexOf('function _closeModal'));
  assert.match(hist, /escapeHtml\(h\.lot \|\| ''\)/);
  assert.match(hist, /openLotRecall\(item\.lot\)/);
});

test('a receipt row does not count against "Total consumed"', () => {
  // Purchase-order receipts are rows of MINUS what arrived; summing them made
  // consumption go down every time a delivery was booked in.
  const hist = inv.slice(inv.indexOf('function openSpoolHistory'), inv.indexOf('function _closeModal'));
  assert.match(hist, /Math\.max\(0, \+h\.weightUsed \|\| 0\)/);
});
