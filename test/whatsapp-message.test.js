'use strict';
const test = require('node:test');
const assert = require('node:assert');
const wa = require('../lib/whatsapp-message.js');

/**
 * WhatsApp updates to customers. The number has to come out in the one shape
 * `wa.me` takes, the message in the customer's language, and a number that
 * cannot be trusted has to be refused rather than guessed at.
 */

// ── The number ──────────────────────────────────────────────────────────────

test('every way a shop writes a Saudi mobile comes out as the same E.164 number', () => {
  const forms = [
    '0501234567', '050 123 4567', '050-123-4567', '(050) 123 4567',
    '501234567', '966501234567', '+966501234567', '+966 50 123 4567',
    '00966501234567', '00 966 50 123 4567', '+966 0501234567', '9660501234567',
    '٠٥٠١٢٣٤٥٦٧', '+٩٦٦٥٠١٢٣٤٥٦٧', '۰۵۰۱۲۳۴۵۶۷',
  ];
  for (const f of forms) {
    const out = wa.normalizePhone(f);
    assert.deepStrictEqual(
      { ok: out.ok, e164: out.e164, digits: out.digits },
      { ok: true, e164: '+966501234567', digits: '966501234567' }, f);
  }
});

test('a Saudi landline is accepted in its local and international forms', () => {
  assert.strictEqual(wa.normalizePhone('011 456 7890').e164, '+966114567890');
  assert.strictEqual(wa.normalizePhone('+966 11 456 7890').e164, '+966114567890');
});

test('another country is accepted with its code, and refused without one', () => {
  assert.strictEqual(wa.normalizePhone('+971 50 123 4567').e164, '+971501234567');
  assert.strictEqual(wa.normalizePhone('0044 7700 900123').e164, '+447700900123');
  // Not Saudi-shaped and no country code: could be anywhere.
  const bare = wa.normalizePhone('07700900123');
  assert.strictEqual(bare.ok, false);
  assert.strictEqual(bare.reason, 'no_country_code');
});

test('unusable numbers are refused with a reason', () => {
  assert.strictEqual(wa.normalizePhone('').reason, 'empty');
  assert.strictEqual(wa.normalizePhone(null).reason, 'empty');
  assert.strictEqual(wa.normalizePhone('   ').reason, 'empty');
  assert.strictEqual(wa.normalizePhone('no phone').reason, 'empty');
  assert.strictEqual(wa.normalizePhone('12345').reason, 'too_short');
  assert.strictEqual(wa.normalizePhone('+966 50 123 45').reason, 'too_short');
  assert.strictEqual(wa.normalizePhone('+966 50 123 456789').reason, 'too_long');
  assert.strictEqual(wa.normalizePhone('+1234567890123456').reason, 'too_long');
  // 800 and 9200 numbers have no WhatsApp.
  assert.strictEqual(wa.normalizePhone('+966 920 012 345').reason, 'bad_saudi_number');
  for (const bad of ['', '12345', '+966 920 012 345', '07700900123']) {
    const out = wa.normalizePhone(bad);
    assert.strictEqual(out.e164, '');
    assert.strictEqual(out.digits, '');
  }
});

test('a field with two numbers gives the first usable one', () => {
  assert.strictEqual(wa.normalizePhone('0501234567 / 0559876543').e164, '+966501234567');
  assert.strictEqual(wa.normalizePhone('12 / 0559876543').e164, '+966559876543');
  assert.strictEqual(wa.normalizePhone('0501234567 أو 0559876543').e164, '+966501234567');
  assert.strictEqual(wa.normalizePhone('0501234567 ext 12').e164, '+966501234567');
});

test('the link carries digits only and an encoded message', () => {
  assert.strictEqual(wa.waLink('966501234567', ''), 'https://wa.me/966501234567');
  const link = wa.waLink('+966 50 123 4567', 'A+B & C = مرحباً\nline');
  assert.ok(link.startsWith('https://wa.me/966501234567?text='));
  // `+` and `&` must be escaped, or wa.me reads a space and cuts the message.
  assert.ok(!link.slice(link.indexOf('?')).includes('+'));
  assert.ok(!link.slice(link.indexOf('?') + 1).includes('&'));
  assert.strictEqual(decodeURIComponent(link.split('?text=')[1]), 'A+B & C = مرحباً\nline');
});

test('chatLink refuses without a link when the number is unusable', () => {
  const bad = wa.chatLink('123', 'hi');
  assert.strictEqual(bad.ok, false);
  assert.strictEqual(bad.link, '');
  const good = wa.chatLink('0501234567', '');
  assert.strictEqual(good.link, 'https://wa.me/966501234567');
});

// ── The milestone ───────────────────────────────────────────────────────────

test('the milestone follows the board: shipped and delivered are stamps on a completed job', () => {
  assert.strictEqual(wa.milestoneOf({ status: 'pending' }), 'received');
  assert.strictEqual(wa.milestoneOf({ status: 'printing' }), 'received');
  assert.strictEqual(wa.milestoneOf({ status: 'on_hold' }), 'received');
  assert.strictEqual(wa.milestoneOf({ status: 'completed' }), 'ready');
  assert.strictEqual(wa.milestoneOf({ status: 'completed', shippedAt: 'x' }), 'shipped');
  assert.strictEqual(wa.milestoneOf({ status: 'completed', shippedAt: 'x', deliveredAt: 'y' }), 'delivered');
  assert.strictEqual(wa.milestoneOf({ status: 'delivered' }), 'delivered');
  for (const none of [{ status: 'quote' }, { status: 'cancelled' }, { status: 'split' },
    { status: 'completed', voidedAt: 'x' }, {}, null]) {
    assert.strictEqual(wa.milestoneOf(none), null);
  }
});

// ── The language ────────────────────────────────────────────────────────────

test('the customer\'s language: set, then read from the names, then the shop\'s', () => {
  assert.strictEqual(wa.customerLanguage({ messageLang: 'en', nameAr: 'ليلى' }, 'ar'), 'en');
  assert.strictEqual(wa.customerLanguage({ messageLang: 'ar', nameEn: 'Layla' }, 'en'), 'ar');
  assert.strictEqual(wa.customerLanguage({ nameAr: 'ليلى' }, 'en'), 'ar');
  assert.strictEqual(wa.customerLanguage({ nameEn: 'Layla' }, 'ar'), 'en');
  assert.strictEqual(wa.customerLanguage({ nameEn: 'Layla', nameAr: 'ليلى' }, 'en'), 'en');
  assert.strictEqual(wa.customerLanguage({ nameEn: 'Layla', nameAr: 'ليلى' }, 'ar'), 'ar');
  assert.strictEqual(wa.customerLanguage({}, 'fr'), 'ar');
  assert.strictEqual(wa.customerLanguage(null, 'en'), 'en');
});

// ── The words ───────────────────────────────────────────────────────────────

const SETTINGS = { bizEn: 'Athar Tuwaiq', bizAr: 'أثر طويق' };
const CLIENT = { id: 'C1', nameEn: 'Layla', nameAr: 'ليلى', phone: '0501234567' };

test('every milestone has a default in both languages, with no braces left over', () => {
  for (const m of wa.MILESTONES) {
    for (const lang of wa.LANGS) {
      assert.ok(wa.DEFAULT_BODIES[m][lang], `${m}/${lang}`);
      const order = { id: 'ORD-9', status: 'completed', shippedAt: 'x', carrier: 'smsa', trackingNumber: 'TRK1' };
      const out = wa.messageText({ order, client: CLIENT, settings: SETTINGS, milestone: m, lang });
      assert.ok(!out.text.includes('{{'), out.text);
      assert.ok(out.text.includes('ORD-9'), out.text);
      assert.strictEqual(out.isDefault, true);
    }
  }
});

test('English: names, shop and order are the English ones', () => {
  const out = wa.messageText({
    order: { id: 'ORD-1', status: 'completed' }, client: CLIENT, settings: SETTINGS,
    milestone: 'ready', lang: 'en',
  });
  assert.strictEqual(out.text,
    'Hi Layla, good news: your order ORD-1 is ready. Reply here to arrange pickup or delivery.\n— Athar Tuwaiq');
});

test('Arabic: names and shop are the Arabic ones', () => {
  const out = wa.messageText({
    order: { id: 'ORD-1', status: 'pending' }, client: CLIENT, settings: SETTINGS,
    milestone: 'received', lang: 'ar',
  });
  assert.strictEqual(out.text,
    'مرحباً ليلى، شكراً لطلبك من أثر طويق. استلمنا طلبك رقم ORD-1 وسنبلغك فور جاهزيته.');
});

test('a name missing in one language falls back to the other, then to the job', () => {
  const ar = wa.messageText({ order: { id: 'O', status: 'pending' }, client: { nameEn: 'Sam' },
    settings: { bizEn: 'Shop' }, milestone: 'received', lang: 'ar' });
  assert.ok(ar.text.includes('Sam') && ar.text.includes('Shop'), ar.text);
  const job = wa.messageText({ order: { id: 'O', status: 'pending', client: 'Walk-in' }, client: {},
    settings: {}, milestone: 'received', lang: 'en' });
  assert.ok(job.text.startsWith('Hi Walk-in,'), job.text);
});

test('shipped carries the carrier and tracking number, in both languages', () => {
  const order = { id: 'ORD-2', status: 'completed', shippedAt: 'x', carrier: 'smsa', trackingNumber: '290012345' };
  const en = wa.messageText({ order, client: CLIENT, settings: SETTINGS, milestone: 'shipped', lang: 'en' });
  assert.strictEqual(en.text,
    'Hi Layla, your order ORD-2 is on its way.\nCarrier: SMSA\nTracking number: 290012345\n— Athar Tuwaiq');
  const ar = wa.messageText({ order, client: CLIENT, settings: SETTINGS, milestone: 'shipped', lang: 'ar' });
  assert.strictEqual(ar.text,
    'مرحباً ليلى، تم شحن طلبك رقم ORD-2.\nشركة الشحن: SMSA\nرقم التتبع: 290012345\n— أثر طويق');
});

test('shipped without tracking leaves the tracking and carrier lines out, not blank', () => {
  const order = { id: 'ORD-3', status: 'completed', shippedAt: 'x', carrier: 'manual' };
  const en = wa.messageText({ order, client: CLIENT, settings: SETTINGS, milestone: 'shipped', lang: 'en' });
  assert.strictEqual(en.text, 'Hi Layla, your order ORD-3 is on its way.\n— Athar Tuwaiq');
});

test('the shop\'s own template wins: exact language first, then any language', () => {
  const templates = [
    { id: 'T0', name: 'plain', body: 'not a milestone' },
    { id: 'T1', name: 'Ready', body: 'Ready {{id}}', milestone: 'ready' },
    { id: 'T2', name: 'جاهز', body: 'جاهز {{id}} {{client}}', milestone: 'ready', lang: 'ar' },
    { id: 'T3', name: 'empty', body: '   ', milestone: 'delivered', lang: 'en' },
  ];
  const order = { id: 'O7', status: 'completed' };
  const ar = wa.messageText({ order, client: CLIENT, settings: SETTINGS, templates, milestone: 'ready', lang: 'ar' });
  assert.deepStrictEqual(ar, { text: 'جاهز O7 ليلى', templateId: 'T2', isDefault: false });
  const en = wa.messageText({ order, client: CLIENT, settings: SETTINGS, templates, milestone: 'ready', lang: 'en' });
  assert.deepStrictEqual(en, { text: 'Ready O7', templateId: 'T1', isDefault: false });
  // An empty body is no template at all.
  const dl = wa.templateFor(templates, 'delivered', 'en');
  assert.strictEqual(dl.isDefault, true);
});

test('{{status}} is the stage in the customer\'s words, and host values override', () => {
  const templates = [{ id: 'T', body: '{{status}} · {{price}} {{currency}}', milestone: 'received' }];
  const order = { id: 'O', status: 'printing' };
  const ar = wa.messageText({ order, client: CLIENT, settings: SETTINGS, templates, milestone: 'received',
    lang: 'ar', values: { price: '120.00', currency: 'SAR' } });
  assert.strictEqual(ar.text, 'قيد الطباعة · 120.00 SAR');
  const en = wa.messageText({ order, client: CLIENT, settings: SETTINGS, templates, milestone: 'received', lang: 'en' });
  assert.strictEqual(en.text, 'being printed ·  ');
});

// ── The whole update ────────────────────────────────────────────────────────

test('buildUpdate: the job\'s milestone, the customer\'s language, a ready link', () => {
  const out = wa.buildUpdate({
    order: { id: 'ORD-1', status: 'completed' },
    client: { nameAr: 'ليلى', phone: '050 123 4567' }, settings: SETTINGS, shopLang: 'en',
  });
  assert.strictEqual(out.ok, true);
  assert.strictEqual(out.milestone, 'ready');
  assert.strictEqual(out.lang, 'ar');
  assert.strictEqual(out.e164, '+966501234567');
  assert.ok(out.link.startsWith('https://wa.me/966501234567?text='));
  assert.strictEqual(decodeURIComponent(out.link.split('?text=')[1]), out.text);
});

test('buildUpdate refuses clearly, but still gives the text to copy', () => {
  const order = { id: 'O', status: 'pending' };
  const noPhone = wa.buildUpdate({ order, client: { nameEn: 'A' }, settings: SETTINGS });
  assert.strictEqual(noPhone.ok, false);
  assert.strictEqual(noPhone.reason, 'no_phone');
  assert.ok(noPhone.text.length > 0);
  assert.strictEqual(noPhone.link, '');
  assert.strictEqual(wa.buildUpdate({ order, client: { phone: '07700900123' } }).reason, 'no_country_code');
  assert.strictEqual(wa.buildUpdate({ order, client: null }).reason, 'no_customer');
  assert.strictEqual(wa.buildUpdate({ order: { status: 'quote' }, client: CLIENT }).reason, 'no_milestone');
  // An explicit milestone and language override the job's and the customer's.
  const forced = wa.buildUpdate({ order, client: CLIENT, milestone: 'delivered', lang: 'en', settings: SETTINGS });
  assert.strictEqual(forced.milestone, 'delivered');
  assert.ok(forced.text.includes('has been delivered'));
});

// ── The log ─────────────────────────────────────────────────────────────────

test('the log line is the editor\'s shape plus the job and milestone', () => {
  const e = wa.commEntry({ id: 'CMM-1', at: '2026-09-26T10:00:00.000Z', text: 'hi',
    orderId: 'ORD-1', milestone: 'ready', lang: 'ar' });
  assert.deepStrictEqual(e, { id: 'CMM-1', type: 'whatsapp', note: 'hi', at: '2026-09-26T10:00:00.000Z',
    orderId: 'ORD-1', milestone: 'ready', lang: 'ar' });
  const bare = wa.commEntry({ id: 'CMM-2', at: 'x', text: 't', milestone: 'nope' });
  assert.deepStrictEqual(bare, { id: 'CMM-2', type: 'whatsapp', note: 't', at: 'x' });
});

test('sentAt finds the newest matching WhatsApp line only', () => {
  const log = [
    { type: 'whatsapp', orderId: 'O1', milestone: 'ready', at: '2026-09-01T00:00:00Z' },
    { type: 'whatsapp', orderId: 'O1', milestone: 'ready', at: '2026-09-03T00:00:00Z' },
    { type: 'email', orderId: 'O1', milestone: 'shipped', at: '2026-09-04T00:00:00Z' },
    { type: 'whatsapp', orderId: 'O2', milestone: 'ready', at: '2026-09-05T00:00:00Z' },
    null,
  ];
  assert.strictEqual(wa.sentAt(log, 'O1', 'ready'), '2026-09-03T00:00:00Z');
  assert.strictEqual(wa.sentAt(log, 'O1', 'shipped'), null);
  assert.strictEqual(wa.sentAt(undefined, 'O1', 'ready'), null);
});
