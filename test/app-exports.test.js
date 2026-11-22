const { test } = require('node:test');
const assert = require('node:assert/strict');

test('KhaytAppExports exports document export helpers', () => {
  const exp = require('../renderer/app-exports.js');
  assert.equal(typeof exp.maybeAutoBackup, 'function');
  assert.equal(typeof exp.updateLastBackupDisplay, 'function');
  assert.equal(typeof exp.exportQuoteApprovalPage, 'function');
  assert.equal(typeof exp.openMilestoneInvoices, 'function');
  assert.equal(typeof exp.generateWorkOrder, 'function');
});
