'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { localDayName, uniqueName, fileStamp } = require('../lib/safe-names');

test('the backup day is the LOCAL day, not the UTC one', () => {
  // 01:30 on the 24th in Riyadh is still the 23rd in UTC. The renderer compares
  // against the local day, so the file must be named for the 24th too.
  const d = new Date(2026, 8, 24, 1, 30);          // local time, whatever the zone
  assert.equal(localDayName(d), '2026-09-24');
  assert.equal(localDayName(new Date(2026, 0, 5, 23, 59)), '2026-01-05', 'zero-padded, and late evening stays on its day');
});

test('localDayName agrees with the renderer\'s own local-date rule', () => {
  // renderer/*: localDateStr() builds the same string from local components.
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  assert.equal(localDayName(d), `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`);
});

test('a free name is kept exactly', () => {
  assert.equal(uniqueName('part.stl', () => false), 'part.stl');
});

test('a taken name becomes name-2, then name-3', () => {
  const have = new Set(['part.stl']);
  assert.equal(uniqueName('part.stl', (n) => have.has(n)), 'part-2.stl');
  have.add('part-2.stl');
  assert.equal(uniqueName('part.stl', (n) => have.has(n)), 'part-3.stl');
});

test('only the last extension moves, and a dotfile keeps its name', () => {
  assert.equal(uniqueName('model.v2.3mf', (n) => n === 'model.v2.3mf'), 'model.v2-2.3mf');
  assert.equal(uniqueName('.env', (n) => n === '.env'), '.env-2');
  assert.equal(uniqueName('README', (n) => n === 'README'), 'README-2');
});

test('fileStamp carries no character a file system refuses', () => {
  assert.doesNotMatch(fileStamp(new Date('2026-09-24T01:02:03.456Z')), /[:.]/);
});
