const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/privacy.js');

const COLLECTIONS = () => ({
  clients: [{
    id: 'C1', nameEn: 'Sara Noor', nameAr: 'سارة نور', phone: '+966500000000', email: 'sara@example.com',
    addresses: [{ label: 'Home', address: 'Riyadh' }], cr: '123', vat: '456', createdAt: '2026-01-01',
    commLog: [{ type: 'call', note: 'discussed order', at: '2026-02-01' }],
  }, { id: 'C2', nameEn: 'Other', email: 'other@example.com' }],
  printLog: [
    { id: 'O1', clientId: 'C1', date: '2026-03-01', project: 'Vase', status: 'completed', price: 100, client: 'Sara Noor', notes: 'n' },
    { id: 'O2', clientId: 'C2', date: '2026-03-02', project: 'Cup', status: 'pending', price: 50 },
  ],
  waitingList: [{ id: 'W1', name: 'Sara Noor', email: 'sara@example.com', at: '2026-02-10' }],
  waitingListHistory: [{ id: 'H1', name: 'someone', email: 'other@example.com', at: '2025-01-01' }],
});

test('consentRecord: null without agreement, stamped + versioned with it', () => {
  assert.equal(P.consentRecord(false, 'Shop', 'en'), null);
  const r = P.consentRecord(true, 'My Shop', 'en', '2026-07-19T00:00:00Z');
  assert.equal(r.agreed, true);
  assert.equal(r.at, '2026-07-19T00:00:00Z');
  assert.equal(r.version, P.CONSENT_VERSION);
  assert.match(r.text, /My Shop/);
});

test('consentNoticeText is bilingual and interpolates the shop', () => {
  assert.match(P.consentNoticeText('Khayt', 'en'), /Khayt may store my contact details/);
  assert.match(P.consentNoticeText('Khayt', 'ar'), /Khayt/);
  assert.notEqual(P.consentNoticeText('X', 'ar'), P.consentNoticeText('X', 'en'));
});

test('buildClientDataExport bundles only this subject: record, orders, comms, intake', () => {
  const e = P.buildClientDataExport('C1', COLLECTIONS(), '2026-07-19T00:00:00Z');
  assert.equal(e.subject.nameEn, 'Sara Noor');
  assert.equal(e.orders.length, 1);
  assert.equal(e.orders[0].id, 'O1', "other client's order excluded");
  assert.equal(e.communications.length, 1);
  assert.equal(e.intakeSubmissions.length, 1, 'intake matched by email');
  assert.equal(e.intakeHistory.length, 0, "other subject's history excluded");
  assert.equal(e.counts.orders, 1);
});

test('buildClientDataExport never leaks shop settings/secrets', () => {
  const e = P.buildClientDataExport('C1', COLLECTIONS());
  const json = JSON.stringify(e);
  assert.equal(json.includes('apiKey'), false);
  assert.equal(json.includes('settings'), false);
  assert.deepEqual(Object.keys(e).sort(), ['communications', 'counts', 'exportedAt', 'giftCards', 'intakeHistory', 'intakeSubmissions', 'loyaltyLedger', 'orders', 'subject'].sort());
});

test('buildClientDataExport on an unknown client is empty, not a throw', () => {
  const e = P.buildClientDataExport('nope', COLLECTIONS());
  assert.equal(e.subject, null);
  assert.equal(e.orders.length, 0);
  assert.equal(e.communications.length, 0);
});

test('planClientErasure unlink: keeps orders, no purge', () => {
  const p = P.planClientErasure('C1', COLLECTIONS(), 'unlink');
  assert.equal(p.mode, 'unlink');
  assert.deepEqual(p.orderIds, ['O1'], 'order retained (financial basis), link dropped');
  assert.equal(p.blankOrderNames, false);
  assert.equal(p.purgeCommLog, false);
  assert.deepEqual(p.purgeIntakeIds, []);
  assert.equal(p.counts.communications, 0);
});

test('planClientErasure full: blanks names, purges intake + commLog', () => {
  const p = P.planClientErasure('C1', COLLECTIONS(), 'full');
  assert.equal(p.mode, 'full');
  assert.deepEqual(p.orderIds, ['O1']);
  assert.equal(p.blankOrderNames, true);
  assert.equal(p.purgeCommLog, true);
  assert.deepEqual(p.purgeIntakeIds, ['W1']);
  assert.equal(p.counts.communications, 1);
  assert.equal(p.counts.intake, 1);
});

test('selectStaleIntakeRows honours the retention window', () => {
  const now = Date.parse('2026-07-19T00:00:00Z');
  const rows = [
    { id: 'a', at: '2026-07-01T00:00:00Z' }, // ~18 days
    { id: 'b', at: '2025-01-01T00:00:00Z' }, // >1 year
    { id: 'c' },                              // undated → never stale
  ];
  assert.deepEqual(P.selectStaleIntakeRows(rows, 6, now).map(r => r.id), ['b']);
  assert.deepEqual(P.selectStaleIntakeRows(rows, 0, now), [], 'disabled retention → nothing');
  assert.deepEqual(P.selectStaleIntakeRows(rows, null, now), []);
  assert.deepEqual(P.selectStaleIntakeRows(null, 6, now), []);
});

test('anonymizeIntakeRow strips PII but keeps the row', () => {
  const r = P.anonymizeIntakeRow({ id: 'W1', name: 'Sara', email: 's@x.com', phone: '+9665', description: 'a vase' });
  assert.equal(r.name, '[erased]');
  assert.equal(r.email, undefined);
  assert.equal(r.phone, undefined);
  assert.equal(r.description, 'a vase', 'non-PII operational detail retained');
  assert.ok(r.anonymizedAt);
});

/* ── Cross-subject isolation (PDPL: never disclose or erase another subject) ── */

const COLLIDING = () => ({
  clients: [
    { id: 'A', nameEn: 'Mohammed', email: 'shared@family.com', phone: '+966500000001' },
    { id: 'B', nameEn: 'Mohammed', email: 'shared@family.com', phone: '+966500000002' },
  ],
  printLog: [
    { id: 'OA', clientId: 'A', date: '2026-01-01', project: 'A order', status: 'completed', price: 1 },
    { id: 'OB', clientId: 'B', date: '2026-01-02', project: 'B order', status: 'completed', price: 2 },
  ],
  waitingList: [
    { id: 'W-A', name: 'Mohammed', email: 'shared@family.com', at: '2026-01-01' },       // unlinked, shared email
    { id: 'W-B', clientId: 'B', name: 'Mohammed', email: 'shared@family.com', at: '2026-01-02' },
  ],
  waitingListHistory: [],
});

test('export never includes a row explicitly linked to a DIFFERENT client', () => {
  const a = P.buildClientDataExport('A', COLLIDING());
  const ids = a.intakeSubmissions.map(r => r.id);
  assert.equal(ids.includes('W-B'), false, 'unlawful disclosure: another subject’s row');
  assert.deepEqual(a.orders.map(o => o.id), ['OA'], 'and never another subject’s orders');
});

test('full erase never purges a row belonging to a different client', () => {
  const plan = P.planClientErasure('A', COLLIDING(), 'full');
  assert.equal(plan.purgeIntakeIds.includes('W-B'), false, 'unlawful erasure of another subject');
  assert.deepEqual(plan.purgeIntakeIds, ['W-A']);
});

test('a shared name alone never matches — only strong identifiers do', () => {
  const c = {
    clients: [{ id: 'A', nameEn: 'Mohammed', email: 'a@example.com', phone: '+9665001' }],
    printLog: [], waitingListHistory: [],
    waitingList: [
      { id: 'name-only', name: 'Mohammed', at: '2026-01-01' },            // same name, different person
      { id: 'by-email', email: 'a@example.com', at: '2026-01-02' },
      { id: 'by-phone', phone: '+9665001', at: '2026-01-03' },
    ],
  };
  const ids = P.buildClientDataExport('A', c).intakeSubmissions.map(r => r.id);
  assert.equal(ids.includes('name-only'), false, 'name collisions must not match');
  assert.deepEqual(ids.sort(), ['by-email', 'by-phone']);
});

test('a row linked to THIS client matches even if its contact details differ', () => {
  const c = {
    clients: [{ id: 'A', nameEn: 'Sara', email: 'new@example.com' }],
    printLog: [], waitingListHistory: [],
    waitingList: [{ id: 'linked', clientId: 'A', email: 'old@example.com', at: '2026-01-01' }],
  };
  const ids = P.buildClientDataExport('A', c).intakeSubmissions.map(r => r.id);
  assert.deepEqual(ids, ['linked'], 'explicit link wins over stale contact details');
});

// ── Full erase never rewrites an issued invoice ─────────────────────────────
// Full erase used to blank the buyer on EVERY one of the customer's jobs, so an
// invoice already issued (and ZATCA-submitted) changed its buyer after the fact.
// Now a job lib/record-delete.js would refuse to delete keeps its name.
const ERASE_BOOK = () => ({
  clients: [{ id: 'C1', nameEn: 'Sara Noor' }],
  printLog: [
    { id: 'Q1', clientId: 'C1', status: 'quote', client: 'Sara Noor' },
    { id: 'J1', clientId: 'C1', status: 'completed', client: 'Sara Noor', invoiceNum: 'INV-2026-0007' },
    { id: 'J2', clientId: 'C1', status: 'completed', client: 'Sara Noor', zatcaUuid: 'u-1' },
    { id: 'J3', clientId: 'C1', status: 'pending', client: 'Sara Noor', paidAmount: 50 },
  ],
  waitingList: [], waitingListHistory: [],
});

test('full erase blanks the name only where no invoice or payment exists', () => {
  const p = P.planClientErasure('C1', ERASE_BOOK(), 'full');
  assert.deepEqual(p.blankNameOrderIds, ['Q1']);
  assert.deepEqual(p.keepNameOrderIds, ['J1', 'J2', 'J3'], 'an issued invoice would change its buyer');
  assert.equal(p.counts.keptNames, 3);
});

test('unlink blanks nothing', () => {
  const p = P.planClientErasure('C1', ERASE_BOOK(), 'unlink');
  assert.deepEqual(p.blankNameOrderIds, []);
  assert.equal(p.counts.keptNames, 0);
});

test('without lib/record-delete.js every job keeps its name', () => {
  // A host that did not load the rule must not fall back to blanking everything.
  const vm = require('node:vm');
  const src = require('node:fs').readFileSync(require.resolve('../lib/privacy.js'), 'utf8');
  const ctx = vm.createContext({});
  vm.runInContext(src, ctx);
  const p = ctx.KhaytPrivacy.planClientErasure('C1', ERASE_BOOK(), 'full');
  assert.deepEqual(Array.from(p.blankNameOrderIds), []);
  assert.equal(p.keepNameOrderIds.length, 4);
});

test('the desktop blanks only the jobs the plan names', () => {
  const src = require('node:fs').readFileSync(require.resolve('../renderer/clients.js'), 'utf8');
  const at = src.indexOf('async function deleteClient(');
  const body = src.slice(at, src.indexOf('\n}', at));
  assert.match(body, /plan\.blankNameOrderIds/, 'deleteClient decides for itself which names to blank');
  assert.doesNotMatch(body, /if \(fullErase\) \{ priorNames\.set/, 'every job is blanked on a full erase again');
});

test('gift cards and loyalty rows are in the export, and a full erase unlinks only what owes nothing', () => {
  const collections = {
    clients: [{ id: 'C1', nameEn: 'Nora', email: 'n@x.sa' }, { id: 'C2', nameEn: 'Other' }],
    printLog: [],
    giftCards: [
      { id: 'GC-SPENT', code: 'AAA', initialBalance: 50, balance: 0, issuedTo: 'C1', issuedToName: 'Nora' },
      { id: 'GC-LEFT', code: 'BBB', initialBalance: 50, balance: 12.5, issuedTo: 'C1', issuedToName: 'Nora' },
      { id: 'GC-OTHER', code: 'CCC', initialBalance: 20, balance: 0, issuedTo: 'C2', issuedToName: 'Other' },
    ],
    loyaltyLedger: [
      { id: 'L1', clientId: 'C1', type: 'redeem', points: 500, credit: 5 },
      { id: 'L2', clientId: 'C2', type: 'redeem', points: 100, credit: 1 },
    ],
  };
  const exp = P.buildClientDataExport('C1', collections, '2026-10-21T00:00:00Z');
  assert.deepEqual(exp.giftCards.map(g => g.id), ['GC-SPENT', 'GC-LEFT']);
  assert.equal(exp.giftCards[1].balance, 12.5);
  assert.deepEqual(exp.loyaltyLedger.map(r => r.id), ['L1']);
  assert.equal(exp.counts.giftCards, 2);
  assert.equal(exp.counts.loyaltyLedger, 1);

  const full = P.planClientErasure('C1', collections, 'full');
  assert.deepEqual(full.unlinkGiftCardIds, ['GC-SPENT'], 'a spent card loses its holder');
  assert.deepEqual(full.keepGiftCardIds, ['GC-LEFT'], 'a card with a balance is money owed, and keeps the name');
  assert.equal(full.counts.keptCards, 1);
  assert.equal(full.unlinkLoyaltyLedger, true);
  assert.equal(full.counts.loyaltyLedger, 1);

  const unlink = P.planClientErasure('C1', collections, 'unlink');
  assert.deepEqual(unlink.unlinkGiftCardIds, []);
  assert.equal(unlink.unlinkLoyaltyLedger, false);
  // Without the two collections (an older caller) nothing is touched.
  const bare = P.planClientErasure('C1', { clients: collections.clients, printLog: [] }, 'full');
  assert.deepEqual(bare.unlinkGiftCardIds, []);
  assert.equal(bare.unlinkLoyaltyLedger, false);
});
