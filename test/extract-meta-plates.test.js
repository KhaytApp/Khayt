'use strict';

/**
 * A multi-plate 3MF is priced as every plate, not the first.
 *
 * Found on a real two-plate Bambu/Orca file (Adiletten.3mf) by the Mac session:
 * extractMeta took the first <plate>'s prediction (655 min) while summing every
 * plate's filament (286.39 g), and model-intake priced one plate's hours against
 * two plates' grams.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const mf = require('../lib/mf-convert.js');

const member = (text) => [{ name: 'Metadata/slice_info.config', data: Buffer.from(text, 'utf8') }];
const plate = (index, secs, filaments, weight) => `
  <plate>
    <metadata key="index" value="${index}"/>
    <metadata key="prediction" value="${secs}"/>
    ${weight != null ? `<metadata key="weight" value="${weight}"/>` : ''}
    ${filaments.map((f) => `<filament id="${f.id}" type="${f.type}" color="#fff" used_m="1" used_g="${f.g}"/>`).join('\n    ')}
  </plate>`;

test('two plates: the time and the filament both cover both plates', () => {
  const xml = `<config>${plate(1, 655 * 60, [{ id: 1, type: 'PLA', g: 150.2 }])}${plate(2, 540 * 60, [{ id: 1, type: 'PLA', g: 136.19 }])}</config>`;
  const meta = mf.extractMeta(member(xml));
  assert.equal(meta.printMinutes, 655 + 540, 'only the first plate\'s time');
  assert.equal(meta.totalGrams, 286.4);
  assert.deepEqual(meta.plates, [
    { index: 1, printTimeMins: 655, filamentGrams: 150.2, filamentType: 'PLA' },
    { index: 2, printTimeMins: 540, filamentGrams: 136.2, filamentType: 'PLA' },
  ]);
});

test('one plate: unchanged, and no plates list', () => {
  const meta = mf.extractMeta(member(`<config>${plate(1, 7200, [{ id: 1, type: 'PETG', g: 40 }, { id: 2, type: 'PETG', g: 2.5 }])}</config>`));
  assert.equal(meta.printMinutes, 120);
  assert.equal(meta.totalGrams, 42.5);
  assert.equal(meta.plates, undefined);
});

test('a plate with no used_g falls back to its weight', () => {
  const xml = `<config>${plate(1, 600, [], 12.34)}${plate(2, 600, [{ id: 1, type: 'PLA', g: 5 }])}</config>`;
  const meta = mf.extractMeta(member(xml));
  assert.equal(meta.plates[0].filamentGrams, 12.3);
  assert.equal(meta.plates[0].filamentType, null);
  assert.equal(meta.printMinutes, 20);
  assert.equal(meta.totalGrams, 17.3, 'the total counts the plate that reported only its weight');
});

test('an older writer with no <plate> blocks still reads its prediction', () => {
  assert.equal(mf.extractMeta(member('<config><metadata key="prediction" value="3600"/></config>')).printMinutes, 60);
  assert.equal(mf.extractMeta(member('<config prediction="1800"></config>')).printMinutes, 30);
});
