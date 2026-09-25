'use strict';

/**
 * The storefront catalogue, built once for every host (lib/storefront-catalog.js).
 * Moved out of renderer/settings.js so the native Mac app publishes the same
 * payload; checked byte-for-byte against the old builder when it moved.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
for (const m of ['content-languages', 'product-images', 'product-specs', 'organise']) require(`../lib/${m}.js`);
const SC = require('../lib/storefront-catalog.js');

const thumb = (s) => 'data:image/jpeg;base64,' + Buffer.from(s).toString('base64');
const settings = (sf) => ({ currency: 'SAR', contentLangs: ['en', 'ar'], storefront: sf || {} });

test('the catalogue\'s own price is the price; a storefront entry overrides it, and 0 is a price', () => {
  const out = SC.build({ settings: settings({ prices: { b: '0', c: '12' } }), products: [
    { id: 'a', nameEn: 'A', price: 50 }, { id: 'b', nameEn: 'B', price: 50 }, { id: 'c', nameEn: 'C', basePrice: 9 }, { id: 'd', nameEn: 'D' },
  ] });
  assert.deepEqual(out.items.map((i) => i.price), ['50', '0', '12', undefined]);
});

test('category and group come from the product, and a storefront category overrides', () => {
  const out = SC.build({ settings: settings({ categories: { b: 'Gifts' } }), products: [
    { id: 'a', nameEn: 'A', category: 'Toys', group: 'Beasts' }, { id: 'b', nameEn: 'B', category: 'Toys', folder: 'Old set' },
  ] });
  assert.equal(out.items[0].category, 'Toys'); assert.equal(out.items[0].group, 'Beasts');
  assert.equal(out.items[1].category, 'Gifts'); assert.equal(out.items[1].group, 'Old set');
});

test('stock: empty means made to order, 0 is a sold-out batch', () => {
  const out = SC.build({ settings: settings({ stockQty: { b: 0, c: 3 }, stockCountedAt: { c: '2026-09-01T00:00:00Z' } }),
    products: [{ id: 'a', nameEn: 'A' }, { id: 'b', nameEn: 'B' }, { id: 'c', nameEn: 'C' }] });
  assert.equal('stockQty' in out.items[0], false);
  assert.equal(out.items[1].stockQty, 0);
  assert.equal(out.items[2].stockCountedAt, '2026-09-01T00:00:00Z');
});

test('options parse to groups, capped, and only well-formed ones survive', () => {
  assert.deepEqual(SC.parseOptionGroups('Color: Black, White; Size: S, M; junk; Empty:'),
    [{ name: 'Color', values: ['Black', 'White'] }, { name: 'Size', values: ['S', 'M'] }]);
  assert.equal(SC.parseOptionGroups(Array.from({ length: 9 }, (_, i) => `G${i}: v`).join(';')).length, 5);
});

test('photos: a hero where the host supplied one, none at all when photos are off', () => {
  const products = [{ id: 'a', nameEn: 'A', images: [{ id: 'i', path: 'a.jpg', thumbnail: thumb('t'), kind: 'print' }] }];
  const HERO = thumb('HERO');
  const on = SC.build({ settings: settings(), products, heroes: { 'a.jpg': HERO } });
  assert.equal(on.items[0].photos.length, 1);
  assert.ok(JSON.stringify(on.items[0].photos).includes(HERO), 'the host\'s hero is used');
  assert.equal('photo' in on.items[0], false, 'photo is derived by the server, never sent');
  const mapHeroes = SC.build({ settings: settings(), products, heroes: new Map([['a.jpg', HERO]]) });
  assert.deepEqual(mapHeroes.items[0].photos, on.items[0].photos, 'a Map and a plain object are the same');
  assert.equal('photos' in SC.build({ settings: settings(), products, withPhotos: false }).items[0], false);
});

test('at most 60 listings, and a product with no readable name is not one', () => {
  const many = Array.from({ length: 70 }, (_, i) => ({ id: 'p' + i, nameEn: 'P' + i }));
  assert.equal(SC.build({ settings: settings(), products: many }).items.length, 60);
  const out = SC.build({ settings: settings(), products: [{ id: 'x', nameEn: '' }, { id: 'y', nameAr: 'كرسي' }] });
  assert.deepEqual(out.items.map((i) => i.id), ['y']);
});

test('the shop-level fields, and a pay link that is not a web address is dropped', () => {
  const out = SC.build({ settings: settings({ payUrl: 'javascript:alert(1)', depositPct: 20, note: 'n' }), products: [], shopName: '  Shop  ', lang: 'ar' });
  assert.equal(out.shopName, 'Shop'); assert.equal(out.lang, 'ar'); assert.equal(out.currency, 'SAR');
  assert.equal(out.payUrl, ''); assert.equal(out.depositPct, 20);
  assert.deepEqual(out.langs, ['en', 'ar']);
  assert.equal(SC.build({ settings: settings(), products: [] }).shopName, 'Khayt');
});

test('the desktop publishes through the module, and both pages load it', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'settings.js'), 'utf8');
  const body = src.slice(src.indexOf('const buildCatalog = async'), src.indexOf("modal.querySelector('#storeCopy')"));
  assert.match(body, /SC\.build\(\{/);
  assert.doesNotMatch(body, /items: pubProducts\.map/, 'a second builder is still in the renderer');
  for (const html of ['index.html', 'bedready.html']) {
    assert.match(fs.readFileSync(path.join(__dirname, '..', 'renderer', html), 'utf8'),
      /<script src="\.\.\/lib\/storefront-catalog\.js"><\/script>/, html);
  }
});

test('a product the shop hides is not published, and does not cost a real one its place', () => {
  const many = Array.from({ length: 61 }, (_, i) => ({ id: 'p' + i, nameEn: 'P' + i }));
  many[0].storefrontHidden = true;
  const out = SC.build({ settings: settings(), products: many });
  assert.equal(out.items.length, 60);
  assert.equal(out.items.some((i) => i.id === 'p0'), false);
  assert.equal(out.items[59].id, 'p60');
});

test('review: what a customer would find wrong, per listing, hidden ones left out', () => {
  const thumb = 'data:image/jpeg;base64,AAAA';
  const good = { id: 'g', nameEn: 'Desk lamp', nameAr: 'مصباح مكتب', descriptionEn: 'A lamp', price: 10, category: 'Home',
    images: [{ id: 'i', thumbnail: thumb, kind: 'print' }] };
  const bad = { id: 'b', nameEn: 'Turtle_Articulated', nameAr: 'Turtle_Articulated' };
  const run = { id: 'r', nameEn: 'Dragon', nameAr: 'AquaticFlexiDragon-U1', price: 5, category: 'Toys',
    descriptionEn: 'x', images: [{ id: 'i', thumbnail: thumb, kind: 'render' }] };
  const hidden = { id: 'h', nameEn: '3+color+AMS', storefrontHidden: true };
  const r = SC.review([good, bad, run, hidden], settings(), 'en');
  assert.equal(r.hidden, 1);
  assert.deepEqual(r.listings.map((l) => l.id), ['b', 'r']);
  assert.deepEqual(r.listings[0].issues, ['no_price', 'no_photo', 'no_description', 'no_category', 'second_language', 'file_name']);
  assert.deepEqual(r.listings[1].issues, ['file_name']);
});

test('review: a storefront price or category counts, and 0 is a price', () => {
  const p = { id: 'p', nameEn: 'Vase', nameAr: 'مزهرية', descriptionEn: 'd', price: 0, images: [{ id: 'i', thumbnail: 'data:image/png;base64,AA' }] };
  const s = settings({ categories: { p: 'Home' } });
  assert.deepEqual(SC.review([p], s, 'en').listings, []);
});
