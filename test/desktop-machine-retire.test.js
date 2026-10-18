'use strict';
// The desktop side of lib/machine-status.js (Mac #1945): a printer with
// history is retired, not deleted, and a retired one leaves every picker,
// poll, board and dashboard. The rule is tested where it lives; this guards
// the wiring, because a correct module with no caller is the recurring bug.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const R = (f) => fs.readFileSync(path.join(__dirname, '..', 'renderer', f), 'utf8');

test('both windows load machine-status.js after order-status.js', () => {
  for (const page of ['index.html', 'bedready.html']) {
    const html = R(page);
    const a = html.indexOf('../lib/order-status.js');
    const b = html.indexOf('../lib/machine-status.js');
    assert.ok(a > 0 && b > a, page);
  }
});

test('delete asks the rule first, and retires what has history', () => {
  const src = R('machines.js');
  const body = src.slice(src.indexOf('async function deleteMachine('), src.indexOf('async function deleteMachine(') + 1800);
  assert.match(body, /MS\.canDelete\(book, machineId\)/);
  assert.match(body, /MS\.retire\(book, machineId, \{ at: localDateStr\(\) \}\)/);
  assert.match(body, /MS\.remove\(book, machineId\)/);
  assert.doesNotMatch(body, /machines = machines\.filter/, 'the old unconditional delete');
});

test('a retired printer can be returned to service from its row', () => {
  assert.match(R('machines.js'), /data-act="unretire-mach"/);
  assert.match(R('wire-events.js'), /unretire-mach'\) unretireMachine\(/);
});

test('every day-to-day list of printers leaves the retired ones out', () => {
  const sites = {
    'machines.js': /activeMachines\(\)\.map\(m => `<option/,
    'app-boot.js': /const apiMachines = activeMachines\(\)\.filter/,
    'kanban.js': /activeMachines\(\)\.filter\(machineMatchesActiveLocation\)/,
    'dashboard.js': /const machRows = activeMachines\(\)\.map/,
    'waste.js': /activeMachines\(\)\.map/,
    'order-flows.js': /activeMachines\(\)\.map\(m => `<option/,
    'inventory.js': /activeMachines\(\)\.map\(m => `<option/,
    'logs.js': /activeMachines\(\)\.map/,
    'operations-extras.js': /activeMachines\(existing && existing\.machineId\)/,
    'printfiles.js': /activeMachines\(su\.machineId\)/,
  };
  for (const [file, re] of Object.entries(sites)) assert.match(R(file), re, file);
  assert.match(R('dashboard.js'), /const maintMachines = activeMachines\(\)\.filter/);
});

test('maintenance reminders are told which printers exist', () => {
  assert.match(R('notifications.js'), /KhaytMaintenance\.dueTasks\(machMaintTasks, hoursByMachine, Date\.now\(\), machines\)/);
});

test('activeMachines keeps the one a record already names', () => {
  global.KhaytMachineStatus = require('../lib/machine-status.js');
  const machines = [{ id: 'a' }, { id: 'b', status: 'retired', retiredAt: '2026-10-01' }];
  const src = R('app-state.js');
  const fn = src.slice(src.indexOf('function activeMachines('), src.indexOf('function collectStoreCollections('));
  const activeMachines = new Function('machines', `${fn}; return activeMachines;`)(machines);
  assert.deepEqual(activeMachines().map(m => m.id), ['a']);
  assert.deepEqual(activeMachines('b').map(m => m.id), ['a', 'b']);
});
