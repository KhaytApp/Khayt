/**
 * A campaign through the shop's own WhatsApp Business account: who it reaches
 * and what it sends.
 *
 * Meta takes only an approved template from a business writing first, so the
 * campaign sends one (lib/whatsapp-send.js), never the free text lib/sms.js
 * used to — which Meta refused for anyone quiet for 24 hours (131047). And it
 * goes only to customers who agreed to OFFERS on WhatsApp: agreeing to order
 * updates (whatsappOptIn) is a different promise.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const C = require('../lib/campaigns.js');
const { sendWhatsappTemplate, checkWhatsapp } = require('../lib/sms.js');

const AGREED = { at: '2026-10-01T09:00:00.000Z', how: 'asked' };
const CLIENTS = [
  { id: 'a', name: 'Amal', phone: '0501234567', whatsappMarketingOptIn: AGREED },
  { id: 'b', name: 'Badr', phone: '0501234568', whatsappOptIn: AGREED },          // order updates only
  { id: 'c', name: 'Cyan', phone: '0501234569' },                                   // never asked
  { id: 'd', name: 'Dana', phone: '0501234570', whatsappMarketingOptIn: AGREED, marketingOptOut: true },
  { id: 'e', name: 'Eid', phone: '12345', whatsappMarketingOptIn: AGREED },         // too short to place
  { id: 'f', name: 'Fay', phone: '0501234571', whatsappMarketingOptIn: { how: 'asked' } }, // no date: not given
];

test('reaches only customers who agreed to offers, at a number WhatsApp can dial', () => {
  const r = C.segmentRecipients(CLIENTS, [], {}, 'whatsapp_business', Date.parse('2026-10-24'));
  assert.deepEqual(r.map((x) => x.client.id), ['a']);
  assert.equal(r[0].contact, '966501234567'); // digits, country code first
});

test('order-update consent is not offers consent', () => {
  assert.equal(C.whatsappOffersOptedIn(CLIENTS[1]), false);
  assert.equal(C.whatsappOffersOptedIn(CLIENTS[0]), true);
  assert.equal(C.whatsappOffersOptedIn(null), false);
});

test('the other channels are unchanged by the new consent', () => {
  const r = C.segmentRecipients(CLIENTS, [], {}, 'whatsapp', Date.parse('2026-10-24'));
  assert.deepEqual(r.map((x) => x.client.id), ['a', 'b', 'c', 'e', 'f']);
});

test('template values: one per line, merge fields filled, blank lines dropped', () => {
  const rec = { client: CLIENTS[0], stats: { completedCount: 3, totalSpend: 120 } };
  assert.deepEqual(C.templateValues('{{name}}\n\n  {{orders}} orders \n', rec, (n) => `SAR ${n}`, {}),
    ['Amal', '3 orders']);
});

const fakeFetch = (status, body, seen) => async (url, init) => {
  seen.push({ url, init });
  return { status, text: async () => JSON.stringify(body) };
};

test('sends a template — never a text body — and reads the message id', async () => {
  const seen = [];
  const r = await sendWhatsappTemplate({ phoneNumberId: '123456789', token: 'EAA' + 'x'.repeat(30) },
    { to: '966501234567', template: { name: 'spring_offer', language: 'ar' }, params: ['Amal'] },
    { fetchImpl: fakeFetch(200, { messages: [{ id: 'wamid.ABC' }] }, seen) });
  assert.deepEqual(r, { ok: true, messageId: 'wamid.ABC', waId: '' });
  const body = JSON.parse(seen[0].init.body);
  assert.equal(body.type, 'template');
  assert.equal(body.text, undefined);
  assert.equal(body.template.name, 'spring_offer');
  assert.equal(body.template.components[0].parameters[0].text, 'Amal');
  assert.match(seen[0].url, /^https:\/\/graph\.facebook\.com\/v\d+\.\d+\/123456789\/messages$/);
});

test('a refusal comes back as a reason, and a bad config never reaches the network', async () => {
  const seen = [];
  const r = await sendWhatsappTemplate({ phoneNumberId: '123456789', token: 'EAA' + 'x'.repeat(30) },
    { to: '966501234567', template: { name: 'spring_offer', language: 'ar' }, params: [] },
    { fetchImpl: fakeFetch(404, { error: { code: 132001, message: 'Template name does not exist' } }, seen) });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'template_missing');
  const bad = await sendWhatsappTemplate({ phoneNumberId: 'x', token: 't' }, { to: '1' }, { fetchImpl: fakeFetch(200, {}, seen) });
  assert.equal(bad.reason, 'bad_phone_number_id');
  assert.equal(seen.length, 1);
});

test('the settings check is a GET that messages nobody', async () => {
  const seen = [];
  const r = await checkWhatsapp({ phoneNumberId: '123456789', token: 'EAA' + 'x'.repeat(30) },
    { fetchImpl: fakeFetch(200, { display_phone_number: '+966 50 123 4567', verified_name: 'Shop' }, seen) });
  assert.deepEqual(r, { ok: true, number: '+966 50 123 4567', name: 'Shop' });
  assert.equal(seen[0].init.method, 'GET');
  assert.doesNotMatch(seen[0].url, /messages/);
});

// Wiring: the module is right only if the app calls it.
test('the desktop campaign and settings use the template path', () => {
  const root = path.join(__dirname, '..');
  const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');
  const clients = read('renderer/clients.js');
  assert.match(clients, /value="whatsapp_business"/);
  assert.match(clients, /hubAPI\.sendWhatsappTemplate\(/);
  assert.match(clients, /whatsappMarketingOptIn/);
  assert.match(read('renderer/settings.js'), /hubAPI\?\.checkWhatsapp\?\.\(/);
  assert.match(read('preload.js'), /sendWhatsappTemplate: \(opts\) => ipcRenderer\.invoke\('hub:send-whatsapp-template'/);
  assert.match(read('main.js'), /ipcMain\.handle\('hub:send-whatsapp-template'/);
  const html = read('renderer/index.html');
  assert.ok(html.indexOf('../lib/whatsapp-message.js') !== -1, 'renderer loads the phone rule');
});
