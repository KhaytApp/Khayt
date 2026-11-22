'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  REDACTED,
  DEFAULT_DENY_KEYS,
  appendEntry,
  appendAll,
  verifyChain,
  entriesFromStampSummary,
  redactChanges,
} = require('../lib/audit-log');

const CTX = { actor: { operatorId: null, name: 'Owner', roleKey: 'owner' }, ts: '2026-06-16T10:00:00.000Z' };

function sampleRaw(n) {
  const out = [];
  for (let i = 0; i < n; i += 1) {
    out.push({
      ts: `2026-06-16T10:0${i}:00.000Z`,
      actor: CTX.actor,
      action: 'order.status_changed',
      entity: 'orders',
      entityId: `o${i}`,
      changes: [{ field: 'status', from: 'new', to: 'done' }],
    });
  }
  return out;
}

test('appendAll then verifyChain ok — chain integrity', () => {
  const chain = appendAll([], sampleRaw(5));
  assert.equal(chain.length, 5);
  const res = verifyChain(chain);
  assert.deepEqual(res, { ok: true, brokenAt: null });

  // hashPrev links: genesis is "", each subsequent points at prior hash.
  assert.equal(chain[0].hashPrev, '');
  for (let i = 1; i < chain.length; i += 1) {
    assert.equal(chain[i].hashPrev, chain[i - 1].hash);
  }
});

test('seq is monotonic and starts at 1 by default', () => {
  const chain = appendAll([], sampleRaw(4));
  assert.deepEqual(chain.map((e) => e.seq), [1, 2, 3, 4]);

  // appending more continues the sequence
  const more = appendAll(chain, sampleRaw(2));
  assert.deepEqual(more.map((e) => e.seq), [1, 2, 3, 4, 5, 6]);
  assert.equal(verifyChain(more).ok, true);
});

test('startSeq is honored', () => {
  const chain = appendAll([], sampleRaw(3), 100);
  assert.deepEqual(chain.map((e) => e.seq), [100, 101, 102]);
  assert.equal(verifyChain(chain).ok, true);
});

test('tamper detection — mutating an entry breaks the chain at that index', () => {
  const chain = appendAll([], sampleRaw(5));
  // Deep-clone so we hold a tampered copy without affecting the original.
  const tampered = JSON.parse(JSON.stringify(chain));
  tampered[2].changes = [{ field: 'status', from: 'new', to: 'TAMPERED' }];

  const res = verifyChain(tampered);
  assert.equal(res.ok, false);
  assert.equal(res.brokenAt, 2);
});

test('tamper detection — reordering / broken hashPrev link is caught', () => {
  const chain = appendAll([], sampleRaw(4));
  const tampered = JSON.parse(JSON.stringify(chain));
  // swap two entries: the link at index 1 will no longer match.
  const tmp = tampered[1];
  tampered[1] = tampered[2];
  tampered[2] = tmp;
  const res = verifyChain(tampered);
  assert.equal(res.ok, false);
  assert.equal(res.brokenAt, 1);
});

test('tamper detection — dropping the tail still verifies up to the cut (prefix is valid)', () => {
  const chain = appendAll([], sampleRaw(5));
  const truncated = chain.slice(0, 3);
  // A truncated prefix is internally consistent (tail-truncation needs an
  // external head marker to detect — out of scope for this pure core).
  assert.equal(verifyChain(truncated).ok, true);
});

test('appendEntry — hash covers hashPrev (same content, different prev → different hash)', () => {
  const raw = { ts: 't', actor: null, action: 'a', entity: 'e', entityId: '1', changes: null };
  const a = appendEntry('', raw);
  const b = appendEntry('deadbeef', raw);
  assert.notEqual(a.hash, b.hash);
  assert.equal(a.hashPrev, '');
  assert.equal(b.hashPrev, 'deadbeef');
});

test('appendEntry — key order does not affect hash (canonical serialization)', () => {
  const a = appendEntry('', { action: 'x', ts: 't', actor: { roleKey: 'owner', name: 'O' } });
  const b = appendEntry('', { ts: 't', action: 'x', actor: { name: 'O', roleKey: 'owner' } });
  assert.equal(a.hash, b.hash);
});

test('appendEntry — seq omitted when not supplied', () => {
  const e = appendEntry('', { ts: 't', action: 'a' });
  assert.equal('seq' in e, false);
  const withSeq = appendEntry('', { ts: 't', action: 'a', seq: 7 });
  assert.equal(withSeq.seq, 7);
});

test('entriesFromStampSummary — correct create/update/delete entries', () => {
  const summary = {
    created: [{ collection: 'orders', id: 'o1' }],
    changed: [{ collection: 'settings', id: 'settings', changes: [{ field: 'currency', from: 'SAR', to: 'USD' }] }],
    deleted: [{ collection: 'clients', id: 'c9' }],
  };
  const raw = entriesFromStampSummary(summary, CTX);
  assert.equal(raw.length, 3);

  assert.deepEqual(
    { action: raw[0].action, entity: raw[0].entity, entityId: raw[0].entityId, actor: raw[0].actor, ts: raw[0].ts },
    { action: 'create', entity: 'orders', entityId: 'o1', actor: CTX.actor, ts: CTX.ts },
  );
  assert.equal(raw[1].action, 'update');
  assert.equal(raw[1].entity, 'settings');
  assert.equal(raw[1].entityId, 'settings');
  assert.deepEqual(raw[1].changes, [{ field: 'currency', from: 'SAR', to: 'USD' }]);
  assert.equal(raw[2].action, 'delete');
  assert.equal(raw[2].entity, 'clients');
  assert.equal(raw[2].entityId, 'c9');

  // chains cleanly
  const chain = appendAll([], raw);
  assert.equal(verifyChain(chain).ok, true);
  assert.deepEqual(chain.map((e) => e.seq), [1, 2, 3]);
});

test('redactChanges — array form hides secret values but keeps field names', () => {
  const changes = [
    { field: 'status', from: 'new', to: 'done' },
    { field: 'botToken', from: 'old-secret-123', to: 'new-secret-456' },
    { field: 'lanApiPin', from: '0000', to: '1234' },
  ];
  const out = redactChanges(changes);

  // non-secret untouched
  assert.deepEqual(out[0], { field: 'status', from: 'new', to: 'done' });

  // secret values gone, field name kept
  assert.equal(out[1].field, 'botToken');
  assert.equal(out[1].from, REDACTED);
  assert.equal(out[1].to, REDACTED);
  assert.equal(out[2].field, 'lanApiPin');
  assert.equal(out[2].to, REDACTED);

  // the secret VALUES never appear anywhere in the serialized output
  const serialized = JSON.stringify(out);
  assert.equal(serialized.includes('old-secret-123'), false);
  assert.equal(serialized.includes('new-secret-456'), false);
  assert.equal(serialized.includes('1234'), false);
});

test('redactChanges — covers all default deny substrings, case-insensitive', () => {
  const fields = ['adminPin', 'apiKey', 'smtpPassword', 'webhookSecret', 'zatcaCsid', 'zatcaPcsid', 'accessToken'];
  const changes = fields.map((f) => ({ field: f, to: 'SENSITIVE_VALUE' }));
  const out = redactChanges(changes);
  for (let i = 0; i < out.length; i += 1) {
    assert.equal(out[i].field, fields[i], `field name preserved for ${fields[i]}`);
    assert.equal(out[i].to, REDACTED, `value redacted for ${fields[i]}`);
  }
  assert.equal(JSON.stringify(out).includes('SENSITIVE_VALUE'), false);
});

test('redactChanges — object map form', () => {
  const out = redactChanges({ currency: 'USD', apiKey: 'sk_live_xxx', name: 'Acme' });
  assert.equal(out.currency, 'USD');
  assert.equal(out.name, 'Acme');
  assert.equal(out.apiKey, REDACTED);
  assert.equal(JSON.stringify(out).includes('sk_live_xxx'), false);
});

test('redactChanges — does not mutate input', () => {
  const changes = [{ field: 'apiKey', from: 'a', to: 'b' }];
  const out = redactChanges(changes);
  assert.equal(changes[0].to, 'b'); // original intact
  assert.equal(out[0].to, REDACTED);
  assert.notEqual(out, changes);
});

test('redactChanges — custom denyKeys', () => {
  const out = redactChanges([{ field: 'iban', to: 'SA0000' }], ['iban']);
  assert.equal(out[0].to, REDACTED);
  // default-only deny key now passes through with custom list
  const out2 = redactChanges([{ field: 'apiKey', to: 'x' }], ['iban']);
  assert.equal(out2[0].to, 'x');
});

test('empty input is safe across the API', () => {
  assert.deepEqual(verifyChain([]), { ok: true, brokenAt: null });
  assert.deepEqual(verifyChain(null), { ok: true, brokenAt: null });
  assert.deepEqual(verifyChain(undefined), { ok: true, brokenAt: null });

  assert.deepEqual(appendAll([], []), []);
  assert.deepEqual(appendAll(null, null), []);
  assert.deepEqual(appendAll(undefined, undefined), []);

  assert.deepEqual(entriesFromStampSummary({}, CTX), []);
  assert.deepEqual(entriesFromStampSummary(null, CTX), []);
  assert.deepEqual(entriesFromStampSummary(undefined), []);

  assert.deepEqual(redactChanges([]), []);
  assert.equal(redactChanges(null), null);
  assert.equal(redactChanges(undefined), undefined);
});

test('DEFAULT_DENY_KEYS is the documented set', () => {
  assert.deepEqual(
    [...DEFAULT_DENY_KEYS].sort(),
    ['apikey', 'csid', 'password', 'pcsid', 'pin', 'secret', 'token'],
  );
});

test('end-to-end: stamp summary → redact → chain → verify', () => {
  const summary = {
    created: [{ collection: 'orders', id: 'o1', changes: [{ field: 'total', to: 500 }] }],
    changed: [{ collection: 'settings', id: 'settings', changes: [{ field: 'telegramBotToken', from: 'old', to: 'new' }] }],
    deleted: [{ collection: 'clients', id: 'c1' }],
  };
  const raw = entriesFromStampSummary(summary, CTX).map((e) => ({
    ...e,
    changes: e.changes ? redactChanges(e.changes) : e.changes,
  }));
  const chain = appendAll([], raw);

  assert.equal(verifyChain(chain).ok, true);
  // secret value redacted
  const settingsEntry = chain.find((e) => e.entity === 'settings');
  assert.equal(JSON.stringify(settingsEntry).includes('"new"'), false);
  assert.equal(settingsEntry.changes[0].field, 'telegramBotToken');
});
