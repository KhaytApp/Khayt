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

test('the Mac 4.0 alpha lane keeps its channel (khayt-cloud #114 accepts alpha)', () => {
  // An enum miss falls back to `stable`, so before `alpha` was listed every
  // Mac alpha would have been counted as a stable install.
  assert.equal(S.buildCrashReport({ channel: 'alpha' }).channel, 'alpha');
  assert.equal(S.buildUsageEvent({ feature: 'app_launch', channel: 'alpha' }).channel, 'alpha');
});

test('a quoted value is redacted, a quoted code name is kept', () => {
  const T = require('../lib/telemetry-scrub.js');
  assert.equal(T.scrubText("Cannot read properties of undefined (reading 'name')"),
    "Cannot read properties of undefined (reading 'name')");
  assert.equal(T.scrubText("No client 'Noura Al-Qahtani'"), "No client '<redacted>'");
  assert.equal(T.scrubText('Unknown material "Galaxy Black"'), 'Unknown material "<redacted>"');
  assert.equal(T.scrubText("bad value 'ريم'"), "bad value '<redacted>'");
  assert.equal(T.scrubText("No client 'Noura' for 'Noura_order.3mf'"),
    "No client '<redacted>' for '<redacted>'", 'one word, and a file name, are data too');
  assert.equal(T.scrubText("x 'order.items.length'"), "x 'order.items.length'");
});

test('a path with spaces is collapsed whole, not up to its first space', () => {
  // The privacy policy says a path is reduced to a file name. Stopping at a space
  // left the folder words after it in the report: "Drive", a customer's surname.
  const drive = S.scrubText('ENOENT /Users/turki/Library/CloudStorage/GoogleDrive-x@y.com/My Drive/Nouf Aldossari/lamp.3mf');
  assert.ok(!/turki|Drive|Nouf|Aldossari|lamp/.test(drive), `folder words leaked: ${drive}`);
  assert.ok(drive.includes('<path>/<file>.3mf'), drive);
  const win = S.scrubText('open C:\\Users\\Turki Alballaa\\AppData\\Roaming\\Khayt\\store.json');
  assert.ok(!/Turki|Alballaa|AppData|Roaming/.test(win), `windows path leaked: ${win}`);
  assert.equal(win, 'open <path>/store.json');
});

test('a stack frame through a folder with spaces keeps its module, line and column', () => {
  assert.equal(S.scrubText('    at foo (/Users/x y/app/lib/a.js:12:3)'), '    at foo (<path>/a.js:12:3)');
  assert.equal(S.scrubText('    at /Users/x y/app/lib/a.js:12:3'), '    at <path>/a.js:12:3');
  assert.equal(S.scrubText('at load (C:\\Users\\Turki A\\app\\store.js:3:1)'), 'at load (<path>/store.js:3:1)');
  // A slash inside a sentence is not a path that swallows the rest of it.
  assert.equal(S.scrubText('either/or 50 / 100'), 'either/or 50 / 100');
});

// A path is a path whatever comes before it: a JSC frame's `@`, a shell's
// `|` or `;`, markup's `<`, a brace. The second pass of the space fix only
// counted one after a space, a bracket or a quote, and leaked these whole.
const PATH_AFTER_ANY_LEAD = [
  ['open ~/Nouf Aldossari/lamp.3mf', 'open <path>/<file>.3mf'],
  ['foo</Users/turki/x.js>', 'foo<<path>/x.js>'],
  ['x{/Users/Nouf Aldossari/a.stl}', 'x{<path>/<file>.stl}'],
  ['x|/Users/turki/a.3mf', 'x|<path>/<file>.3mf'],
  ['x;/Users/turki/a.3mf', 'x;<path>/<file>.3mf'],
  ['x>/Users/turki/a.3mf', 'x><path>/<file>.3mf'],
  ['x*/Users/turki/a.3mf', 'x*<path>/<file>.3mf'],
  ['readStore@/Users/turki/Khayt/lib/x.js:12:3', 'readStore@<path>/x.js:12:3'],
  ['open ./Nouf/a.3mf', 'open <path>/<file>.3mf'],
];

test('a path is collapsed after any character that cannot be inside a word', () => {
  for (const [input, want] of PATH_AFTER_ANY_LEAD) assert.equal(S.scrubPath(input), want, input);
  // Words with a slash in them are not paths.
  assert.equal(S.scrubPath('and/or Trace/BPT KhaytApp/Shop.swift'), 'and/or Trace/BPT KhaytApp/Shop.swift');
  // The scrubber's own marker is not a path to collapse again.
  assert.equal(S.scrubPath(S.scrubPath('x>/Users/turki/a.3mf')), 'x><path>/<file>.3mf');
});

test('the sentence after a file name is kept, a space inside a folder name is not', () => {
  assert.equal(S.scrubPath('Failed /Users/a/b.3mf because disk full'), 'Failed <path>/<file>.3mf because disk full');
  assert.equal(S.scrubPath('Fatal error: file /Users/turki/src/KhaytApp/Shop.swift, line 120'),
    'Fatal error: file <path>/Shop.swift, line 120');
  assert.equal(S.scrubPath('copy /a/Nouf.v2 Aldossari/x.3mf to /b/c d/e.3mf now'),
    'copy <path>/<file>.3mf to <path>/<file>.3mf now');
  assert.equal(S.scrubPath('ENOENT /x/My Drive/Nouf Aldossari/lamp.3mf'), 'ENOENT <path>/<file>.3mf');
});

test('nothing the scrubber used to redact is leaked now', () => {
  // The scrubber before paths ran through spaces, verbatim. Every word it took
  // out of a path must still be out; the only words allowed back are a code
  // file's own name, which a stack frame needs.
  const CODE = /\.(?:js|mjs|cjs|ts|json|html|css|node)$/i;
  const oldBase = (name) => {
    const base = String(name || '');
    if (CODE.test(base)) return base;
    const dot = base.lastIndexOf('.');
    return dot > 0 ? '<file>' + base.slice(dot) : '<file>';
  };
  const oldScrubPath = (str) => str
    .replace(/(?:file:\/\/)?(?:\/[^\s:()]+)+/g, (m) => '<path>/' + oldBase(m.split('/').filter(Boolean).pop()))
    .replace(/[A-Za-z]:\\(?:[^\s:()\\]+\\)*([^\s:()\\]+)/g, (m, base) => '<path>/' + oldBase(base));
  const words = (s) => new Set(s.match(/[A-Za-z0-9]{2,}/g) || []);
  const kept = (s) => new Set((s.match(/[\w.-]+\.(?:js|mjs|cjs|ts|json|html|css|node|swift)\b/g) || [])
    .flatMap((f) => [...words(f)]));
  const corpus = [
    ...SECRETS,
    ...PATH_AFTER_ANY_LEAD.map(([input]) => input),
    'ENOENT /Users/turki/Library/CloudStorage/GoogleDrive-x@y.com/My Drive/Nouf Aldossari/lamp.3mf',
    'open C:\\Users\\Turki Alballaa\\AppData\\Roaming\\Khayt\\store.json',
    '    at foo (/Users/x y/app/lib/a.js:12:3)',
    '    at /Users/x y/app/lib/a.js:12:3',
    'at load (C:\\Users\\Turki A\\app\\store.js:3:1)',
    'at load (/Users/turki/Library/Application Support/Khayt/khayt-store.json:12:5)',
    'ENOENT: open /Users/t/Khayt/exports/mohammed-alqahtani-invoice.pdf',
    'at saveAll (/Users/t/Khayt/renderer/store.js:412:9)',
    'Error: auth\n    at post (/app/net.js:1:1) token=abcdef1234567890',
    'GET http://192.168.1.50/api/job?apikey=A1B2C3D4E5F6G7H8I9J0KLMN',
    'Failed /Users/a/b.3mf because disk full',
    'Fatal error: file /Users/turki/src/KhaytApp/Shop.swift, line 120',
    'copy /a/Nouf.v2 Aldossari/x.3mf to /b/c d/e.3mf now',
    'file:///Users/sara/Desktop/order.3mf',
  ];
  for (const input of corpus) {
    const before = words(oldScrubPath(input));
    const now = S.scrubPath(input);
    const allowed = kept(now);
    const leaked = [...words(input)].filter((w) => !before.has(w) && words(now).has(w) && !allowed.has(w));
    assert.deepEqual(leaked, [], `${input} -> ${now}`);
  }
});
