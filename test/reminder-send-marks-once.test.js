'use strict';

/**
 * Desktop payment reminders are recorded when they are SENT, once.
 *
 * The 6-hour timer (`processPaymentReminders`) used to stamp every invoice it
 * selected, and the 💰 send that followed did not — so the record said
 * "reminded" for reminders never sent, and once the send recorded too, one
 * reminder would have counted twice. Now the timer only flags and the send
 * marks (`markReminderPatch`), after it went out. One send, one mark.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/wa-template.js');
require('../lib/payment-terms.js');
require('../lib/tax.js');
require('../lib/order-money.js');
require('../lib/payment-reminder.js');

const due = new Date(Date.now() - 20 * 86400000).toISOString().slice(0, 10);

function setup({ phone = '+966500000000', share = async () => true } = {}) {
  const sent = [];
  global.settings = { currency: 'SAR', paymentReminder: { enabled: true },
    paymentProviders: { moyasar: { enabled: true, payLink: 'https://pay.example/{amount}' } } };
  global.clients = [{ id: 'C1', name: 'Sara', phone }];
  global.printLog = [{ id: 'J1', status: 'completed', clientId: 'C1', project: 'Lamp', price: 500, paidAmount: 0, dueDate: due }];
  global.waTemplates = [{ id: 'tpl-payment', body: 'Hi {{client}}, {{price}} {{currency}} is due on {{id}}.' }];
  global.t = (k, p) => (p ? k + ' ' + JSON.stringify(p) : k);
  global.toast = () => {};
  global.saveAll = () => {};
  global.renderDashboard = () => {};
  global.localName = (c) => c.name;
  global.jobRef = (o) => String((o && o.jobNumber) || (o && o.id) || o || '');
  global.fmtMoney = (n) => (+n).toFixed(2);
  global.fmtMoneyIn = (n, c) => (+n).toFixed(2) + ' ' + c;
  global.orderCurrency = (o) => o.currency || 'SAR';
  global.orderOwedRaw = (o) => global.KhaytOrderMoney.orderOwedRaw(o, { settings: global.settings });
  global.CURRENCIES = { SAR: { symbol: 'SAR' }, EUR: { symbol: '€' } };
  global.window = { hubAPI: { shareWhatsApp: async (opts) => { sent.push(opts); return share(opts); } } };
  return sent;
}

test('one send is one mark, and the text asks for what is owed with the pay link', async () => {
  const sent = setup();
  const { sendPaymentReminder } = require('../renderer/invoicing.js');
  assert.equal(await sendPaymentReminder('J1'), true);
  const job = global.printLog[0];
  assert.equal(job.payReminderCount, 1);
  assert.ok(job.payRemindedAt);
  assert.equal(sent.length, 1);
  assert.match(sent[0].message, /Hi Sara, 500\.00 SAR is due on J1\./);
  assert.match(sent[0].message, /https:\/\/pay\.example\/500\.00/);
  await sendPaymentReminder('J1');
  assert.equal(job.payReminderCount, 2, 'a second send is a second reminder, no more');
});

test('a send that failed records nothing', async () => {
  setup({ share: async () => { throw new Error('no WhatsApp'); } });
  const { sendPaymentReminder } = require('../renderer/invoicing.js');
  assert.equal(await sendPaymentReminder('J1'), false);
  assert.equal(global.printLog[0].payReminderCount, undefined);
});

test('a customer with no way to reach records nothing', async () => {
  setup({ phone: '' });
  const { sendPaymentReminder } = require('../renderer/invoicing.js');
  assert.equal(await sendPaymentReminder('J1'), false);
  assert.equal(global.printLog[0].payReminderCount, undefined);
});

test('the timer flags and never marks, so flag + send is still one reminder', async () => {
  setup();
  const { processPaymentReminders } = require('../renderer/operations-extras.js');
  const { sendPaymentReminder } = require('../renderer/invoicing.js');
  processPaymentReminders();
  processPaymentReminders();
  assert.equal(global.printLog[0].payReminderCount, undefined, 'flagging is not reminding');
  await sendPaymentReminder('J1');
  assert.equal(global.printLog[0].payReminderCount, 1);
});

test('a job in another currency asks in it; the pay link is converted at the saved rate, or left out', async () => {
  const sent = setup();
  global.printLog[0].currency = 'EUR';
  global.printLog[0].fxRate = 4;
  const { sendPaymentReminder } = require('../renderer/invoicing.js');
  await sendPaymentReminder('J1');
  assert.match(sent[0].message, /500\.00 € is due/);
  assert.match(sent[0].message, /pay\.example\/2000\.00/, 'the link charges the shop currency');
  delete global.printLog[0].fxRate;
  await sendPaymentReminder('J1');
  assert.doesNotMatch(sent[1].message, /pay\.example/, 'no saved rate: no honest figure, no link');
});
