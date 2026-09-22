const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/storefront-orders.js');

/*
 * An order that arrives twice from a storefront is one order.
 *
 * Salla and Zid POST a signed webhook when an order is placed, and each delivery
 * became a fresh row with a fresh random id — the platform's own reference went
 * into free text. The only thing between a retry and a duplicate order was
 * `isReplayedWebhook`, whose own comment describes it accurately: "per-process
 * (cleared on restart) and capped in size", ten-minute TTL.
 *
 * Every one of those limits is an ordinary event. Providers retry, byte for
 * byte, which is the only reason a signature cache ever matches. Shops close the
 * app at night. Five hundred webhooks evict an entry. Ten minutes pass.
 *
 * Then the shop has the same job in its queue twice — printed twice, or invoiced
 * twice. The durable check is the platform's own id against the print log, which
 * is on disk.
 */

const sallaPayload = (ref) => ({
  data: { reference_id: ref, name: 'Order 12', total: 250, customer: { first_name: 'A', last_name: 'B' } },
});
const zidPayload = (ref, id) => ({ order: { reference_id: ref, id, name: 'Order 12', total: 250 } });

test('each platform’s own order id is found where that platform puts it', () => {
  assert.equal(S.sourceOrderIdFrom('salla', sallaPayload('SL-991')), 'SL-991');
  assert.equal(S.sourceOrderIdFrom('zid', zidPayload('ZD-4', 77)), 'ZD-4');
  // Zid may send only the numeric id, which is what the notes line already fell
  // back to — so the dedup key and the note stay the same string.
  assert.equal(S.sourceOrderIdFrom('zid', zidPayload(undefined, 77)), '77');
  assert.equal(S.sourceOrderIdFrom('salla', {}), '');
  assert.equal(S.sourceOrderIdFrom('shopify', sallaPayload('X')), '', 'an unknown platform must not guess');
  assert.equal(S.sourceOrderIdFrom('salla', null), '');
});

test('a second delivery of the same order is recognised', () => {
  const log = [{ id: 'salla_a', source: 'salla', sourceOrderId: 'SL-991' }];
  assert.equal(S.alreadyRecorded(log, 'salla', 'SL-991'), true);
  assert.equal(S.alreadyRecorded(log, 'salla', 'SL-992'), false, 'a genuinely different order was dropped');
});

test('the same reference on a different platform is a different order', () => {
  // Two storefronts numbering their own orders from 1 is not a collision to
  // resolve — they are unrelated orders that happen to share a string.
  const log = [{ id: 'salla_a', source: 'salla', sourceOrderId: '1001' }];
  assert.equal(S.alreadyRecorded(log, 'zid', '1001'), false);
  assert.equal(S.alreadyRecorded(log, 'salla', '1001'), true);
});

test('an order with NO id is never deduped against another', () => {
  // The dangerous direction. Two payloads that both failed to name themselves
  // are not thereby the same order, and folding them together would silently
  // drop a real second order — worse than the duplicate this prevents, because
  // nothing about it is visible.
  const log = [{ id: 'salla_a', source: 'salla', sourceOrderId: undefined, notes: 'Salla order #' }];
  assert.equal(S.alreadyRecorded(log, 'salla', ''), false);
  assert.equal(S.alreadyRecorded(log, 'salla', null), false);
  assert.equal(S.alreadyRecorded([], 'salla', 'SL-1'), false);
  assert.equal(S.alreadyRecorded(null, 'salla', 'SL-1'), false);
});

test('orders recorded before the field existed are still recognised', () => {
  // Without this the fix protects only orders arriving from now on, and a shop's
  // existing queue — where a duplicate is most annoying — keeps collecting them.
  // The string being parsed is one Khayt wrote itself, in the format noteFor()
  // defines, so the two cannot drift.
  const legacy = [
    { id: 'salla_a', source: 'salla', notes: 'Salla order #SL-991' },
    { id: 'zid_a', source: 'zid', notes: 'Zid order #ZD-4' },
  ];
  assert.equal(S.alreadyRecorded(legacy, 'salla', 'SL-991'), true);
  assert.equal(S.alreadyRecorded(legacy, 'zid', 'ZD-4'), true);
  assert.equal(S.alreadyRecorded(legacy, 'salla', 'SL-000'), false);

  assert.equal(S.recordedNoteRef({ notes: 'Salla order #SL-991' }), 'SL-991');
  assert.equal(S.recordedNoteRef({ notes: 'Zid order #ZD-4' }), 'ZD-4');
  // A note the shop typed is not an order reference.
  assert.equal(S.recordedNoteRef({ notes: 'customer wants it matte' }), '');
  assert.equal(S.recordedNoteRef({ notes: 'Salla order #' }), '', 'an empty ref is not a ref');
  assert.equal(S.recordedNoteRef({}), '');
  assert.equal(S.recordedNoteRef(null), '');
});

test('the note and the dedup key are built from one function', () => {
  // They were two copies of the same string in two handlers. If they drift, a
  // legacy order stops being recognisable by the very reference it displays.
  assert.equal(S.noteFor('salla', 'SL-991'), 'Salla order #SL-991');
  assert.equal(S.noteFor('zid', 'ZD-4'), 'Zid order #ZD-4');
  for (const [source, ref] of [['salla', 'SL-991'], ['zid', 'ZD-4']]) {
    assert.equal(S.recordedNoteRef({ notes: S.noteFor(source, ref) }), ref,
      'a note this module writes must be one it can read back');
  }
});

test('the whole round trip: deliver, retry, restart, retry again', () => {
  // The sequence that produced the bug. The signature cache is assumed gone
  // throughout — that is the point.
  const payload = sallaPayload('SL-991');
  const ref = S.sourceOrderIdFrom('salla', payload);
  const log = [];

  assert.equal(S.alreadyRecorded(log, 'salla', ref), false, 'first delivery must be recorded');
  log.unshift({ id: 'salla_1', source: 'salla', sourceOrderId: ref, notes: S.noteFor('salla', ref) });

  // Provider retries because our 200 was slow to arrive.
  assert.equal(S.alreadyRecorded(log, 'salla', ref), true);
  // App restarts; the log is read back off disk, the cache is not.
  const afterRestart = JSON.parse(JSON.stringify(log));
  assert.equal(S.alreadyRecorded(afterRestart, 'salla', ref), true);
  // A genuinely new order still gets through.
  assert.equal(S.alreadyRecorded(afterRestart, 'salla', 'SL-992'), false);
});

/* ── how it is wired ────────────────────────────────────────────────────── */

const fs = require('fs');
const path = require('path');
const lan = fs.readFileSync(path.join(__dirname, '..', 'lib', 'lan-server.js'), 'utf8');

test('both storefront handlers check before they create, and record the id', () => {
  // The failure this guards is a THIRD platform handler written by copying one
  // of these two — which is how both of them came to build an order inline with
  // a random id in the first place.
  for (const source of ['salla', 'zid']) {
    const at = lan.indexOf(`sourceOrderIdFrom('${source}'`);
    assert.ok(at > 0, `the ${source} handler does not read the platform's order id`);
    // The window is generous on purpose. It was 1400 and the handlers outgrew it
    // the moment they gained a few lines of comment, which fails this guard for
    // a reason that has nothing to do with what it checks — a test that breaks
    // on prose is a test people learn to edit rather than read.
    const body = lan.slice(at, at + 3000);
    const check = body.indexOf(`alreadyRecorded(storeData.printLog, '${source}'`);
    // `log.unshift(recorded)`, not `newOrder`: what goes in the book is the
    // order AFTER the shelf has been read against it — `fromStock`, the
    // status and the note all come from there. See the next assertion.
    const create = body.indexOf('log.unshift(recorded)');
    assert.ok(check > 0, `the ${source} handler does not check for a duplicate`);
    assert.ok(create > 0, `the ${source} handler no longer creates an order here`);
    assert.ok(check < create, `the ${source} handler creates the order before checking for it`);
    // The check answering the request is not enough. A provider retry arriving
    // while the first write is still in flight reads a log that has not been
    // updated yet and passes it, so the check has to be repeated INSIDE the
    // write, against the store as it stands when that write's turn comes.
    const inWrite = body.indexOf(`alreadyRecorded(log, '${source}'`);
    assert.ok(inWrite > 0,
      `the ${source} handler does not re-check for a duplicate inside updateStoreOnDisk`);
    assert.ok(inWrite < create,
      `the ${source} handler inserts before re-checking inside the write`);
    assert.match(body, /sourceOrderId: \w+Ref \|\| undefined/,
      `the ${source} handler does not record the id, so the NEXT delivery cannot be recognised`);
    assert.match(body, /notes:\s+storefrontOrders\.noteFor\(/,
      `the ${source} handler writes its own note string instead of the shared one`);

    // ── AND THE SHELF IS READ INSIDE THE SAME WRITE ───────────────────
    //
    // An online order for something already printed is a sale: it comes off
    // `settings.storefront.stockQty`, which is the count the storefront
    // publishes and sells against. Doing that outside `updateStoreOnDisk`
    // would be a read-modify-write racing the duplicate check beside it —
    // two deliveries arriving together would each read the same figure and
    // each write their own.
    const shelf = body.indexOf(`takeOnlineOrderOffTheShelf('${source}'`);
    assert.ok(shelf > 0,
      `the ${source} handler does not read the shelf, so an order for a piece `
      + 'already made still goes to a machine and the published count stays wrong');
    assert.ok(check < shelf && shelf < create,
      `the ${source} handler reads the shelf outside the checked write`);
  }
});

/*
 * What the desktop is TOLD is what was written, not what was drafted.
 *
 * `lan-order-updated` carried `newOrder` — the record built before the write
 * chain ran — so the queue was told 'pending' about an order the book had just
 * recorded as completed off the shelf.
 */
test('the window is sent the order that was written', () => {
  assert.ok(!/lan-order-updated', newOrder\)/.test(lan),
    'a storefront handler tells the window about its draft rather than its record');
  assert.equal((lan.match(/lan-order-updated', recorded\)/g) || []).length, 2,
    'both storefront handlers should send the record they wrote');
});

test('a duplicate answers 200, so the provider stops retrying', () => {
  // Not 409. A retry is the provider asking "did you get this?", and the honest
  // answer is yes — the order is recorded. A non-2xx tells it to try again, and
  // on some platforms eventually to mark the delivery failed and alert the shop
  // about a webhook that is working perfectly.
  for (const source of ['salla', 'zid']) {
    const at = lan.indexOf(`alreadyRecorded(storeData.printLog, '${source}'`);
    const body = lan.slice(at, at + 400);
    assert.match(body, /writeHead\(200/, `a duplicate ${source} delivery is answered with a non-2xx`);
    assert.match(body, /duplicate: true/, `the ${source} response does not say it was a duplicate`);
  }
});

/**
 * What the order is WORTH, which is the field a shop is actually measured in.
 *
 * The fixture below is Salla's own published webhook sample, trimmed. It is
 * used rather than an invented one for the same reason the Repetier tests are:
 * a payload we made up would have agreed with the code that was wrong.
 */
const SALLA_ORDER = {
  event: 'order.created',
  merchant: 1305146709,
  data: {
    id: 2116149737,
    reference_id: 41027662,
    currency: 'SAR',
    amounts: {
      sub_total: { amount: 186, currency: 'SAR' },
      shipping_cost: { amount: 15, currency: 'SAR' },
      cash_on_delivery: { amount: 0, currency: 'SAR' },
      total: { amount: 196, currency: 'SAR' },
    },
    items: [{ id: 70815337, name: 'بيتزا', sku: '54534534', quantity: 1 }],
    customer: { id: 225167971, first_name: 'Mohammed', last_name: 'Ali', email: 'usertest@gmail.com' },
  },
};

test('a Salla order is worth what Salla says it is worth', () => {
  // THE DEFECT: this used to read `data.total`, which does not exist anywhere
  // in a Salla payload — the top-level keys of `data` are id, reference_id,
  // urls, date, draft, read, source, source_device, source_details, status,
  // receipt_image, payment_method, currency, amounts, shipping, items,
  // customer. Number(undefined) is NaN, isFinite(NaN) is false, and the guard
  // substituted 0. Every Salla order ever imported was priced at zero.
  assert.equal(S.orderPriceFrom('salla', SALLA_ORDER), 196);
  assert.equal(SALLA_ORDER.data.total, undefined, 'the field the old code read');

  // The total is an OBJECT, so a bare Number() could never have worked even
  // against the right key.
  assert.equal(S.money({ amount: 196, currency: 'SAR' }), 196);
  assert.equal(S.money(196), 196, 'a plain number is equally ordinary');

  // It must be the TOTAL, not the first amount that happens to parse. sub_total
  // here is 186 and would look perfectly plausible on an invoice.
  assert.notEqual(S.orderPriceFrom('salla', SALLA_ORDER), 186);
});

test('"I could not read the price" is never reported as "it is free"', () => {
  // A guard that turns unknown into 0 is worse than no guard: 0 is a number a
  // shop can act on. money() and orderPriceFrom() return null instead, and the
  // caller decides — which is what makes the difference visible at all.
  assert.equal(S.orderPriceFrom('salla', { data: {} }), null);
  assert.equal(S.orderPriceFrom('salla', {}), null);
  assert.equal(S.money(undefined), null);
  assert.equal(S.money(''), null);
  assert.equal(S.money({}), null);
  assert.equal(S.money('not a number'), null);
  assert.equal(S.money(-5), null, 'a negative total is not a total');
  assert.equal(S.money(0), 0, 'but a genuine zero is a real answer and survives');
});

test('a Salla order is titled something a shop can tell apart', () => {
  // `data.name` does not exist either, so `data.name || 'Order'` made every
  // order in the queue read "Salla: Order".
  assert.equal(SALLA_ORDER.data.name, undefined);
  assert.equal(S.orderTitleFrom('salla', SALLA_ORDER), 'بيتزا');

  // More than one line item says so rather than naming only the first.
  const two = { data: { ...SALLA_ORDER.data, items: [{ name: 'A' }, { name: 'B' }] } };
  assert.equal(S.orderTitleFrom('salla', two), 'A +1');

  // With no items at all, the reference identifies the order; the word "Order"
  // does not. It is the last resort, not the first.
  assert.equal(S.orderTitleFrom('salla', { data: { reference_id: 41027662 } }), '#41027662');
  assert.equal(S.orderTitleFrom('salla', { data: {} }), 'Order');

  assert.equal(S.customerNameFrom('salla', SALLA_ORDER), 'Mohammed Ali');
});

test('Zid is read whether or not the order is wrapped', () => {
  // This audit could NOT confirm Zid's payload shape: its webhook schema is
  // rendered by a docs component that does not come out as text, and its own
  // sample apps carry no fixture. The code assumed `{order:{…}}`. Rather than
  // keep betting on that, both shapes are accepted — if the wrapper is there
  // nothing changes, and if it is not, Zid starts working instead of recording
  // an unnamed order priced at zero with no reference to deduplicate on.
  const wrapped = { order: { id: 9, reference_id: 'Z-1', total: 250, customer: { name: 'Sara' }, items: [{ name: 'Bracket' }] } };
  const flat = wrapped.order;

  for (const [label, payload] of [['wrapped', wrapped], ['top level', flat]]) {
    assert.equal(S.sourceOrderIdFrom('zid', payload), 'Z-1', label);
    assert.equal(S.orderPriceFrom('zid', payload), 250, label);
    assert.equal(S.orderTitleFrom('zid', payload), 'Bracket', label);
    assert.equal(S.customerNameFrom('zid', payload), 'Sara', label);
  }

  // Several spellings of the total are accepted, since only one is ever present
  // and which one was never verified.
  assert.equal(S.orderPriceFrom('zid', { order: { order_total: 99 } }), 99);
  assert.equal(S.orderPriceFrom('zid', { order: { amounts: { total: { amount: 42 } } } }), 42);

  // An unrelated body must not donate stray fields just because it is not wrapped.
  assert.deepEqual(S.orderObject('zid', { hello: 'world' }), {});
  assert.equal(S.orderPriceFrom('zid', { hello: 'world' }), null);
});
