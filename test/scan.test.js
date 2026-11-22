/**
 * Scan-code router. Pure classification of scanned/typed strings into Khayt
 * actions (spool / order / track) with a fall-through to filament parsing.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseScanCode } = require('../lib/scan.js');

test('spool label code → { type: spool, id }', () => {
  assert.deepEqual(parseScanCode('KHAYT-SPOOL:INV-123'), { type: 'spool', id: 'INV-123' });
  assert.deepEqual(parseScanCode('  khayt-spool:abc  '), { type: 'spool', id: 'abc' }); // trim + case-insensitive
});

test('order label code → { type: order, id }', () => {
  assert.deepEqual(parseScanCode('KHAYT-ORDER:INV-2026-0007'), { type: 'order', id: 'INV-2026-0007' });
});

test('customer tracking URL → { type: track, token }', () => {
  assert.deepEqual(parseScanCode('https://cloud.khaytapp.com/p/abc123def'), { type: 'track', token: 'abc123def' });
  assert.deepEqual(parseScanCode('https://cloud.khaytapp.com/p/abc123def/'), { type: 'track', token: 'abc123def' });
});

test('empty + unknown', () => {
  assert.deepEqual(parseScanCode('   '), { type: 'empty' });
  assert.deepEqual(parseScanCode('eSun PLA+ Black 1kg'), { type: 'unknown', raw: 'eSun PLA+ Black 1kg' });
});
