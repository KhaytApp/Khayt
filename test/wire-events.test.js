const { test } = require('node:test');
const assert = require('node:assert/strict');

test('KhaytWireEvents exports initialRender and wireEvents', () => {
  const wire = require('../renderer/wire-events.js');
  assert.equal(typeof wire.initialRender, 'function');
  assert.equal(typeof wire.wireEvents, 'function');
});
