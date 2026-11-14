const { test } = require('node:test');
const assert = require('node:assert/strict');
const N = require('../lib/order-next-step.js');

const job = (status, extra) => Object.assign({ id: 'J1', status, price: 100, paidAmount: 0 }, extra || {});
const codes = (steps) => steps.map((s) => s.code);

test('every working stage has one move along, and QC is its own step', () => {
  const cases = [
    ['pending', 'start_printing', 'printing'],
    ['printing', 'mark_printed', 'post'],
    ['post', 'send_to_check', 'qc'],
    ['qc', 'mark_ready', 'completed'],
  ];
  for (const [status, code, to] of cases) {
    const r = N.nextSteps(job(status), {});
    assert.equal(r.stage, status);
    assert.equal(r.primary.code, code, status);
    assert.equal(r.primary.to, to, status);
    assert.equal(r.primary.blocked, null, status);
    assert.ok(codes(r.secondary).includes('hold'), `${status} can be put on hold`);
  }
});

test('finishing asks what it took; putting on hold asks why; failing a check asks what failed', () => {
  const qc = N.nextSteps(job('qc'), {});
  assert.equal(qc.primary.asks, 'actuals');
  const fail = qc.secondary.find((s) => s.code === 'fail_check');
  assert.equal(fail.asks, 'qc_fail');
  assert.equal(fail.to, 'post');
  assert.equal(N.nextSteps(job('printing'), {}).primary.asks, null);
  assert.equal(N.nextSteps(job('pending'), {}).secondary.find((s) => s.code === 'hold').asks, 'hold');
});

test('a quote: send it first; once sent, take the job', () => {
  const fresh = N.nextSteps(job('quote'), {});
  assert.equal(fresh.primary.code, 'send_quote');
  assert.equal(fresh.primary.asks, 'send');
  assert.equal(fresh.primary.to, null);
  assert.deepEqual(codes(fresh.secondary), ['take_job'], 'an app that cannot send still offers take_job');
  assert.equal(fresh.secondary[0].to, 'pending');

  const sent = N.nextSteps(job('quote', { quoteSharedAt: '2026-11-14T10:00:00Z' }), {});
  assert.equal(sent.primary.code, 'take_job');
  assert.equal(sent.primary.to, 'pending');
  assert.deepEqual(codes(sent.secondary), ['send_quote']);
  // `quoteSentAt` is written on EVERY quote at creation (order-new.js): it is
  // the day it was quoted, not proof it was sent.
  assert.equal(N.nextSteps(job('quote', { quoteSentAt: '2026-11-01' }), {}).primary.code, 'send_quote');
  assert.equal(fresh.owed, 0, 'a quote owes nothing');
  assert.equal(fresh.late, false, 'a quote has no deadline to miss');
});

test('on hold: Resume, back to the stage it was held from', () => {
  const held = (history) => N.nextSteps(job('on_hold', { statusHistory: history }), {});
  const at = (status) => ({ status, at: '2026-11-10T08:00:00Z' });
  assert.equal(held([at('pending'), at('printing'), at('on_hold')]).primary.to, 'printing');
  assert.equal(held([at('pending'), at('on_hold')]).primary.to, 'pending');
  assert.equal(held([at('printing'), at('post'), at('qc'), at('on_hold')]).primary.to, 'qc');
  // Held twice: the stage before the LAST hold.
  assert.equal(held([at('printing'), at('on_hold'), at('printing'), at('post'), at('on_hold')]).primary.to, 'post');
  // No history, or held from somewhere that is not work: back into the queue.
  assert.equal(held(undefined).primary.to, 'pending');
  assert.equal(held([at('quote'), at('on_hold')]).primary.to, 'pending');
  const r = held([at('printing'), at('on_hold')]);
  assert.equal(r.primary.code, 'resume');
  assert.equal(r.heldFrom, 'printing');
  assert.equal(r.pill.tone, 'purple');
  assert.ok(!codes(r.secondary).includes('hold'));
});

test('finished: hand over; shipped is a stamp; delivered and owing asks for the payment', () => {
  const done = N.nextSteps(job('completed', { completedAt: '2026-11-12T09:00:00Z' }), {});
  assert.equal(done.stage, 'completed');
  assert.equal(done.primary.code, 'hand_over');
  assert.equal(done.primary.to, null, 'a hand-over stamps a date, it does not move the status');
  assert.deepEqual(codes(done.secondary), ['ship', 'record_payment']);

  const shipped = N.nextSteps(job('completed', { shippedAt: '2026-11-13T09:00:00Z' }), {});
  assert.equal(shipped.stage, 'shipped');
  assert.equal(shipped.primary.code, 'hand_over');
  assert.ok(!codes(shipped.secondary).includes('ship'));

  const owing = N.nextSteps(job('completed', { deliveredAt: '2026-11-13T10:00:00Z' }), {});
  assert.equal(owing.stage, 'delivered');
  assert.equal(owing.primary.code, 'record_payment');
  assert.equal(owing.primary.asks, 'payment');
  assert.equal(owing.owed, 100);
  assert.equal(owing.pill.stage, 'delivered');

  const paid = N.nextSteps(job('completed', { deliveredAt: '2026-11-13T10:00:00Z', paidAmount: 100 }), {});
  assert.equal(paid.primary, null);
  assert.deepEqual(paid.pill, { stage: 'paid', tone: 'green' });
  // The legacy `delivered` STATUS is a delivered job too.
  assert.equal(N.nextSteps(job('delivered', { paidAmount: 100 }), {}).primary, null);
});

test('nothing next for a cancelled, split or voided job', () => {
  const cancelled = N.nextSteps(job('cancelled'), {});
  assert.equal(cancelled.primary, null);
  assert.deepEqual(cancelled.secondary, []);
  assert.equal(cancelled.pill.tone, 'grey');
  assert.equal(cancelled.owed, 0);
  assert.equal(N.nextSteps(job('split'), {}).primary, null);
  const voided = N.nextSteps(job('completed', { voidedAt: '2026-11-13' }), {});
  assert.equal(voided.primary, null);
  assert.deepEqual(voided.secondary, []);
  assert.equal(voided.pill.tone, 'grey');
  assert.equal(N.nextSteps(null, {}), null);
});

test('the gate speaks at the control: paused, WIP, assembly, read-only', () => {
  const paused = N.nextSteps(job('pending'), { settings: { productionPaused: true } });
  assert.deepEqual(paused.primary.blocked, { code: 'production_paused', params: {} });
  assert.equal(paused.primary.code, 'start_printing', 'still named, so the page can say why not');
  // Paused stops work being STARTED, nothing else.
  assert.equal(N.nextSteps(job('printing'), { settings: { productionPaused: true } }).primary.blocked, null);

  const others = [job('printing', { id: 'A' }), job('printing', { id: 'B' })];
  const wip = { wipLimits: { printing: 2 }, wipEnforceHardLimit: true };
  const full = N.nextSteps(job('pending'), { settings: wip, orders: others.concat([job('pending')]) });
  assert.equal(full.primary.blocked.code, 'wip_blocked');
  assert.equal(full.primary.blocked.params.n, 2);
  // A soft limit warns when the move is made; it does not block the button.
  const soft = N.nextSteps(job('pending'), { settings: { wipLimits: { printing: 2 } }, orders: others.concat([job('pending')]) });
  assert.equal(soft.primary.blocked, null);

  const ro = N.nextSteps(job('printing'), { canWrite: false });
  assert.equal(ro.primary.blocked.code, 'read_only');
  assert.ok(ro.secondary.every((s) => s.blocked && s.blocked.code === 'read_only'));
  const roDone = N.nextSteps(job('completed'), { canWrite: false });
  assert.equal(roDone.primary.blocked.code, 'read_only', 'a hand-over is a write too');
});

test('late: due before today, or the caller\'s own answer; never for finished or cancelled work', () => {
  const due = { dueDate: '2026-11-10' };
  assert.equal(N.nextSteps(job('printing', due), { today: '2026-11-14' }).late, true);
  assert.equal(N.nextSteps(job('printing', due), { today: '2026-11-10' }).late, false, 'due today is not late');
  assert.equal(N.nextSteps(job('printing', due), {}).late, false, 'no day given, no claim');
  assert.equal(N.nextSteps(job('printing', due), { today: '2026-11-14', late: false }).late, false, 'the caller\'s rule wins');
  assert.equal(N.nextSteps(job('printing', {}), { late: true }).late, true);
  for (const st of ['completed', 'cancelled', 'quote']) {
    assert.equal(N.nextSteps(job(st, due), { today: '2026-11-14', late: true }).late, false, st);
  }
});

test('tones: steel waits, amber is being made, green is done, purple is held, grey is over', () => {
  const tone = (status, extra) => N.nextSteps(job(status, extra), {}).pill.tone;
  assert.equal(tone('quote'), 'steel');
  assert.equal(tone('pending'), 'steel');
  for (const st of ['printing', 'post', 'qc']) assert.equal(tone(st), 'amber', st);
  assert.equal(tone('completed'), 'green');
  assert.equal(tone('completed', { shippedAt: 'x' }), 'green');
  assert.equal(tone('on_hold'), 'purple');
  assert.equal(tone('cancelled'), 'grey');
  assert.equal(tone('something-new'), 'grey', 'a stage this build does not know is not coloured as work');
});

test('the track: done, current, todo; hold stands where it was held; shipped stands at the end', () => {
  const at = (status, when) => ({ status, at: when });
  const printing = N.nextSteps(job('printing', {
    statusHistory: [at('pending', '2026-11-10T08:00:00Z'), at('printing', '2026-11-11T08:00:00Z')] }), {});
  assert.deepEqual(printing.track.map((n) => `${n.stage}:${n.state}`),
    ['pending:done', 'printing:current', 'post:todo', 'qc:todo', 'completed:todo', 'delivered:todo']);
  assert.equal(printing.track[0].at, '2026-11-10T08:00:00Z');
  assert.equal(printing.track[1].at, '2026-11-11T08:00:00Z');
  assert.equal(printing.track[2].at, '', 'a stage not reached has no date');

  const wasQuote = N.nextSteps(job('pending', { statusHistory: [at('quote', 'q'), at('pending', 'p')] }), {});
  assert.equal(wasQuote.track[0].stage, 'quote');
  assert.equal(wasQuote.track[0].state, 'done');

  const held = N.nextSteps(job('on_hold', { statusHistory: [at('printing', 'a'), at('on_hold', 'b')] }), {});
  assert.equal(held.track.find((n) => n.state === 'current').stage, 'printing');

  const shipped = N.nextSteps(job('completed', { completedAt: 'c', shippedAt: 's' }), {});
  const last = shipped.track[shipped.track.length - 1];
  assert.deepEqual(last, { stage: 'shipped', state: 'current', at: 's' });
  assert.equal(shipped.track.find((n) => n.stage === 'completed').state, 'done');

  const delivered = N.nextSteps(job('completed', { completedAt: 'c', deliveredAt: 'd', paidAmount: 100 }), {});
  assert.ok(delivered.track.every((n) => n.state === 'done'), 'nothing left on the track');
  assert.equal(delivered.track[delivered.track.length - 1].at, 'd');

  const cancelled = N.nextSteps(job('cancelled', { statusHistory: [at('pending', 'p'), at('printing', 'r'), at('cancelled', 'x')] }), {});
  assert.deepEqual(cancelled.track.map((n) => n.state), ['done', 'done', 'todo', 'todo', 'todo', 'todo']);
});

test('owed follows the shop\'s tax: an exclusive shop is owed price plus tax', () => {
  const settings = { tax: { enabled: true, rate: 15, mode: 'exclusive' } };
  const plain = N.nextSteps(job('printing'), {}).owed;
  assert.equal(plain, 100);
  const M = require('../lib/order-money.js');
  const expected = Math.round(M.orderOwedRaw(job('printing'), { settings }) * 100) / 100;
  assert.equal(N.nextSteps(job('printing'), { settings }).owed, expected, 'the figure is order-money\'s, not price minus paid');
  // A crumb left by rounding never asks for a payment.
  const crumb = N.nextSteps(job('completed', { deliveredAt: 'd', paidAmount: 99.999 }), {});
  assert.equal(crumb.primary, null);
});

test('nextStepsAll: the whole book in one call, with the caller\'s late list', () => {
  const book = [job('pending', { id: 'A' }), job('printing', { id: 'B', dueDate: '2026-11-01' }), { nope: true }];
  const all = N.nextStepsAll(book, { lateIds: ['A'], today: '2026-11-14' });
  assert.deepEqual(Object.keys(all).sort(), ['A', 'B']);
  assert.equal(all.A.late, true);
  assert.equal(all.B.late, false, 'the caller\'s list decides, not the date');
  assert.equal(N.nextStepsAll(book, { today: '2026-11-14' }).B.late, true);
  assert.deepEqual(N.nextStepsAll(null, {}), {});
});

test('the module is safe in JavaScriptCore: no window, no global, no clock', () => {
  const src = require('node:fs').readFileSync(require.resolve('../lib/order-next-step.js'), 'utf8');
  const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
  assert.ok(!/\bwindow\b/.test(code));
  assert.ok(!/\bglobal\./.test(code), 'JSC has no `global`');
  assert.ok(!/Date\.now|new Date\(/.test(code), 'the caller says what day it is');
});
