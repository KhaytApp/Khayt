'use strict';
/**
 * Sorting linked folders with the shop's assistant (lib/ai-library.js).
 *
 * Two promises are pinned here: what leaves the Mac is names and counts and
 * nothing else, and what comes back is believed only where it can be — a path
 * that was sent, a role that exists, a name a group can hold.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const L = require('../lib/ai-library.js');
const tools = require('../lib/ai-tools.js');

const ENTRIES = [
  { path: 'Aug26 Giga Tier', models: 0, folders: ['Aug26 Collectibles Tier'], samples: [] },
  { path: 'Aug26 Giga Tier/Aug26 Collectibles Tier/Call of Duty 4 ', models: 0,
    folders: ['Concert Poster', 'Mini Poster', 'RENDERS'], samples: [] },
  { path: 'Aug26 Giga Tier/Aug26 Collectibles Tier/Call of Duty 4 /Mini Poster', models: 2,
    folders: ['STLs'], samples: ['Base_2.stl', 'Frame.stl'] },
];

test('the request is folder paths, counts, sub-folder names and file names — nothing else', () => {
  const text = L.buildLibraryRequest(ENTRIES);
  assert.match(text, /Call of Duty 4 \/Mini Poster \| 2 \| STLs \| Base_2\.stl; Frame\.stl/);
  assert.equal(text.split('\n').length, ENTRIES.length + 1);
  // A name cannot break a line and smuggle in a second entry.
  const sneaky = L.buildLibraryRequest([{ path: 'A\nB | 99', models: 1, folders: [], samples: ['x\ny.stl'] }]);
  assert.equal(sneaky.split('\n').length, 2);
});

test('the request is bounded: folders, sub-folders and samples are capped', () => {
  const many = Array.from({ length: 400 }, (_, i) => ({
    path: `F${i}`, models: 1, folders: Array.from({ length: 90 }, (_, j) => `s${j}`),
    samples: Array.from({ length: 40 }, (_, j) => `m${j}.stl`),
  }));
  const lines = L.buildLibraryRequest(many).split('\n');
  assert.equal(lines.length, L.LIMITS.folders + 1);
  assert.equal(lines[1].split(' | ')[2].split('; ').length, L.LIMITS.subfolders);
  assert.equal(lines[1].split(' | ')[3].split('; ').length, L.LIMITS.samples);
});

test('an answer is kept only for paths that were sent and roles that exist', () => {
  const sent = ENTRIES.map((e) => e.path);
  const r = L.readLibraryAnswer({
    folders: [
      { path: sent[0], role: 'collection' },
      { path: sent[1], role: 'PRINT', name: 'Call of Duty 4' },
      { path: sent[2], role: 'part' },
      { path: 'Somewhere/Else', role: 'print', name: 'Invented' },   // never sent
      { path: sent[2], role: 'print' },                               // a second answer for one path
      { path: sent[0], role: 'banana' },
      { role: 'print' },
      null,
    ],
  }, sent);
  assert.deepEqual(r.roles, { [sent[0]]: 'collection', [sent[1]]: 'print', [sent[2]]: 'part' });
  assert.deepEqual(r.names, { [sent[1]]: 'Call of Duty 4' });
  assert.equal(r.dropped, 5);
});

test('nothing usable comes back as nothing, never as a throw', () => {
  for (const bad of [null, undefined, {}, { folders: 'x' }, { folders: [1, 2] }]) {
    const r = L.readLibraryAnswer(bad, ['a']);
    assert.deepEqual(r.roles, {});
    assert.deepEqual(r.names, {});
  }
});

test('a print name is one line a group can hold: no slash, no control characters, at most 60', () => {
  assert.equal(L.cleanName('Life Size / Buzz\nLightyear'), 'Life Size - Buzz Lightyear');
  const long = L.cleanName('Word '.repeat(30));
  assert.ok(long.length <= 60 && !long.endsWith(' '));
  assert.equal(L.cleanName('   '), '');
  // A group path segment of dots names nothing (alpha.67 review).
  for (const dots of ['..', '.', ' - ', '../..', '***']) assert.equal(L.cleanName(dots), '', dots);
  assert.equal(L.cleanName('درع'), 'درع', 'any script is a name');
  const r = L.readLibraryAnswer({ folders: [{ path: 'a', role: 'print', name: 'x/y' },
    { path: 'b', role: 'part', name: 'ignored for a part' }] }, ['a', 'b']);
  assert.deepEqual(r.names, { a: 'x - y' });
});

test('the task frames itself as sorting folders, with room for a long answer', () => {
  const t = tools.resolveTool('library', L.LIBRARY_SCHEMA);
  assert.equal(t.task, 'library');
  assert.equal(t.tool.name, 'sort_library_folders');
  assert.deepEqual(t.tool.input_schema.properties.folders.items.properties.role.enum, L.ROLES);
  assert.ok(t.maxTokens >= 16000);
  assert.match(L.buildLibrarySystem(), /PATHS and file NAMES only/);
});
