'use strict';
const test = require('node:test');
const assert = require('node:assert');
const m = require('../lib/saved-reports.js');

test('a store with junk in it still renders a list', () => {
  const list = m.savedReports({ savedReports: [
    { id: 'R1', name: 'Monthly VAT', fields: ['id', 'price'] },
    null, 'nope', { name: 'no id' }, { id: 'R2' }, { id: 'R1', name: 'duplicate id' },
  ] });
  assert.deepEqual(list.map((r) => r.id), ['R1']);
  // The shape is complete even where the stored row was not, so a screen never
  // has to ask whether `statusIn` is an array this time.
  assert.deepEqual(list[0].statusIn, []);
  assert.equal(list[0].from, '');
});

test('no savedReports at all is an empty list, not a throw', () => {
  assert.deepEqual(m.savedReports(undefined), []);
  assert.deepEqual(m.savedReports({}), []);
  assert.deepEqual(m.savedReports({ savedReports: 'yes' }), []);
});

test('saving under a name already used replaces it, keeping its id and place', () => {
  let list = m.addReport([], { name: 'Monthly VAT', fields: ['id'] }, 'R1');
  list = m.addReport(list, { name: 'Quotes out', fields: ['id'] }, 'R2');
  // Same name, different case, different columns — the correction a shop makes
  // after running the report once and seeing a column missing.
  list = m.addReport(list, { name: 'monthly vat', fields: ['id', 'balance'] }, 'R9');
  assert.equal(list.length, 2, 'a re-save appended instead of replacing');
  assert.equal(list[0].id, 'R1', 'the id moved, so anything holding it is now broken');
  assert.deepEqual(list[0].fields, ['id', 'balance']);
  assert.equal(list[0].name, 'monthly vat');
  assert.equal(list[1].id, 'R2', 'the replacement reordered the list');
});

test('a report with no name is not saved', () => {
  assert.deepEqual(m.addReport([], { name: '   ', fields: ['id'] }, 'R1'), []);
  assert.deepEqual(m.addReport([], {}, 'R1'), []);
});

test('one can be removed, and removing it twice is not an error', () => {
  let list = m.addReport([], { name: 'A', fields: ['id'] }, 'R1');
  list = m.addReport(list, { name: 'B', fields: ['id'] }, 'R2');
  list = m.removeReport(list, 'R1');
  assert.deepEqual(list.map((r) => r.id), ['R2']);
  assert.deepEqual(m.removeReport(list, 'R1').map((r) => r.id), ['R2']);
});

test('the list is never mutated in place', () => {
  const list = m.addReport([], { name: 'A', fields: ['id'] }, 'R1');
  const before = JSON.stringify(list);
  m.addReport(list, { name: 'B', fields: ['id'] }, 'R2');
  m.removeReport(list, 'R1');
  assert.equal(JSON.stringify(list), before);
});

test('dates are stored as days, whatever was handed in', () => {
  const list = m.addReport([], {
    name: 'A', fields: ['id'], from: '2026-09-01T10:22:00.000Z', to: '2026-09-30',
  }, 'R1');
  assert.equal(list[0].from, '2026-09-01');
  assert.equal(list[0].to, '2026-09-30');
});

test('findReport returns null rather than undefined for one that is gone', () => {
  const list = m.addReport([], { name: 'A', fields: ['id'] }, 'R1');
  assert.equal(m.findReport(list, 'R1').name, 'A');
  assert.equal(m.findReport(list, 'R404'), null);
  assert.equal(m.findReport([], 'R1'), null);
});
