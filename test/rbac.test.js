'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const rbac = require('../lib/rbac.js');
const { ROLES, AREAS, ACTIONS, MATRIX, can, roleFromLegacy, isAtLeast } = rbac;

test('ROLES is ordered most → least privileged', () => {
  assert.deepEqual(ROLES, ['owner', 'manager', 'operator', 'viewer']);
});

test('owner can do everything in the matrix (true on every granted cell)', () => {
  // Owner is true for every area/action that exists in its matrix row, and the
  // row covers every area.
  for (const area of AREAS) {
    assert.ok(MATRIX.owner[area], `owner missing area ${area}`);
  }
  // Spot-check the strongest privileges.
  for (const area of ['orders', 'inventory', 'clients', 'invoicing', 'settings', 'security', 'cloud', 'logs']) {
    assert.equal(can('owner', area, 'view'), true, `owner view ${area}`);
    assert.equal(can('owner', area, 'create'), true, `owner create ${area}`);
    assert.equal(can('owner', area, 'edit'), true, `owner edit ${area}`);
    assert.equal(can('owner', area, 'delete'), true, `owner delete ${area}`);
  }
  // Analytics is read-only even for owner per spec.
  assert.equal(can('owner', 'analytics', 'view'), true);
  // Destructive: owner may create (gated elsewhere) but it is not a delete/edit cell.
  assert.equal(can('owner', 'destructive', 'create'), true);
});

test('viewer is view-only everywhere (no create/edit/delete)', () => {
  for (const area of AREAS) {
    for (const action of ACTIONS) {
      const expected = action === 'view'
        ? MATRIX.viewer[area].view // some areas (analytics/settings/...) are hidden entirely
        : false;
      assert.equal(can('viewer', area, action), expected, `viewer ${area}/${action}`);
    }
  }
  // Concretely: viewer can read orders but never mutate.
  assert.equal(can('viewer', 'orders', 'view'), true);
  assert.equal(can('viewer', 'orders', 'create'), false);
  assert.equal(can('viewer', 'orders', 'edit'), false);
  assert.equal(can('viewer', 'orders', 'delete'), false);
  // Viewer cannot see admin areas at all.
  assert.equal(can('viewer', 'settings', 'view'), false);
  assert.equal(can('viewer', 'security', 'view'), false);
});

test('operator can edit orders but not delete, and no settings/security', () => {
  assert.equal(can('operator', 'orders', 'view'), true);
  assert.equal(can('operator', 'orders', 'create'), true);
  assert.equal(can('operator', 'orders', 'edit'), true);
  assert.equal(can('operator', 'orders', 'delete'), false);

  assert.equal(can('operator', 'inventory', 'edit'), true);
  assert.equal(can('operator', 'inventory', 'delete'), false);

  // Clients read-only for operator.
  assert.equal(can('operator', 'clients', 'view'), true);
  assert.equal(can('operator', 'clients', 'edit'), false);

  // No settings, security, cloud, analytics, invoicing-admin.
  for (const area of ['settings', 'security', 'cloud', 'analytics', 'destructive']) {
    for (const action of ACTIONS) {
      assert.equal(can('operator', area, action), false, `operator ${area}/${action}`);
    }
  }
  assert.equal(can('operator', 'invoicing', 'view'), true);
  assert.equal(can('operator', 'invoicing', 'create'), false);
});

test('manager is blocked from security, cloud, and destructive', () => {
  for (const area of ['security', 'cloud', 'destructive']) {
    for (const action of ACTIONS) {
      assert.equal(can('manager', area, action), false, `manager ${area}/${action}`);
    }
  }
  // Manager runs the shop: full orders/inventory/clients, analytics read.
  assert.equal(can('manager', 'orders', 'delete'), true);
  assert.equal(can('manager', 'clients', 'delete'), true);
  assert.equal(can('manager', 'analytics', 'view'), true);
  // Settings is read-only for manager (no write).
  assert.equal(can('manager', 'settings', 'view'), true);
  assert.equal(can('manager', 'settings', 'edit'), false);
  // Invoicing create/edit but not delete (no ZATCA admin).
  assert.equal(can('manager', 'invoicing', 'create'), true);
  assert.equal(can('manager', 'invoicing', 'edit'), true);
  assert.equal(can('manager', 'invoicing', 'delete'), false);
});

test('lockEnabled:false ⇒ everything allowed regardless of role (backward-compat)', () => {
  for (const role of [...ROLES, 'unknown', '', null, undefined]) {
    for (const area of AREAS) {
      for (const action of ACTIONS) {
        assert.equal(
          can(role, area, action, { lockEnabled: false }),
          true,
          `lock-off should allow ${role}/${area}/${action}`,
        );
      }
    }
  }
});

test('unknown / missing roleKey falls back to viewer (least privilege)', () => {
  for (const bogus of ['superadmin', 'root', '', null, undefined, 'OWNER ']) {
    // OWNER (uppercase) is normalized, but 'OWNER ' with a space is unknown.
    for (const area of AREAS) {
      for (const action of ACTIONS) {
        assert.equal(
          can(bogus, area, action),
          can('viewer', area, action),
          `unknown role ${JSON.stringify(bogus)} should equal viewer at ${area}/${action}`,
        );
      }
    }
  }
  // Case-insensitivity: 'OWNER' (no space) IS a valid owner.
  assert.equal(can('OWNER', 'security', 'delete'), true);
});

test('can() denies unknown area/action', () => {
  assert.equal(can('owner', 'nonsense', 'view'), false);
  assert.equal(can('owner', 'orders', 'teleport'), false);
});

test('roleFromLegacy maps legacy free-text roles per spec', () => {
  // admin → owner
  assert.equal(roleFromLegacy('admin'), 'owner');
  assert.equal(roleFromLegacy('Administrator'), 'owner');
  // tech / technician → operator
  assert.equal(roleFromLegacy('tech'), 'operator');
  assert.equal(roleFromLegacy('Senior Technician'), 'operator');
  // sales → operator
  assert.equal(roleFromLegacy('Sales'), 'operator');
  // manager → manager
  assert.equal(roleFromLegacy('Shop Manager'), 'manager');
  // viewer/read → viewer
  assert.equal(roleFromLegacy('Read Only'), 'viewer');
  assert.equal(roleFromLegacy('viewer'), 'viewer');
  // unrecognized non-empty → operator (safe front-line default)
  assert.equal(roleFromLegacy('Designer'), 'operator');
  // empty → owner when no lock; operator when a lock exists
  assert.equal(roleFromLegacy(''), 'owner');
  assert.equal(roleFromLegacy('   '), 'owner');
  assert.equal(roleFromLegacy(null), 'owner');
  assert.equal(roleFromLegacy('', { hasLock: false }), 'owner');
  assert.equal(roleFromLegacy('', { hasLock: true }), 'operator');
});

test('isAtLeast respects the privilege ordering', () => {
  // Owner satisfies every floor.
  for (const floor of ROLES) {
    assert.equal(isAtLeast('owner', floor), true, `owner ≥ ${floor}`);
  }
  // Viewer only satisfies the viewer floor.
  assert.equal(isAtLeast('viewer', 'viewer'), true);
  assert.equal(isAtLeast('viewer', 'operator'), false);
  assert.equal(isAtLeast('viewer', 'manager'), false);
  assert.equal(isAtLeast('viewer', 'owner'), false);

  // Manager ≥ operator ≥ viewer, but manager < owner.
  assert.equal(isAtLeast('manager', 'operator'), true);
  assert.equal(isAtLeast('manager', 'viewer'), true);
  assert.equal(isAtLeast('manager', 'owner'), false);
  assert.equal(isAtLeast('operator', 'viewer'), true);
  assert.equal(isAtLeast('operator', 'manager'), false);

  // Equality holds.
  assert.equal(isAtLeast('operator', 'operator'), true);

  // Unknown roles normalize to viewer (lowest).
  assert.equal(isAtLeast('bogus', 'viewer'), true);
  assert.equal(isAtLeast('bogus', 'operator'), false);
});
