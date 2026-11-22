const { test } = require('node:test');
const assert = require('node:assert/strict');
const settings = require('../renderer/settings.js');

test('KhaytSettings exports core settings tab functions', () => {
  for (const name of [
    'loadSettingsIntoForm',
    'saveSettingsFromForm',
    'saveSettingsFromPanel',
    'renderZatcaPhase2Settings',
    'renderLanApiSettings',
    'exportData',
    'importData',
    'resetAllData',
    'fullWipeData',
    'renderSecuritySettings',
  ]) {
    assert.equal(typeof settings[name], 'function', name);
  }
});
