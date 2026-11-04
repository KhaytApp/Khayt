'use strict';

/**
 * Payment reminders that work: milestone proformas with a due date are
 * chased, the shop's pay link goes into the text, and the channel and the
 * email are decided once for both apps (`lib/payment-reminder.js`).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/wa-template.js');
const R = require('../lib/payment-reminder.js');

const NOW = new Date('2026-06-20T12:00:00').getTime();
const on = { paymentReminder: { enabled: true } };
const job = (over = {}) => Object.assign({
  id: 'J1', status: 'printing', price: 1000, paidAmount: 0, dueDate: '2026-07-30',
  milestoneInvoices: [
    { id: 'MS-a', label: 'Deposit', percentage: 30, amount: 300, issuedAt: '2026-06-01', dueDate: '2026-06-10' },
    { id: 'MS-b', label: 'Balance', percentage: 70, amount: 700, issuedAt: null, dueDate: '2026-07-30' },
  ],
}, over);

test('a milestone past its due date is chased while the job itself is not yet due', () => {
  const due = R.selectInvoicesDueForReminder([job()], on, () => 1000, NOW);
  assert.deepEqual(due.map((o) => o.id), ['J1']);
  assert.equal(R.reminderDaysOverdue(job(), NOW, null, on), 10);
});

test('paid down by the running total, in the order they are asked for', () => {
  assert.deepEqual(R.milestonesDue(job({ paidAmount: 300 }), NOW), [], 'the deposit is covered');
  const part = R.milestonesDue(job({ paidAmount: 100 }), NOW);
  assert.equal(part.length, 1);
  assert.equal(part[0].unpaid, 200);
  assert.deepEqual(R.selectInvoicesDueForReminder([job({ paidAmount: 300 })], on, () => 700, NOW), []);
  // A paidAt some build wrote on the row is honoured.
  const marked = job();
  marked.milestoneInvoices[0].paidAt = '2026-06-09';
  assert.deepEqual(R.milestonesDue(marked, NOW), []);
});

test('no due date, a quote, a void or inside the grace period: not chased', () => {
  const undated = job();
  undated.milestoneInvoices.forEach((m) => delete m.dueDate);
  assert.deepEqual(R.selectInvoicesDueForReminder([undated], on, () => 1000, NOW), []);
  assert.deepEqual(R.milestonesDue(job({ status: 'quote' }), NOW), []);
  assert.deepEqual(R.milestonesDue(job({ voidedAt: '2026-06-11' }), NOW), []);
  const recent = job();
  recent.milestoneInvoices[0].dueDate = '2026-06-19';
  assert.deepEqual(R.milestonesDue(recent, NOW), [], '1 day over is inside the 3-day grace');
});

test('the cooldown and the three-reminder cap apply to milestones too', () => {
  const capped = job({ payReminderCount: 3 });
  assert.deepEqual(R.selectInvoicesDueForReminder([capped], on, () => 1000, NOW), []);
  const recent = job(R.markReminderPatch({}, NOW - 86400000));
  assert.deepEqual(R.selectInvoicesDueForReminder([recent], on, () => 1000, NOW), []);
  const old = job(R.markReminderPatch({ payReminderCount: 1 }, NOW - 5 * 86400000));
  assert.equal(old.payReminderCount, 2);
  assert.deepEqual(R.selectInvoicesDueForReminder([old], on, () => 1000, NOW).map((o) => o.id), ['J1']);
});

test('a book without milestones selects exactly as before', () => {
  const orders = [
    { id: 'A', status: 'completed', dueDate: '2026-06-10' },
    { id: 'B', status: 'completed', dueDate: '2026-06-19' },
    { id: 'C', status: 'completed', dueDate: '2026-06-01' },
  ];
  assert.deepEqual(R.selectInvoicesDueForReminder(orders, on, () => 100, NOW).map((o) => o.id), ['C', 'A']);
});

test('the amount asked for: the due milestones, or everything once the invoice is overdue', () => {
  assert.deepEqual(R.reminderAmount(job(), 1000, on, NOW).amount, 300);
  assert.equal(R.reminderAmount(job(), 1000, on, NOW).milestones[0].id, 'MS-a');
  assert.equal(R.reminderAmount(job({ dueDate: '2026-06-01' }), 1000, on, NOW).amount, 1000);
  assert.equal(R.reminderAmount(job(), 150, on, NOW).amount, 150, 'never more than is owed');
});

test('the pay link: the first switched-on provider, with the amount put in', () => {
  const settings = { paymentProviders: {
    tabby: { enabled: false, payLink: 'https://tabby.example/pay/{amount}' },
    moyasar: { enabled: true, payLink: 'https://pay.example/shop?amount={amount}' },
    stc: { enabled: true, payLink: 'javascript:alert(1)' },
  } };
  assert.equal(R.payLinkFor(settings, 300), 'https://pay.example/shop?amount=300.00');
  assert.equal(R.payLinkFor({ paymentProviders: { x: { enabled: true, payLink: 'https://p.example/{total}' } } }, 12.5),
    'https://p.example/12.50');
  assert.equal(R.payLinkFor({ paymentProviders: { x: { enabled: true, payLink: 'javascript:alert(1)' } } }, 1), '');
  assert.equal(R.payLinkFor({}, 1), '');
});

test('the text: the shop\'s template filled, and the link on its own line', () => {
  const body = 'Hi {{client}}, payment of {{price}} {{currency}} is outstanding for order {{id}}.';
  const values = { client: 'Sara', price: '300.00', currency: 'EUR', id: 'J1' };
  assert.equal(R.reminderText({ body, values }), 'Hi Sara, payment of 300.00 EUR is outstanding for order J1.');
  assert.equal(R.reminderText({ body, values, payLink: 'https://p.example/300.00', payLabel: 'Pay here:' }),
    'Hi Sara, payment of 300.00 EUR is outstanding for order J1.\nPay here: https://p.example/300.00');
});

test('a text already filled is only given the link, never filled again', () => {
  const filled = 'Hi {{price}}, 300 is due.';   // a customer whose name is "{{price}}"
  assert.equal(R.reminderText({ body: filled, values: null, payLink: 'https://p.example/1' }),
    'Hi {{price}}, 300 is due.\nhttps://p.example/1');
  assert.equal(R.reminderText({ body: filled, values: null }), filled);
});

test('the channel:the shop\'s choice when it can be used, else WhatsApp, else email', () => {
  const mail = { emailConfig: { provider: 'sendgrid' } };
  const both = { phone: '+966500000000', email: 'a@b.co' };
  assert.equal(R.reminderChannel(mail, both), 'whatsapp');
  assert.equal(R.reminderChannel({ ...mail, paymentReminder: { channel: 'email' } }, both), 'email');
  assert.equal(R.reminderChannel({ paymentReminder: { channel: 'email' } }, both), 'whatsapp', 'no provider');
  assert.equal(R.reminderChannel(mail, { email: 'a@b.co' }), 'email');
  assert.equal(R.reminderChannel({}, { email: 'a@b.co' }), 'none');
  assert.equal(R.reminderChannel(mail, null), 'none');
});

test('the email: addressed, escaped, the link made clickable', () => {
  const m = R.reminderEmail({ settings: { emailConfig: { provider: 'mailgun' } }, client: { email: 'a@b.co' },
    text: 'Pay <now>\nhttps://p.example/1', subject: 'Reminder', shopName: 'Shop & Co' });
  assert.equal(m.to, 'a@b.co');
  assert.equal(m.provider, 'mailgun');
  assert.match(m.html, /Pay &lt;now&gt;<br><a href="https:\/\/p.example\/1">/);
  assert.match(m.html, /Shop &amp; Co/);
  assert.equal(R.reminderEmail({ settings: {}, client: { email: 'a@b.co' }, text: 'x' }), null);
});
