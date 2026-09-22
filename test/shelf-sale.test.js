const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/shelf-sale.js');

/*
 * An online order for something already printed is a sale, not a job.
 *
 * Three doors let an online order into Khayt — the LAN server's signed Salla
 * and Zid webhooks, khayt-cloud's import route, and the desktop's Order
 * requests screen — and none of them ever looked at `settings.storefront
 * .stockQty`. That number is what the storefront publishes and sells against,
 * and the only thing that has ever written it is a person typing it in.
 *
 * So a shop that printed twelve, listed twelve and sold four went on
 * advertising twelve until a customer bought the thirteenth.
 */

const products = [
  { id: 'PRD-A', nameEn: 'Flexi Dragon', nameAr: 'تنين مرن' },
  { id: 'PRD-B', nameEn: 'Falcon hood', nameAr: 'غطاء الصقر' },
  { id: 'PRD-C', nameEn: 'Turbine bracket', nameAr: '' },
];
const stock = { 'PRD-A': 12, 'PRD-B': 4, 'PRD-C': 0 };
const book = { products, stock };

/** The shape khayt-cloud's mapPlatformOrder actually files. */
const order = (desc, extra) => Object.assign(
  { title: 'Salla order — SL-991', description: desc, qty: '', source: 'salla', ref: 'salla:SL-991' },
  extra || {});

test('the basket is read back out of the line khayt-cloud writes', () => {
  const got = S.lines(order('• Flexi Dragon × 2\n• Falcon hood'));
  assert.deepEqual(got, [
    { name: 'Flexi Dragon', qty: 2 },
    { name: 'Falcon hood', qty: 1 },
  ]);
});

test('a shop note after the basket is not mistaken for an item', () => {
  const got = S.lines(order('• Flexi Dragon × 2\n\nPlease post it before Thursday'));
  assert.deepEqual(got, [{ name: 'Flexi Dragon', qty: 2 }]);
});

test('a request with no basket is still one line, and still checked', () => {
  const got = S.lines({ title: 'Flexi Dragon', description: '', qty: '3' });
  assert.deepEqual(got, [{ name: 'Flexi Dragon', qty: 3 }]);
});

test('a line matches the product in either language', () => {
  assert.equal(S.matchLine('Flexi Dragon', products), 'PRD-A');
  assert.equal(S.matchLine('تنين مرن', products), 'PRD-A');
  assert.equal(S.matchLine('  FLEXI   dragon ', products), 'PRD-A');
});

/*
 * THE REFUSAL. A near-match would deduct the wrong shelf, and a deduction is
 * invisible once made: the number it leaves behind looks exactly like a number
 * somebody counted. An unplaceable line is handed back unplaced.
 */
test('a name this shop does not sell matches nothing, and is not guessed at', () => {
  assert.equal(S.matchLine('Flexi Dragons', products), null);
  assert.equal(S.matchLine('Dragon', products), null);
  assert.equal(S.matchLine('', products), null);
  const r = S.read(order('• Benchy × 1'), book);
  assert.equal(r.unmatched, 1);
  assert.equal(r.lines[0].productId, null);
  assert.equal(r.lines[0].fromShelf, 0, 'an unrecognised line took something off a shelf');
  assert.equal(r.lines[0].toPrint, 1);
  assert.equal(S.effects(r, '2026-09-22T10:00:00Z').filter((e) => e.type === 'deduct').length, 0);
});

test('what the shelf can answer, and what still has to be printed', () => {
  const r = S.read(order('• Flexi Dragon × 2\n• Falcon hood × 6\n• Turbine bracket × 1'), book);
  assert.deepEqual(r.lines.map((l) => [l.productId, l.fromShelf, l.toPrint]), [
    ['PRD-A', 2, 0],
    ['PRD-B', 4, 2],   // four on the shelf, two to make
    ['PRD-C', 0, 1],   // none on the shelf
  ]);
  assert.equal(r.fromShelf, 6);
  assert.equal(r.toPrint, 3);
  assert.equal(r.allFromShelf, false);
});

test('an order the shelf answers in full puts nothing in the queue', () => {
  const r = S.read(order('• Flexi Dragon × 2'), book);
  assert.equal(r.allFromShelf, true);
  assert.deepEqual(S.effects(r, '2026-09-22T10:00:00Z'),
    [{ type: 'deduct', productId: 'PRD-A', taken: 2, to: 10, countedAt: '2026-09-22T10:00:00Z' }]);
});

/*
 * THE ONE THAT NEEDS THE TEST.
 *
 * A basket can name the same product twice — a storefront splits by variant, or
 * the customer added it a second time. Read line by line against the shelf,
 * both lines see the same four items and the shop promises eight.
 */
test('two lines naming one product share the shelf rather than each taking all of it', () => {
  const r = S.read(order('• Falcon hood × 3\n• Falcon hood × 2'), book);
  assert.deepEqual(r.lines.map((l) => [l.onShelf, l.fromShelf, l.toPrint]), [
    [4, 3, 0],
    [1, 1, 1],
  ]);
  assert.equal(r.fromShelf, 4, 'five came off a shelf holding four');
  assert.equal(r.toPrint, 1);
  const deducts = S.effects(r, 'now').filter((e) => e.type === 'deduct');
  assert.equal(deducts.length, 1, 'one product, two writes — the second would race the first');
  assert.deepEqual(deducts[0], { type: 'deduct', productId: 'PRD-B', taken: 4, to: 0, countedAt: 'now' });
});

test('a shelf can never be driven below nothing', () => {
  const r = S.read(order('• Turbine bracket × 5'), { products, stock: { 'PRD-C': -3 } });
  assert.equal(r.lines[0].onShelf, 0);
  assert.equal(r.lines[0].fromShelf, 0);
  assert.equal(r.lines[0].toPrint, 5);
});

test('what still has to be printed is named, so the queue can be written from it', () => {
  const r = S.read(order('• Falcon hood × 6\n• Benchy × 2'), book);
  const queue = S.effects(r, 'now').find((e) => e.type === 'queue');
  assert.deepEqual(queue.lines, [
    { name: 'Falcon hood', qty: 2, productId: 'PRD-B' },
    { name: 'Benchy', qty: 2, productId: null },
  ]);
});

/*
 * A storefront and a catalogue spell the same thing differently: Arabic-Indic
 * digits, a tatweel somebody stretched a heading with, a zero-width character a
 * web form left behind. None of those is a different product.
 */
test('two spellings of one name are one name', () => {
  assert.equal(S.key('٢ تنين'), S.key('2 تنين'));
  assert.equal(S.key('تنيــن'), S.key('تنين'));
  assert.equal(S.key('Flexi​Dragon'), S.key('FlexiDragon'));
});

test('an empty order asks for nothing rather than for everything', () => {
  const r = S.read({}, book);
  assert.deepEqual(r.lines, []);
  assert.equal(r.allFromShelf, false, 'an order with no lines is not "all on the shelf"');
  assert.deepEqual(S.effects(r, 'now'), []);
});

/*
 * ── A BASKET HAS AN END ───────────────────────────────────────────────────
 *
 * This runs over an order that arrives from OUTSIDE — khayt-cloud's import
 * route takes a storefront's delivery and files it, and the Mac then reads it
 * on its main actor. The cloud caps a description at 4000 characters, but
 * `lib/lan-server.js` reads a platform's own payload through `itemLines`,
 * where nothing caps anything.
 *
 * Unbounded, a long basket against a real catalogue was quadratic: every line
 * normalised every product name again, each an NFKC pass and four regexes.
 * Forty thousand lines against sixty products measured 455ms; against a
 * five-hundred-product catalogue it is seconds, with the window frozen.
 *
 * Two bounds fix it — this cap, and indexing the catalogue once.
 */
test('a basket is bounded, however long the delivery claims to be', () => {
  const huge = Array.from({ length: 40000 }, () => '• Flexi Dragon × 1').join('\n');
  const t = Date.now();
  const r = S.read({ description: huge }, book);
  const ms = Date.now() - t;
  assert.equal(r.lines.length, S.MAX_LINES);
  assert.ok(ms < 1000, `reading a 40,000-line basket took ${ms}ms`);
});

test('a platform sending its own basket is bounded the same way', () => {
  const items = Array.from({ length: 40000 }, () => ({ name: 'Flexi Dragon', quantity: 1 }));
  assert.equal(S.itemLines(items).length, S.MAX_LINES);
});

/*
 * The catalogue is indexed ONCE per reading rather than re-normalised per
 * line. Two products can share a name — a shop duplicates a row and renames
 * one later — and the index must resolve that the same way every time rather
 * than by whichever came first in the array on the day.
 */
test('two products sharing a name resolve to the same one every time', () => {
  const twins = [
    { id: 'PRD-X', nameEn: 'Falcon hood' },
    { id: 'PRD-Y', nameEn: 'Falcon hood' },
  ];
  const match = S.matcher(twins);
  assert.equal(match('Falcon hood'), 'PRD-X');
  assert.equal(match('falcon  HOOD'), 'PRD-X');
  assert.equal(S.matchLine('Falcon hood', twins), 'PRD-X');
});

test('a product with no id is not indexed, and neither is a blank name', () => {
  const messy = [
    { nameEn: 'No id here' },
    { id: 'PRD-Z', nameEn: '', nameAr: '' },
    { id: 'PRD-W', nameEn: 'Real one' },
  ];
  const match = S.matcher(messy);
  assert.equal(match('No id here'), null);
  assert.equal(match(''), null);
  assert.equal(match('Real one'), 'PRD-W');
});
