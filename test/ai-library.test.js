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

// ── Loose files at the top of a linked folder ─────────────────────────────

const LOOSE = ['Kart Racer 3MF For Bambu Printers.3mf', 'Plate 2 - Red.stl', 'Plate 1 - Yellow.stl',
  'v7-QQ - holder.stl', 'v7-QQ - cover.stl', '412.jpg'];

test('loose files go as numbered names in copy order, nothing else', () => {
  const text = L.buildLooseRequest(LOOSE);
  const lines = text.split('\n');
  assert.equal(lines.length, LOOSE.length + 1);
  assert.equal(lines[1], '0 | Kart Racer 3MF For Bambu Printers.3mf');
  assert.equal(lines[3], '2 | Plate 1 - Yellow.stl');
  // A path is cut to its own name, and a name cannot break a line.
  const sneaky = L.buildLooseRequest(['/Users/x/My Drive/secret/a.stl', 'b\nc.stl', '..\\up.stl']);
  assert.deepEqual(sneaky.split('\n').slice(1), ['0 | a.stl', '1 | b c.stl', '2 | up.stl']);
});

test('a loose request holds at most 300 names, each clipped', () => {
  assert.equal(L.LIMITS.looseNames, 300);
  assert.equal(L.LIMITS.looseNamesPerScan, 3000);
  const many = Array.from({ length: 450 }, (_, i) => `part ${i} ${'x'.repeat(200)}.stl`);
  const lines = L.buildLooseRequest(many).split('\n');
  assert.equal(lines.length, 301);
  for (const l of lines.slice(1)) assert.ok(l.split(' | ')[1].length <= L.LIMITS.looseNameLength);
});

test('loose prints are believed only where they can be', () => {
  const r = L.readLooseAnswer({ prints: [
    { name: 'Kart Racer', members: [0, 1, 2] },
    { name: 'v7-QQ', members: [3, 4] },
    { name: '..', members: [5, 3] },                 // dots name nothing
    { name: 'a/b', members: [3, 4] },                // a path, not a name
    { name: 'Far', members: [4, 99] },               // never sent
    { name: 'Again', members: [0, 3] },              // already in a print
    { name: 'Alone', members: [5] },                 // one file is not a print
    { name: 'Twice', members: [5, 5] },
    { name: 'Frac', members: [1.5, 2] },
  ] }, LOOSE.length);
  assert.deepEqual(r.prints, [{ name: 'Kart Racer', members: [0, 1, 2] }, { name: 'v7-QQ', members: [3, 4] }]);
  assert.equal(r.dropped, 7);
  for (const bad of [null, {}, { prints: 'x' }, { prints: [null, 1] }]) {
    assert.deepEqual(L.readLooseAnswer(bad, 3).prints, []);
  }
});

test('Check pictures: published limits, at most two images, verdicts read strictly', () => {
  assert.equal(L.LIMITS.pictureImages, 2);
  assert.equal(L.LIMITS.pictureChecksPerScan, 40);
  assert.equal(L.LIMITS.picturePixels, 512);
  assert.equal(L.LIMITS.pictureSourceBytes, 8 * 1024 * 1024);
  assert.equal(L.pictureImages('a', 'b').length, 2);
  assert.deepEqual(L.pictureImages('a', null).map((i) => i.mediaType), ['image/jpeg']);
  assert.equal(L.readPictureAnswer({ verdict: 'YES' }), 'yes');
  assert.equal(L.readPictureAnswer({ verdict: 'maybe' }), 'unsure');
  assert.equal(L.readPictureAnswer(null), 'unsure');
  assert.equal(L.pictureOutcome('yes', true), 'attach');
  assert.equal(L.pictureOutcome('yes', false), 'ticked');
  assert.equal(L.pictureOutcome('no', true), 'rejected');
  assert.equal(L.pictureOutcome('unsure', true), 'unticked');
  assert.match(L.buildPictureRequest('Kart\nRacer', true), /Print: Kart Racer\nImage 1/);
  const P = require('../lib/ai-providers.js');
  const req = P.buildRequest({ ai: { provider: 'anthropic', apiKey: 'k' } }, {
    system: 's', prompt: 'p', images: L.pictureImages('QQ', 'RR'),
    tool: { name: 't', description: 'd', input_schema: {} }, maxTokens: 10,
  });
  const imgs = req.body.messages[0].content.filter((c) => c.type === 'image');
  assert.equal(imgs.length, 2);
  assert.equal(imgs[0].source.media_type, 'image/jpeg');
  assert.equal(P.takesImages({ ai: { provider: 'compatible' } }), false);
  assert.equal(P.takesImages({ ai: { provider: 'google' } }), true);
});

test('the loose task frames itself as grouping files', () => {
  const t = L.looseTool();
  assert.equal(t.tool.name, 'group_loose_model_files');
  assert.equal(t.tool.input_schema, L.LOOSE_SCHEMA);
  assert.ok(t.maxTokens >= 8000);
  assert.match(L.buildLooseSystem(), /file NAMES only/);
});
