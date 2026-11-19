'use strict';
/**
 * test/fixtures/catalogue-labour-vectors.json through lib/product-pricing.js
 * priceProduct: labour ONCE per product with product-level rates, the
 * labourPerPart override, a part's own rate winning, and a legacy product
 * (no rates) costed exactly as before. A single item must equal the
 * calculator (lib/calculator-cost.js computePartBaseCost of the same part).
 * The Mac and the phone run the same file.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'part-ids', 'print-rates', 'calculator-cost', 'product-price', 'product-pricing', 'order-new']) require('../lib/' + f + '.js');
const N = globalThis.KhaytOrderNew;
const PP = globalThis.KhaytProductPricing;
const CC = globalThis.KhaytCalculatorCost;
const PRt = globalThis.KhaytPrintRates;
const V = require('./fixtures/catalogue-labour-vectors.json');
const clone = (o) => JSON.parse(JSON.stringify(o));

for (const c of V.cases) {
  test(c.why, () => {
    const parts = Array.from({ length: c.parts }, (_, i) => Object.assign({ name: 'p' + i },
      c.productRates ? {} : clone(V.rates), clone(V.part), i === 0 ? (c.firstPartOverride || {}) : {},
      c.partOverride && c.partOverride.index === i ? Object.assign({}, c.partOverride, { index: undefined }) : {}));
    const product = Object.assign({ id: 'P', parts }, c.productRates ? { rates: clone(V.rates) } : {}, c.labourPerPart ? { labourPerPart: true } : {});
    const ctx = { inventory: [], settings: clone(c.settings || V.settings) };
    const r = PP.priceProduct(product, ctx);
    assert.equal(r.cost, c.want.cost, 'cost');
    if (c.want.labour !== undefined) {
      assert.equal(Math.round(PP.productLabourCost(product, ctx) * 100) / 100, c.want.labour, 'the labour charged once');
    }
    if (c.want.once !== undefined) assert.equal(Math.round(PP.productOnceCost(product, ctx) * 100) / 100, c.want.once, 'labour and packaging, once');
    if (c.want.jobPrice !== undefined) {
      const lines = PP.productJobParts(product, ctx);
      assert.equal(lines.length, c.want.jobLines, 'the parts plus one labour line');
      const job = N.newOrder({ parts: lines, project: 'J', margin: ctx.settings.defaultMargin }, { settings: ctx.settings, orders: [], clients: [], now: new Date('2026-11-19T08:00:00Z'),
        tokens: { tracking: new Uint8Array(N.TOKEN_BYTES), quoteApproval: new Uint8Array(N.TOKEN_BYTES), id: new Uint8Array(4) } });
      assert.equal(job.price, c.want.jobPrice, 'newOrder prices the job');
      assert.equal(job.price, r.basePrice, 'exactly as the catalogue');
    }
    if (c.want.equalsCalculator) {
      const calc = CC.computePartBaseCost(PRt.withRates(Object.assign({}, clone(V.rates), clone(V.part)), { settings: ctx.settings }), ctx);
      assert.equal(r.cost, Math.round(calc * 100) / 100, 'catalogue == calculator for the same item');
    }
  });
}
