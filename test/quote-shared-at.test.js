'use strict';
/**
 * A quote that reaches its customer is stamped `quoteSharedAt`, which the
 * shared next-step rule (lib/order-next-step.js) reads as "sent". Not
 * `quoteSentAt`: order-new.js writes that the moment any quote is created.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');
const invoicing = read('renderer/invoicing.js');
const integrations = read('renderer/integrations.js');

function loadHelper() {
  const start = invoicing.indexOf('function markQuoteShared(');
  assert.ok(start > 0, 'renderer/invoicing.js defines markQuoteShared');
  const end = invoicing.indexOf('\n}\n', start) + 3;
  const ctx = { saves: 0 };
  ctx.saveAll = () => { ctx.saves += 1; };
  vm.runInNewContext(invoicing.slice(start, end) + '\nthis.markQuoteShared = markQuoteShared;', ctx);
  return ctx;
}

test('a quote is stamped quoteSharedAt and saved; quoteSentAt is left alone', () => {
  const ctx = loadHelper();
  const order = { id: 'Q1', status: 'quote', quoteSentAt: '2026-11-01' };
  assert.equal(ctx.markQuoteShared(order), true);
  assert.match(order.quoteSharedAt, /^\d{4}-\d{2}-\d{2}T/);
  assert.equal(order.quoteSentAt, '2026-11-01');
  assert.equal(ctx.saves, 1);
});

test('a job that is no longer a quote is not stamped', () => {
  const ctx = loadHelper();
  for (const status of ['pending', 'printing', 'completed', 'cancelled']) {
    const order = { id: 'J', status };
    assert.equal(ctx.markQuoteShared(order), false, status);
    assert.equal(order.quoteSharedAt, undefined, status);
  }
  assert.equal(ctx.markQuoteShared(null), false);
  assert.equal(ctx.saves, 0);
});

test('the shared next-step rule then reads the quote as sent', () => {
  const NS = require('../lib/order-next-step.js');
  const ctx = loadHelper();
  const order = { id: 'Q2', status: 'quote', price: 100, date: '2026-11-10' };
  const before = NS.nextSteps(order, { settings: {}, orders: [order], today: '2026-11-14', canWrite: true });
  ctx.markQuoteShared(order);
  const after = NS.nextSteps(order, { settings: {}, orders: [order], today: '2026-11-14', canWrite: true });
  assert.equal(before.primary && before.primary.code, 'send_quote');
  assert.notEqual(after.primary && after.primary.code, 'send_quote');
});

test('every place the desktop shares a quote stamps it', () => {
  const handler = (src, id) => {
    const at = src.indexOf(`querySelector('#${id}')`);
    assert.ok(at > 0, `${id} is still wired`);
    return src.slice(at, src.indexOf('\n      });', at));
  };
  for (const id of ['cpCopy', 'cpWa', 'quoteApprovalCopy', 'quoteApprovalWa']) {
    assert.match(handler(integrations, id), /markQuoteShared\(order\)/, id);
  }
  const fn = (name) => {
    const at = invoicing.indexOf(`function ${name}(`);
    return invoicing.slice(at, invoicing.indexOf('\n}\n', at));
  };
  for (const name of ['exportInvoicePDF', 'shareInvoiceWhatsApp', 'sendQuoteFollowUp']) {
    assert.match(fn(name), /markQuoteShared\(order\)/, name);
  }
});
