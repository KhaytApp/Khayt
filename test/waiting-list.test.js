const { test } = require('node:test');
const assert = require('node:assert/strict');
const waiting = require('../renderer/waiting-list.js');

test('KhaytWaitingList exports job intake functions', () => {
  for (const name of [
    'renderWaitingList',
    'openWaitingItemEditor',
    'promoteWaitingItem',
    'updateWaitingBadge',
    'renderWaitingFunnel',
    'openReminderModal',
  ]) {
    assert.equal(typeof waiting[name], 'function', name);
  }
});
