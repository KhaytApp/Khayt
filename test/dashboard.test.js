const { test } = require('node:test');
const assert = require('node:assert/strict');
const { studioSparkSvg, renderDashboard } = require('../renderer/dashboard.js');

test('studioSparkSvg renders polyline from numeric series', () => {
  const svg = studioSparkSvg([10, 20, 5], 120, 24, '#5b9cf0');
  assert.match(svg, /<polyline/);
  assert.match(svg, /points="/);
});

test('KhaytDashboard exports main render entry points', () => {
  assert.equal(typeof renderDashboard, 'function');
  assert.equal(typeof studioSparkSvg, 'function');
});
