const { test } = require('node:test');
const assert = require('node:assert/strict');

const A = require('../lib/deposit-audit.js');

/**
 * Deposits erased by the pre-#500 instalment save, and their recovery.
 *
 * The defect assigned `instPaid` over `paidAmount` unconditionally. Since the
 * plan generator builds schedules with depositAmount:0 spanning the full price,
 * a freshly generated plan had instPaid = 0 — so a 500 deposit became 0 on save,
 * the order dropped to 'unpaid', and receivables rose by 500 silently.
 *
 * I twice told the user this was unrecoverable, reasoning that nothing recorded
 * the prior value. That was wrong: createOrder writes a SEPARATE
 * `depositAmount` field the defect never touched, and it survives store
 * normalization (verified against normalizeStoreSnapshot before this was built).
 * The tests below pin both the detection and the arithmetic that puts it back.
 */

const affected = () => ({
  id: 'O1', project: 'Sign', status: 'completed', date: '2026-07-01',
  price: 2000, depositAmount: 500, paidAmount: 0, paymentStatus: 'unpaid',
  instalments: [{ id: 'I1', amount: 666.67, paid: false }],
});

test('an erased deposit is detected', () => {
  const [hit] = A.findErasedDeposits([affected()]);
  assert.ok(hit, 'the affected order must be found');
  assert.equal(hit.deposit, 500);
  assert.equal(hit.currentPaid, 0);
  assert.equal(hit.recovered, 500);
  assert.equal(hit.lost, 500);
});

test('instalments already marked paid are added, not replaced', () => {
  // Both are real cash the shop received. Restoring only the deposit would
  // trade one wrong number for another.
  const o = affected();
  o.instalments = [{ id: 'I1', amount: 400, paid: true }, { id: 'I2', amount: 600, paid: false }];
  o.paidAmount = 400;
  const [hit] = A.findErasedDeposits([o]);
  assert.equal(hit.recovered, 900, 'deposit 500 + instalment 400');
  assert.equal(hit.lost, 500);
});

test('an untouched order is not flagged', () => {
  const o = affected();
  o.paidAmount = 500;      // deposit intact
  assert.deepEqual(A.findErasedDeposits([o]), []);
});

test('an order with no deposit is never flagged', () => {
  // Most orders have no deposit at all. Flagging them would bury the real ones.
  const o = affected();
  o.depositAmount = 0;
  assert.deepEqual(A.findErasedDeposits([o]), []);
  delete o.depositAmount;
  assert.deepEqual(A.findErasedDeposits([o]), []);
});

test('an order with no instalments is not flagged, even if paid < deposit', () => {
  // The instalment save is the ONLY path that overwrote paidAmount. Without
  // that condition this would flag an owner's own manual correction and tell
  // them it was a bug.
  const o = affected();
  o.instalments = [];
  assert.deepEqual(A.findErasedDeposits([o]), []);
  delete o.instalments;
  assert.deepEqual(A.findErasedDeposits([o]), []);
});

test('cent-level float drift does not look like a missing deposit', () => {
  // The tolerance only matters when paid lands fractionally BELOW the deposit.
  // 0.1+0.2 drifts ABOVE (0.30000000000000004) and would pass with no epsilon
  // at all — mutation-testing caught that this assertion was pointing the wrong
  // way. 0.7-0.4 gives 0.29999999999999993, which is the real hazard: a shop
  // told a deposit is missing because the last bit of a float went the wrong way.
  const o = affected();
  o.depositAmount = 0.3;
  o.paidAmount = 0.7 - 0.4;
  assert.ok(o.paidAmount < 0.3, 'the fixture must actually be below the deposit');
  assert.deepEqual(A.findErasedDeposits([o]), [], 'binary drift is not a lost deposit');
});

test('restoring sets the paid amount and recomputes payment status', () => {
  const o = affected();
  const entry = A.findErasedDeposits([o])[0];
  const res = A.restoreDeposit(entry);
  assert.equal(res.ok, true);
  assert.equal(o.paidAmount, 500);
  assert.equal(o.paymentStatus, 'partial', '500 against a 2,000 price is partial, not unpaid');
  assert.deepEqual(res.before, { paidAmount: 0, paymentStatus: 'unpaid' }, 'undo needs the prior values');
});

test('restoring an order whose deposit covers the price marks it paid', () => {
  const o = affected();
  o.price = 500;
  const entry = A.findErasedDeposits([o])[0];
  A.restoreDeposit(entry);
  assert.equal(o.paymentStatus, 'paid');
});

test('restoring touches nothing else', () => {
  const o = affected();
  o.notes = 'keep'; o.clientId = 'C1';
  const entry = A.findErasedDeposits([o])[0];
  A.restoreDeposit(entry);
  assert.equal(o.price, 2000, 'the price is what was agreed — never touched');
  assert.equal(o.depositAmount, 500, 'the recovery source must survive for a re-run');
  assert.equal(o.instalments.length, 1);
  assert.equal(o.notes, 'keep');
  assert.equal(o.clientId, 'C1');
});

test('restoring twice is refused, not doubled', () => {
  // The banner re-renders from live data, but a stale entry must not be able to
  // stack a second restore on top of the first.
  const o = affected();
  const entry = A.findErasedDeposits([o])[0];
  assert.equal(A.restoreDeposit(entry).ok, true);
  const second = A.restoreDeposit(entry);
  assert.equal(second.ok, false);
  assert.equal(o.paidAmount, 500, 'the amount must not double');
});

test('the worst loss is listed first, and the total is summed', () => {
  const small = { ...affected(), id: 'small', depositAmount: 100, paidAmount: 0 };
  const big = { ...affected(), id: 'big', depositAmount: 900, paidAmount: 0 };
  const hits = A.findErasedDeposits([small, big]);
  assert.deepEqual(hits.map((h) => h.order.id), ['big', 'small']);
  assert.equal(A.totalLost(hits), 1000);
});

test('empty and malformed input is safe', () => {
  for (const bad of [null, undefined, [], 'nope', {}]) {
    assert.deepEqual(A.findErasedDeposits(bad), []);
  }
  assert.equal(A.restoreDeposit(null).ok, false);
  assert.equal(A.restoreDeposit({}).ok, false);
  assert.equal(A.totalLost(null), 0);
});

test('the recovery source really does survive store normalization', () => {
  // This is the fact the whole feature rests on, and the one I got wrong twice
  // by reading instead of running. Pin it: if a future schema change strips
  // depositAmount, the deposits become genuinely unrecoverable and this must
  // fail loudly rather than the banner quietly finding nothing.
  const { normalizeStoreSnapshot, STORE_VERSION } = require('../lib/store-validate.js');
  const snap = { version: STORE_VERSION, printLog: [affected()], inventory: [], settings: {} };
  const { normalized } = normalizeStoreSnapshot(JSON.parse(JSON.stringify(snap)));
  const o = normalized.printLog[0];
  assert.ok(o, 'the order must survive normalization');
  assert.equal(o.depositAmount, 500, 'depositAmount is the only record of the erased figure');
  assert.equal((o.instalments || []).length, 1, 'instalments are needed to identify the affected path');
});
