const { test } = require('node:test');
const assert = require('node:assert/strict');
const { safeJsonParse } = require('../lib/safe-json');

test('parses valid JSON', () => {
  assert.deepEqual(safeJsonParse('{"a":1,"b":[2]}'), { a: 1, b: [2] });
});

test('strips __proto__ keys', () => {
  const before = Object.prototype.polluted;
  const obj = safeJsonParse('{"__proto__":{"polluted":true},"ok":1}');
  assert.equal(obj.ok, 1);
  assert.equal(Object.prototype.polluted, before);
  assert.equal('polluted' in obj, false);
});

test('strips constructor keys', () => {
  const obj = safeJsonParse('{"constructor":{"name":"x"},"x":1}');
  assert.equal(obj.x, 1);
  assert.equal(Object.hasOwn(obj, 'constructor'), false);
});

test('strips prototype keys', () => {
  const obj = safeJsonParse('{"prototype":{"evil":true},"ok":1}');
  assert.equal(obj.ok, 1);
  assert.equal(Object.hasOwn(obj, 'prototype'), false);
});

test('throws on invalid JSON', () => {
  assert.throws(() => safeJsonParse('{'), SyntaxError);
});
