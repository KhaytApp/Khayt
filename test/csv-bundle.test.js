'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildCsvBundle } = require('../lib/csv-bundle.js');

test('builds one CSV per non-empty known collection, skips empty/unknown', () => {
  const files = buildCsvBundle({
    printLog: [{ id: 'O1', date: '2026-06-23', project: 'Sara', price: 120, status: 'done' }],
    clients: [{ id: 'C1', nameEn: 'Sara', phone: '+966500' }],
    inventory: [],            // empty → skipped
    foobar: [{ id: 'x' }],    // unknown → skipped
  });
  const names = files.map((f) => f.name).sort();
  assert.deepEqual(names, ['clients.csv', 'orders.csv']);
});

test('orders.csv has a header + one row per order; arrays joined', () => {
  const [orders] = buildCsvBundle({
    printLog: [{ id: 'O1', date: '2026-06-23', client: 'Sara', project: 'Phone stands', price: 120, status: 'done', tags: ['rush', 'vip'] }],
  });
  const lines = orders.content.replace(/^﻿/, '').split('\r\n');
  assert.equal(lines.length, 2);
  assert.match(lines[0], /^"ID","Date","Client","Project"/);
  assert.match(lines[1], /"rush, vip"/); // tags array joined
  assert.match(lines[1], /"Sara","Phone stands"/); // the customer, then the job
});

test('cells are quoted, quote-escaped, and formula-neutralized', () => {
  const [clients] = buildCsvBundle({
    clients: [{ id: 'C1', nameEn: '=cmd()', notes: 'he said "hi"\nbye' }],
  });
  const body = clients.content;
  assert.match(body, /"'=cmd\(\)"/);        // leading = neutralized with '
  assert.match(body, /"he said ""hi"" bye"/); // quotes doubled, newline → space
});

test('empty snapshot → no files', () => {
  assert.deepEqual(buildCsvBundle({}), []);
  assert.deepEqual(buildCsvBundle(), []);
});

/* ── EVERY COLUMN MUST BE READ FROM A FIELD THE APP ACTUALLY WRITES ───────
 *
 * The tests above used to hand this module records shaped the way the module
 * happened to read them — `{ name: 'Sara' }` for a customer — so they passed
 * while a real export came out with an empty Name column in every row. The
 * fixture cannot catch that: the fixture is the thing that is wrong.
 *
 * These drive it with records shaped the way Khayt writes them, taken from
 * what `lib/sample-data.js` seeds and what the store actually holds.
 */
const cellsOf = (file) => file.content.replace(/^﻿/, '').split('\r\n')[1]
  .split('","').map((c) => c.replace(/^"|"$/g, ''));
const columnOf = (file, heading) => {
  const headers = file.content.replace(/^﻿/, '').split('\r\n')[0]
    .split('","').map((c) => c.replace(/^"|"$/g, ''));
  return cellsOf(file)[headers.indexOf(heading)];
};

test("a customer's name reaches the file, whichever language it is written in", () => {
  const [both] = buildCsvBundle({ clients: [{ id: 'C1', nameEn: 'Layla Design Studio', nameAr: 'استوديو ليلى' }] });
  assert.equal(columnOf(both, 'Name'), 'Layla Design Studio');
  // Written in Arabic alone is still written down; an empty cell would say it
  // was not.
  const [arabic] = buildCsvBundle({ clients: [{ id: 'C2', nameAr: 'مختبر الخليج' }] });
  assert.equal(columnOf(arabic, 'Name'), 'مختبر الخليج');
});

test('a shop that writes neither English nor Arabic still gets its names', () => {
  /* The obvious repair for the blank Name column — `nameEn || nameAr` — is the
   * shape `test/content-languages.test.js` forbids by name, and it is blank for
   * a shop working in German or Turkish. The shop's own content-language rule
   * answers it instead, so this is the case that says the repair was the right
   * one rather than the near one.
   */
  const [clients] = buildCsvBundle({
    settings: { contentLangs: ['de'] },
    clients: [{ id: 'C1', name_de: 'Muster Werkstatt' }],
  });
  assert.equal(columnOf(clients, 'Name'), 'Muster Werkstatt');

  // And English is only ASKED for, never imposed: a shop that does not write it
  // is not handed a stale English field left over from setup.
  const [mixed] = buildCsvBundle({
    settings: { contentLangs: ['ar'] },
    clients: [{ id: 'C2', nameEn: 'Old Setup Name', nameAr: 'مختبر الخليج' }],
  });
  assert.equal(columnOf(mixed, 'Name'), 'مختبر الخليج');
});

test("a spool's grams are what is left and what it held new", () => {
  // `weight` and `spoolWeight` are what the shelf writes; `remaining`/`total`
  // are written by nothing, and reading them emptied both columns.
  const [shelf] = buildCsvBundle({
    inventory: [{ id: 'sp-1', material: 'PLA+', colourVariant: 'Black', weight: 860, spoolWeight: 1000, cost: 75, storage: 'Dry box A' }],
  });
  assert.equal(columnOf(shelf, 'Remaining (g)'), '860');
  assert.equal(columnOf(shelf, 'Total (g)'), '1000');
  assert.equal(columnOf(shelf, 'Cost'), '75');
  assert.equal(columnOf(shelf, 'Color'), 'Black');
  assert.equal(columnOf(shelf, 'Location'), 'Dry box A');
});

test("a product's name and the price it sells at", () => {
  const [products] = buildCsvBundle({
    products: [{ id: 'P1', nameEn: 'Desk Phone Stand', category: 'Office', basePrice: 35 }],
  });
  assert.equal(columnOf(products, 'Name'), 'Desk Phone Stand');
  assert.equal(columnOf(products, 'Price'), '35');
  // A price the shop typed over the worked-out one is what it actually sells
  // for, so it wins.
  const [over] = buildCsvBundle({
    products: [{ id: 'P2', nameEn: 'Helmet', basePrice: 320, priceOverride: 295 }],
  });
  assert.equal(columnOf(over, 'Price'), '295');
});

test('what a job is printed in comes off its parts', () => {
  // An order carries no `material`: the parts do, one each.
  const [orders] = buildCsvBundle({
    printLog: [{ id: 'O1', date: '2026-09-01', client: 'Acme', project: 'Bracket',
                 parts: [{ material: 'PETG-CF' }, { material: 'PLA+' }, { material: 'PETG-CF' }] }],
  });
  assert.equal(columnOf(orders, 'Material'), 'PETG-CF, PLA+'); // once each, in order
});

test("a machine's model is the field the app writes", () => {
  const [machines] = buildCsvBundle({
    machines: [{ id: 'M1', name: 'Bench', printerModelName: 'Bambu Lab A1' }],
  });
  assert.equal(columnOf(machines, 'Model'), 'Bambu Lab A1');
  // The demo data's spelling still works, behind it.
  const [demo] = buildCsvBundle({ machines: [{ id: 'M2', name: 'Ender', model: 'Creality Ender 3 V3' }] });
  assert.equal(columnOf(demo, 'Model'), 'Creality Ender 3 V3');
});

test('the demo shop a new install seeds exports with its columns filled', () => {
  // End to end against the data Khayt itself writes on first run. If a field
  // is renamed on either side, this is what says so.
  const { buildSampleData } = require('../lib/sample-data.js');
  const files = buildCsvBundle(buildSampleData());
  const byName = Object.fromEntries(files.map((f) => [f.name, f]));
  assert.ok(byName['clients.csv'] && byName['orders.csv'] && byName['inventory.csv']);
  assert.notEqual(columnOf(byName['clients.csv'], 'Name'), '');
  assert.notEqual(columnOf(byName['products.csv'], 'Name'), '');
  assert.notEqual(columnOf(byName['products.csv'], 'Price'), '');
  assert.notEqual(columnOf(byName['inventory.csv'], 'Remaining (g)'), '');
  assert.notEqual(columnOf(byName['machines.csv'], 'Model'), '');
});
