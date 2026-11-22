const { test } = require('node:test');
const assert = require('node:assert/strict');
const T = require('../lib/api-tokens.js');

test('generateToken: prefixed plaintext once, only a hash persisted', () => {
  const { token, record } = T.generateToken({ label: 'Zapier', scopes: ['orders:read', 'orders:write'] });
  assert.ok(token.startsWith('khayt_'), 'prefixed');
  assert.ok(token.length > 40, 'high entropy');
  assert.equal(record.hash, T.hashToken(token));
  assert.equal(JSON.stringify(record).includes(token), false, 'plaintext never stored in the record');
  assert.deepEqual(record.scopes, ['orders:read', 'orders:write']);
  assert.equal(record.lastUsedAt, null);
});

test('generateToken: drops unknown scopes and clamps the label', () => {
  const { record } = T.generateToken({ label: 'x'.repeat(200), scopes: ['orders:read', 'bogus:scope'] });
  assert.deepEqual(record.scopes, ['orders:read']);
  assert.equal(record.label.length, 60);
});

test('generateToken: two mints never collide', () => {
  const a = T.generateToken({ scopes: [] });
  const b = T.generateToken({ scopes: [] });
  assert.notEqual(a.token, b.token);
  assert.notEqual(a.record.id, b.record.id);
});

test('verifyToken: matches the right record, rejects unknown and revoked', () => {
  const a = T.generateToken({ label: 'A', scopes: ['orders:read'] });
  const b = T.generateToken({ label: 'B', scopes: ['clients:read'] });
  const store = [a.record, b.record];
  assert.equal(T.verifyToken(a.token, store).label, 'A');
  assert.equal(T.verifyToken(b.token, store).label, 'B');
  // Revocation = removing the record → immediately unusable.
  assert.equal(T.verifyToken(a.token, [b.record]), null, 'revoked token denied');
  assert.equal(T.verifyToken('khayt_totallybogus', store), null);
  assert.equal(T.verifyToken('', store), null);
  assert.equal(T.verifyToken(null, store), null);
  assert.equal(T.verifyToken('no-prefix', store), null, 'unprefixed rejected');
});

test('verifyToken: tolerates malformed records without throwing', () => {
  const a = T.generateToken({ scopes: [] });
  assert.equal(T.verifyToken(a.token, [null, {}, { hash: 123 }, { hash: 'short' }]), null);
  assert.equal(T.verifyToken(a.token, null), null);
});

test('bearerFromHeader parses only well-formed prefixed bearers', () => {
  assert.equal(T.bearerFromHeader('Bearer khayt_abc'), 'khayt_abc');
  assert.equal(T.bearerFromHeader('bearer   khayt_abc'), 'khayt_abc');
  assert.equal(T.bearerFromHeader('Bearer someothertoken'), null, 'foreign token ignored');
  assert.equal(T.bearerFromHeader('Basic khayt_abc'), null);
  assert.equal(T.bearerFromHeader(''), null);
  assert.equal(T.bearerFromHeader(undefined), null);
});

test('hasScope is exact — no implicit widening', () => {
  const rec = { scopes: ['orders:read'] };
  assert.equal(T.hasScope(rec, 'orders:read'), true);
  assert.equal(T.hasScope(rec, 'orders:write'), false, 'read does NOT imply write');
  assert.equal(T.hasScope(rec, 'clients:read'), false);
  assert.equal(T.hasScope(null, 'orders:read'), false);
  assert.equal(T.hasScope({}, 'orders:read'), false);
});

test('requiredScope maps path + method to the needed scope', () => {
  assert.equal(T.requiredScope('/v1/orders', 'GET'), 'orders:read');
  assert.equal(T.requiredScope('/v1/orders', 'POST'), 'orders:write');
  assert.equal(T.requiredScope('/v1/orders/INV-1', 'PATCH'), 'orders:write');
  assert.equal(T.requiredScope('/v1/queue', 'GET'), 'orders:read');
  assert.equal(T.requiredScope('/v1/clients', 'POST'), 'clients:write');
  assert.equal(T.requiredScope('/v1/inventory', 'GET'), 'inventory:read');
  assert.equal(T.requiredScope('/v1/inventory/SP-1', 'DELETE'), 'inventory:write');
  assert.equal(T.requiredScope('/v1/machines', 'GET'), 'machines:read');
  assert.equal(T.requiredScope('/v1/machines', 'POST'), 'machines:read', 'no machine writes over the API');
  assert.equal(T.requiredScope('/v1/status', 'GET'), null, 'public status needs no scope');
});

test('redactTokens never exposes the hash', () => {
  const { record } = T.generateToken({ label: 'A', scopes: ['orders:read'] });
  const out = T.redactTokens([record]);
  assert.equal(out[0].label, 'A');
  assert.equal(out[0].hash, undefined);
  assert.equal(JSON.stringify(out).includes(record.hash), false);
  assert.deepEqual(T.redactTokens(null), []);
});
