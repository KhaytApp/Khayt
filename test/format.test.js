const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  num,
  clampPositive,
  fmtMoney,
  computeUnitPrice,
  csvFormulaNeutralize,
} = require('../renderer/format.js');

test('num parses numbers and falls back', () => {
  assert.equal(num('12.5'), 12.5);
  assert.equal(num('x', 3), 3);
  assert.equal(num(NaN, 1), 1);
});

test('clampPositive floors at zero', () => {
  assert.equal(clampPositive(-5), 0);
  assert.equal(clampPositive('2'), 2);
});

test('fmtMoney rounds to two decimals', () => {
  assert.equal(fmtMoney(10.456), '10.46');
  assert.equal(fmtMoney(null), '0.00');
});

test('computeUnitPrice prefers unitPrice then amount/qty', () => {
  assert.equal(computeUnitPrice({ unitPrice: 5, amount: 100, quantity: 10 }), 5);
  assert.equal(computeUnitPrice({ amount: 100, quantity: 4 }), 25);
  assert.equal(computeUnitPrice({ amount: 50 }), 50);
});

test('csvFormulaNeutralize prefixes dangerous cells', () => {
  assert.equal(csvFormulaNeutralize('=1+1'), "'=1+1");
  assert.equal(csvFormulaNeutralize('safe'), 'safe');
  assert.equal(csvFormulaNeutralize('+100'), "'+100");
});
