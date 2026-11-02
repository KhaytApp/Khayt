'use strict';
/**
 * A milestone of a job, asked for on its own.
 *
 * `milestone` is an option of the shared document (lib/invoice-document.js),
 * used with `proforma`: ONE line, "{label} / N% of total", priced at the
 * milestone's amount, with the tax worked out on that amount and none of the
 * whole job's shipping, rush, extras or discount. It is not a tax invoice.
 * Without it the document must be exactly what it was.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { render, context } = require('./helpers/invoice-harness.js');
const { SHOP, ORDER } = require('./helpers/invoice-cases.js');

const BUSY = Object.assign({}, ORDER, {
  shippingCost: 30, rushFeeAmount: 25, discountPct: 10, priceBeforeDiscount: 1000,
  extraLines: [{ label: 'Engraving', amount: 40 }],
});
const MS = { label: 'Deposit 50%', percentage: 50, amount: 575, total: 1150 };

/** The document with `milestone` passed to the shared module. */
function withMilestone(order, milestone, opts = {}, money = {}) {
  const { ctx, area } = context(opts);
  const D = ctx.KhaytInvoiceDocument;
  const real = D.invoiceHtml;
  D.invoiceHtml = (o, c) => real(o, Object.assign({}, c, { milestone }));
  ctx.renderInvoice(order, Object.assign({
    qrSvg: '<svg id="zatca-qr"></svg>', qrProblem: null, payQrSvg: '',
    total: '1150.00', vatAmount: '150.00', subtotal: '1000.00', subtotalShown: '1000.00',
    vatRate: 15, shipping: 0,
  }, money));
  return { html: area.innerHTML, ctx };
}

test('without a milestone the document is unchanged, proforma or not', () => {
  for (const order of [ORDER, BUSY]) {
    for (const money of [{}, { proforma: true }]) {
      const plain = render(order, { settings: SHOP }, money);
      assert.equal(withMilestone(order, undefined, { settings: SHOP }, money).html, plain);
      assert.equal(withMilestone(order, null, { settings: SHOP }, money).html, plain);
    }
  }
});

test('a milestone on a plain invoice (no proforma) is ignored', () => {
  const plain = render(BUSY, { settings: SHOP });
  assert.equal(withMilestone(BUSY, MS, { settings: SHOP }).html, plain);
});

test('a milestone proforma is ONE line at the milestone amount, with the tax on that amount', () => {
  const { html, ctx } = withMilestone(BUSY, MS, { settings: SHOP }, { proforma: true });
  const body = html.match(/<tbody>[\s\S]*?<\/tbody>/)[0];
  assert.equal((body.match(/<tr>/g) || []).length, 1, 'one line, not one per part');
  assert.match(html, /Deposit 50%/);
  assert.match(html, /50% of 1150\.00 SAR/);
  assert.doesNotMatch(body, /Bracket|Lid|Engraving/, 'the job\'s parts are not listed');
  assert.doesNotMatch(html, /Shipping|Rush|Discount/, 'nor its shipping, rush or discount');
  assert.doesNotMatch(html, /id="zatca-qr"|qr-box/, 'not a tax invoice');
  assert.match(html, /proforma-watermark/);
  const tax = ctx.KhaytTax.computeTax(575, ctx.KhaytTax.profileFromSettings(SHOP));
  const f = (n) => n.toFixed(2);
  const grand = html.match(/class="row grand"[\s\S]*?<span class="v">([0-9.]+)/)[1];
  assert.equal(grand, f(tax.total), 'the total is the tax engine\'s on the amount');
  assert.match(html, new RegExp(`<span class="v">${f(tax.taxTotal)} `), 'and so is the VAT line');
  assert.notEqual(grand, '1150.00');
});
