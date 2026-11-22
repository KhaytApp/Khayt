'use strict';
/**
 * Require this BEFORE lib/mf-convert so a test sees no installed Orca-family slicer.
 *
 * mf-convert overlays the installed Snapmaker Orca / OrcaSlicer machine and process presets
 * (applyOrcaNative). On a developer Mac with Snapmaker Orca in /Applications that overlay runs and
 * replaces the process settings a test pinned; on CI there is no slicer and it does not. Tests
 * that check the converter's own rules stub an empty profile DB so both machines agree.
 */
const path = require('node:path');

const stubPath = path.join(__dirname, '..', '..', 'lib', 'orca-db.js');
require.cache[require.resolve(stubPath)] = {
  id: stubPath, filename: stubPath, loaded: true,
  exports: {
    machineSettings: () => null,
    defaultProcessFor: () => null,
    resolvePreset: () => ({}),
  },
};
