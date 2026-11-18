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
for (const f of ['print-rates', 'calculator-cost', 'product-price', 'product-pricing']) require('../lib/' + f + '.js');
const PP = globalThis.KhaytProductPricing;
const CC = globalThis.KhaytCalculatorCost;
const PRt = globalThis.KhaytPrintRates;
const V = require('./fixtures/catalogue-labour-vectors.json');
const clone = (o) => JSON.parse(JSON.stringify(o));

for (const c of V.cases) {
  test(c.why, () => {
    const parts = Array.from({ length: c.parts }, (_, i) => Object.assign({ name: 'p' + i },
      c.productRates ? {} : clone(V.rates), clone(V.part), i === 0 ? (c.firstPartOverride || {}) : {}));
    const product = Object.assign({ id: 'P', parts }, c.productRates ? { rates: clone(V.rates) } : {}, c.labourPerPart ? { labourPerPart: true } : {});
    const ctx = { inventory: [], settings: clone(V.settings) };
    const r = PP.priceProduct(product, ctx);
    assert.equal(r.cost, c.want.cost, 'cost');
    if (c.want.labour !== undefined) {
      assert.equal(Math.round(PP.productLabourCost(product, ctx) * 100) / 100, c.want.labour, 'the labour charged once');
    }
    if (c.want.equalsCalculator) {
      const calc = CC.computePartBaseCost(PRt.withRates(Object.assign({}, clone(V.rates), clone(V.part)), { settings: ctx.settings }), ctx);
      assert.equal(r.cost, Math.round(calc * 100) / 100, 'catalogue == calculator for the same item');
    }
  });
}
