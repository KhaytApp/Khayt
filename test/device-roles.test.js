'use strict';
/**
 * lib/device-roles.js: a paired phone's role, enforced by scopes (C1 + C9,
 * D-P2/D-P3/D-P4 as decided Nov 22). Vectors in
 * test/fixtures/device-roles-vectors.json for LanServer.swift and the iPhone.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('node:vm');
const D = require('../lib/device-roles.js');
const V = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'device-roles-vectors.json'), 'utf8'));

for (const c of V.cases) test(c.why, () => assert.deepEqual(D.allows(c.role, c.path, c.method), c.want));

test('the role table, the legacy owner and what each approver may grant', () => {
  assert.deepEqual(D.ROLES, V.roles);
  assert.deepEqual(D.ROLES, require('../lib/rbac.js').ROLES, 'the same ladder as lib/rbac.js');
  for (const [role, want] of Object.entries(V.scopesFor)) assert.deepEqual([...D.scopesFor(role)], want, role);
  assert.deepEqual([...D.scopesFor('owner')], [...D.SCOPES]);
  assert.deepEqual([...D.scopesFor('nope')], V.scopesFor.viewer, 'unknown: viewer');
  for (const r of V.roleOf) assert.equal(D.roleOf(r.device), r.want, JSON.stringify(r.device));
  for (const [who, want] of Object.entries(V.grantable)) assert.deepEqual(D.grantable(who), want, who);
  assert.equal(D.DEFAULT_ROLE, 'operator', 'D-P2');
});

test('each role holds everything the role below it holds (the ladder only adds)', () => {
  for (let i = 0; i < D.ROLES.length - 1; i++) {
    const hi = D.scopesFor(D.ROLES[i]), lo = D.scopesFor(D.ROLES[i + 1]);
    for (const s of lo) assert.ok(hi.includes(s), `${D.ROLES[i]} has ${s}`);
  }
  for (const r of D.ROUTES) for (const k of ['read', 'write']) if (r[k]) assert.ok(D.SCOPES.includes(r[k]), `${r.path.join('/')} ${r[k]}`);
});

test('the shared tables cannot be changed by a caller', () => {
  assert.throws(() => { 'use strict'; D.scopesFor('viewer').push('book:write'); });
  assert.throws(() => { 'use strict'; D.ROUTES[0].path.push('x'); });
  assert.equal(D.allows('viewer', '/api/store/deltas', 'POST').ok, false);
});

test('junk in, a refusal out, never a throw; a long path is not walked', () => {
  for (const p of [null, undefined, '', '/', 42, {}, '/api', '/api/' + 'a/'.repeat(5000)]) {
    const r = D.allows('manager', p, 'GET');
    assert.equal(r.ok, false, String(p).slice(0, 20));
    assert.equal(r.required, 'owner');
  }
});

test('loads in JavaScriptCore\'s shape: no require, the global only', () => {
  const ctx = {}; vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', 'device-roles.js'), 'utf8'), ctx);
  assert.equal(vm.runInContext("KhaytDeviceRoles.allows('operator', '/api/printer/m/stop', 'POST').ok", ctx), true);
  assert.equal(vm.runInContext("KhaytDeviceRoles.allows('viewer', '/api/store', 'GET').required", ctx), 'book:read');
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'device-roles.js'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
  assert.doesNotMatch(src, /\brequire\(|\bprocess\.|\bBuffer\b|\bglobal\b(?!This)/);
});
