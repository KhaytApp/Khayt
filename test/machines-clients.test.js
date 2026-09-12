const { test } = require('node:test');
const assert = require('node:assert/strict');

test('machineServiceStatus marks service due when interval exceeded', () => {
  global.printLog = [
    { machineId: 'M1', status: 'completed', printTime: 100 },
  ];
  global.machines = [{ id: 'M1', name: 'Test', serviceInterval: 50, lastServiceHours: 0 }];
  // index.html loads this as a <script>, which is what defines the global the
  // hour meter reads. Requiring it here does the same thing, so the test
  // exercises the shared rule rather than a stand-in for it.
  require('../lib/maintenance.js');
  const { machineServiceStatus } = require('../renderer/machines.js');
  const svc = machineServiceStatus(global.machines[0]);
  assert.equal(svc.due, true);
});

test('getClientTier returns highest qualifying loyalty tier', () => {
  require('../renderer/currency.js');
  global.settings = {
    loyaltyEnabled: true,
    loyaltyTiers: [
      { name: 'Bronze', minOrders: 1, minSpend: 0 },
      { name: 'Gold', minOrders: 5, minSpend: 0 },
    ],
  };
  global.printLog = Array.from({ length: 5 }, (_, i) => ({
    id: `o${i}`,
    clientId: 'C1',
    status: 'completed',
  }));
  const { getClientTier } = require('../renderer/clients.js');
  assert.equal(getClientTier('C1').name, 'Gold');
});

test('KhaytMachines and KhaytClients export tab entry points', () => {
  const machines = require('../renderer/machines.js');
  const clients = require('../renderer/clients.js');
  assert.equal(typeof machines.renderMachines, 'function');
  assert.equal(typeof machines.machineServiceStatus, 'function');
  assert.equal(typeof clients.renderClients, 'function');
  assert.equal(typeof clients.quoteForClient, 'function');
});
