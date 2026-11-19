'use strict';
/**
 * test/fixtures/line-labour-vectors.json: prep once per line, post per piece
 * (Turki, Nov 19), through KhaytOrderMoney.lineLabour and every path that
 * costs a line with it: a hand part (lib/calculator-cost.js), a product of N
 * (lib/product-pricing.js), a store order's line (lib/store-order-job.js) and
 * an agreed-price line through newOrder. The Mac and the phone run the file.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'part-ids', 'print-rates', 'calculator-cost', 'product-price', 'product-pricing', 'order-new', 'store-order-job']) require('../lib/' + f + '.js');
const Mo = globalThis.KhaytOrderMoney, CC = globalThis.KhaytCalculatorCost, PP = globalThis.KhaytProductPricing;
const N = globalThis.KhaytOrderNew, SJ = globalThis.KhaytStoreOrderJob;
const V = require('./fixtures/line-labour-vectors.json');
const r2 = (v) => Math.round(v * 100) / 100;
const settings = V.settings;
const product = { id: 'PR', rates: V.rates, parts: [
  { name: 'a', printWeight: 0, printTime: 0, qty: 1 },
  { name: 'b', printWeight: 0, printTime: 0, qty: 2 },
] };
const part = (c) => Object.assign({ name: 'p', printWeight: c.printWeight || 0, printTime: 0, spoolCost: c.spoolCost || 0, spoolWeight: c.spoolWeight || 1000, qty: c.qty }, V.rates);

for (const c of V.cases) {
  test(c.why, () => {
    if (c.kind === 'lineLabour') {
      assert.equal(r2(Mo.lineLabour(Object.assign({ qty: c.qty }, V.rates))), c.want);
    } else if (c.kind === 'part') {
      const s = c.packaging ? settings : Object.assign({}, settings, { defaultPackagingCost: 0 });
      assert.equal(r2(CC.partTotalCost(part(c), { inventory: [], settings: s })), c.want);
    } else if (c.kind === 'product') {
      const jp = PP.productJobParts(product, { inventory: [], settings, units: c.units });
      assert.equal(r2(jp.labourCost), c.want.labourCost);
      assert.equal(r2(jp.packagingCost), c.want.packagingCost);
      assert.deepEqual(jp.parts.map((p) => p.qty), c.want.partQty);
      if (c.want.partsWithoutLabour) for (const p of jp.parts) assert.equal(p.baseCost, 0, 'no labour (and nothing else) in a part of this product');
    } else if (c.kind === 'agreed') {
      const p = part(c);
      p.baseCost = CC.partTotalCost(p, { inventory: [], settings: Object.assign({}, settings, { defaultPackagingCost: 0 }) });
      p.agreedPrice = c.agreedPrice;
      const job = N.newOrder({ parts: [p], project: 'A', margin: 30, asQuote: true },
        { settings, orders: [], clients: [], now: new Date('2026-11-19T08:00:00Z'), tokens: { tracking: new Uint8Array(N.TOKEN_BYTES), quoteApproval: new Uint8Array(N.TOKEN_BYTES), id: new Uint8Array(4) } });
      assert.equal(job.price, c.want.price);
      assert.equal(r2(job.parts[0].baseCost), c.want.baseCost);
    } else if (c.kind === 'store') {
      const out = SJ.build({ lines: [{ name: 'PR', productId: 'PR', qty: c.units, toPrint: c.units }] }, { products: [product], settings, inventory: [], consumables: [] }, 'S1');
      assert.equal(r2(out.labourCost), c.want.labourCost);
      assert.equal(r2(out.packagingCost), c.want.packagingCost);
      assert.deepEqual(out.parts.map((p) => p.qty), c.want.partQty);
      const job = SJ.apply({ id: 'S1', parts: [] }, out);
      assert.equal(r2(Mo.jobFixedCost(job, { components: false, overhead: false })), r2(c.want.labourCost + c.want.packagingCost), 'on the job, once');
    } else {
      throw new Error('unknown kind ' + c.kind);
    }
  });
}
