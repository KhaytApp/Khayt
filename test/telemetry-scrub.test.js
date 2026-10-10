const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/telemetry-scrub.js');

// The things that must NEVER survive scrubbing, in the shapes Khayt actually holds them.
const SECRETS = [
  'sara.noor@example.com',
  '+966501234567',
  'SA0380000000608010167519',        // IBAN
  '4111111111111111',                // card-like long digit run
  '/Users/turki/Library/Application Support/Khayt/khayt-store.json',
  'C:\\Users\\Turki\\AppData\\Roaming\\Khayt\\store.json',
];

test('scrubText removes emails, phones, IBANs and long digit runs', () => {
  const out = S.scrubText('contact sara.noor@example.com or +966501234567, IBAN SA0380000000608010167519, card 4111111111111111');
  for (const s of ['sara.noor@example.com', '+966501234567', 'SA0380000000608010167519', '4111111111111111']) {
    assert.equal(out.includes(s), false, `leaked: ${s}`);
  }
  assert.ok(out.includes('<redacted>'));
});

test('scrubPath collapses absolute POSIX and Windows paths to a basename', () => {
  const posix = S.scrubPath('at load (/Users/turki/Library/Application Support/Khayt/khayt-store.json:12:5)');
  assert.equal(posix.includes('/Users/turki'), false, 'home dir leaked');
  assert.ok(posix.includes('khayt-store.json'), 'basename kept for debuggability');
  const win = S.scrubPath('C:\\Users\\Turki\\AppData\\Roaming\\Khayt\\store.json');
  assert.equal(win.includes('Turki'), false, 'windows username leaked');
  assert.ok(win.includes('store.json'));
});

test('isSecretKey catches every credential key shape the app uses', () => {
  for (const k of ['apiKey', 'api_key', 'smtpPassword', 'botToken', 'webhookSecret', 'pin', 'csid', 'pcsid', 'accessCode', 'authorization', 'privateKey']) {
    assert.equal(S.isSecretKey(k), true, `missed secret key: ${k}`);
  }
  assert.equal(S.isSecretKey('project'), false);
  assert.equal(S.isSecretKey('count'), false);
});

test('scrubValue masks secret-shaped keys anywhere in a nested object', () => {
  const out = S.scrubValue({
    settings: { lanApi: { pin: '1234', apiTokens: [{ hash: 'x', label: 'z' }] }, emailConfig: { apiKey: 'SG.real-key' } },
    note: 'call +966501234567',
  }, '', 0);
  const json = JSON.stringify(out);
  assert.equal(json.includes('SG.real-key'), false, 'api key leaked');
  assert.equal(json.includes('1234'), false, 'pin leaked');
  assert.equal(json.includes('+966501234567'), false, 'phone leaked');
  assert.ok(json.includes(S.SECRET_MASK));
});

test('HEADLINE GATE: a crash report seeded with PII/secrets/paths leaks nothing', () => {
  const report = S.buildCrashReport({
    type: 'uncaughtException',
    name: 'TypeError',
    message: `failed for sara.noor@example.com (+966501234567) IBAN SA0380000000608010167519 card 4111111111111111`,
    stack: [
      'TypeError: boom',
      '    at saveStore (/Users/turki/Library/Application Support/Khayt/khayt-store.json:12:5)',
      '    at load (C:\\Users\\Turki\\AppData\\Roaming\\Khayt\\store.json:3:1)',
    ].join('\n'),
    process: 'main', appVersion: '3.2.0', osFamily: 'macOS', osMajor: '14',
    locale: 'ar', channel: 'beta', installId: 'a1b2c3d4e5f6a7b8',
    // Upstream mistakes that must be dropped by the allowlist gate:
    clientEmail: 'leak@example.com', orderTotal: 1234.56, apiKey: 'SG.super-secret',
    storeSnapshot: { clients: [{ name: 'Sara', phone: '+966501234567' }] },
  });
  const json = JSON.stringify(report);
  for (const s of SECRETS) assert.equal(json.includes(s), false, `LEAKED: ${s}`);
  assert.equal(json.includes('SG.super-secret'), false, 'api key leaked');
  assert.equal(json.includes('leak@example.com'), false, 'extra field leaked');
  assert.equal(json.includes('Sara'), false, 'store snapshot leaked');
  assert.equal(json.includes('1234.56'), false, 'financials leaked');
  // Allowlist is exact — no extra keys survived.
  assert.deepEqual(Object.keys(report).sort(), S.CRASH_FIELDS.slice().sort());
  // Still useful for debugging.
  assert.equal(report.name, 'TypeError');
  assert.ok(report.stack.includes('khayt-store.json'));
});

test('buildCrashReport clamps enums and rejects a forged installId', () => {
  const r = S.buildCrashReport({ type: 'evil', process: 'evil', osFamily: 'evil', locale: 'evil', channel: 'evil', installId: 'not a uuid; DROP TABLE' });
  assert.equal(r.type, 'unknown');
  assert.equal(r.process, 'main');
  assert.equal(r.osFamily, 'unknown');
  assert.equal(r.locale, 'en');
  assert.equal(r.channel, 'stable');
  assert.equal(r.installId, '', 'forged install id rejected');
});

test('buildUsageEvent is counts+enums only — never string content', () => {
  const e = S.buildUsageEvent({
    feature: 'quote_created', count: 3, mode: 'professional', businessType: 'shop',
    vatEnabled: true, zatcaEnabled: false, onlineEnabled: true, lanEnabled: false,
    sessions: 12, appVersion: '3.2.0', locale: 'ar', channel: 'beta', installId: 'a1b2c3d4e5f6a7b8',
    // must be dropped:
    clientName: 'Sara Noor', orderId: 'INV-2026-0001', amount: 950,
  });
  const json = JSON.stringify(e);
  assert.equal(json.includes('Sara Noor'), false);
  assert.equal(json.includes('INV-2026-0001'), false);
  assert.equal(json.includes('950'), false);
  assert.deepEqual(Object.keys(e).sort(), S.USAGE_FIELDS.slice().sort());
  assert.equal(e.count, 3);
  assert.equal(e.mode, 'professional');
});

test('buildUsageEvent rejects a feature name carrying content', () => {
  assert.equal(S.buildUsageEvent({ feature: 'order for sara@example.com' }), null);
  assert.equal(S.buildUsageEvent({ feature: 'INV-2026-0001' }), null, 'ids are not enum-shaped');
  assert.equal(S.buildUsageEvent({}), null);
  assert.ok(S.buildUsageEvent({ feature: 'invoice_exported' }));
});

test('boundQueue caps the offline queue, keeping the newest', () => {
  const q = Array.from({ length: 500 }, (_, i) => ({ i }));
  const out = S.boundQueue(q, 200);
  assert.equal(out.length, 200);
  assert.equal(out[out.length - 1].i, 499);
  assert.deepEqual(S.boundQueue(null, 10), []);
});

test('dedupeCrashes collapses a crash storm of identical stacks', () => {
  const q = [
    { kind: 'crash', payload: { name: 'E', stack: 'same' } },
    { kind: 'crash', payload: { name: 'E', stack: 'same' } },
    { kind: 'crash', payload: { name: 'E', stack: 'other' } },
    { kind: 'usage', payload: { feature: 'a' } },
    { kind: 'usage', payload: { feature: 'a' } },
  ];
  const out = S.dedupeCrashes(q);
  assert.equal(out.filter(e => e.kind === 'crash').length, 2, 'identical stacks collapsed');
  assert.equal(out.filter(e => e.kind === 'usage').length, 2, 'usage counters untouched');
});

/* ── Secrets in free text (crash messages are strings, not keyed objects) ────── */

test('SECRET LEAK: a credential quoted inside a crash message is never transmitted', () => {
  // Each of these is a message an actual Khayt code path could throw. The key-based
  // masking in scrubValue() never sees them — a message is a string, not an object.
  const cases = [
    ['OctoPrint URL',   'GET http://192.168.1.50/api/job?apikey=A1B2C3D4E5F6G7H8I9J0KLMN', /A1B2C3D4/],
    ['Khayt API token', 'Unauthorized for Bearer khayt_9xKq2mPvR7tLwZ3nB8cF4hJ6dY1sA5gE', /khayt_9xKq/],
    ['webhook HMAC',    'hmac verify failed (secret=whsec_7f3a9c2e8b1d4056a2c9e7f1)',     /whsec_7f3a/],
    ['ZATCA cert pass', 'openssl error: -passin pass:Sh0p!Secret2026 rejected',            /Sh0p!Secret/],
    ['X-Api-Key header','fetch failed, headers: X-Api-Key: QWERTYUIOPASDFGH1234',          /QWERTYUIOP/],
    ['ZATCA csid',      'csid=ZATCA-CSID-abcdef123456 invalid',                            /CSID-abcdef/],
    ['LAN PIN',         'startLanServer rejected pin=884213',                              /884213/],
  ];
  for (const [label, message, forbidden] of cases) {
    const out = S.buildCrashReport({ type: 'uncaughtException', message });
    assert.ok(!forbidden.test(out.message), `CREDENTIAL LEAKED (${label}): ${out.message}`);
    assert.ok(out.message.includes(S.SECRET_MASK) || out.message.includes('<path>'),
      `${label} should be masked, got: ${out.message}`);
  }
});

test('a secret in a stack frame is masked too', () => {
  const stack = 'Error: auth\n    at post (/app/net.js:1:1) token=abcdef1234567890';
  assert.ok(!/abcdef1234567890/.test(S.scrubStack(stack)));
});

test('scrubSecrets keeps the key so the frame stays debuggable', () => {
  // Knowing WHICH credential failed is useful; knowing its value is not.
  const out = S.scrubSecrets('auth failed: api_key=SUPERSECRETVALUE123');
  assert.ok(out.includes('api_key'), 'key retained');
  assert.ok(!out.includes('SUPERSECRETVALUE123'), 'value masked');
});

test('a document filename cannot leak a customer name, but module names survive', () => {
  // A filename routinely carries a person's name — "mohammed-alqahtani-invoice.pdf".
  const doc = S.scrubText('ENOENT: open /Users/t/Khayt/exports/mohammed-alqahtani-invoice.pdf');
  assert.ok(!/mohammed|alqahtani/i.test(doc), `customer name leaked via filename: ${doc}`);
  assert.ok(doc.includes('.pdf'), 'extension kept — still says what kind of file it was');
  // Stack frames must stay readable, or crash reports are worthless.
  const frame = S.scrubText('at saveAll (/Users/t/Khayt/renderer/store.js:412:9)');
  assert.ok(frame.includes('store.js:412'), `module/line lost from stack frame: ${frame}`);
  assert.ok(!frame.includes('/Users/t'), 'home dir still stripped');
});

test('a deep stack fits the ingest, which refuses the whole event over 4,000 characters', () => {
  // khayt-cloud src/telemetry-ingest.js CAPS.stack. Thirty frames of up to 201
  // characters scrubbed to ~6,000, so a deep crash was queued, sent, refused (422)
  // and dropped — the reports most worth having were the ones that never arrived.
  const frame = (i) => `    at someVeryLongFunctionName_${i}_${'x'.repeat(110)} (renderer/app.js:${i}:1)`;
  const stack = Array.from({ length: 30 }, (_, i) => frame(i)).join('\n');
  const out = S.scrubStack(stack);
  assert.ok(out.length <= 4000, `stack is ${out.length} characters`);
  // Whole frames only: every line kept is a complete frame, not half of one.
  const lines = out.split('\n');
  assert.ok(lines.length > 10);
  assert.ok(lines.every((l) => l.endsWith(':1)')), 'a frame was cut in half');
  // A short stack is untouched by the cap.
  assert.equal(S.scrubStack('Error: x\n    at f (a.js:1:1)'), 'Error: x\n    at f (a.js:1:1)');
});

test('both telemetry modules publish a global for JavaScriptCore and read no `global`', () => {
  // The native Mac runs these files in JavaScriptCore, which has no `global` and
  // no `module` (#1789). A bare `global.X` read throws there and nowhere else.
  const fs = require('node:fs');
  const path = require('node:path');
  const vm = require('node:vm');
  for (const [file, name] of [['lib/telemetry-scrub.js', 'KhaytTelemetryScrub'],
                              ['lib/telemetry-sender.js', 'KhaytTelemetrySender']]) {
    const src = fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
    assert.ok(!/(^|[^.\w])global\./m.test(src), `${file} reads \`global.\``);
    const ctx = vm.createContext({});
    vm.runInContext(src, ctx);
    assert.equal(typeof vm.runInContext(name, ctx), 'object', `${file} defined no ${name}`);
  }
});
