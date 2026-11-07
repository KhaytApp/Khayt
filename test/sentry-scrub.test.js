'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { scrubSentryEvent } = require('../lib/main/sentry-scrub.js');

test('a Sentry event leaves with no e-mail, phone, IBAN, long digits or secret', () => {
  const ev = scrubSentryEvent({
    message: 'failed for ali@example.com',
    exception: { values: [{ value: 'call +966 55 123 4567 about SA0380000000608010167519 order 1234567890123',
      stacktrace: { frames: [{ filename: '/Users/ali/AppData/Khayt/x.js', vars: { token: 'abc' }, context_line: 'pay(5555444433332222)' }] } }] },
    breadcrumbs: [{ message: 'GET https://x.test/api?apikey=sk_live_abcdefghijk', data: { url: 'https://x.test/?email=a@b.co', authorization: 'Bearer zzzzzzzzzz', status: 500 } }],
    request: { url: 'file:///Users/ali/index.html?q=a@b.co', headers: { cookie: 'x' }, query_string: 'q=1' },
    extra: { url: 'mail me at ali@example.com', apiKey: 'k', line: 12 },
    user: { email: 'ali@example.com' },
  });
  const all = JSON.stringify(ev);
  for (const bad of ['ali@example.com', 'a@b.co', '123 4567', 'SA0380000000608010167519', '1234567890123',
    '5555444433332222', 'sk_live_abcdefghijk', 'zzzzzzzzzz', 'cookie', 'query_string', '"vars"', '"user"', 'apiKey']) {
    assert.ok(!all.includes(bad), `${bad} reached Sentry: ${all}`);
  }
  assert.equal(ev.extra.line, 12);
  assert.equal(ev.breadcrumbs[0].data.status, 500);
});

test('main.js scrubs in beforeSend and fails closed', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /scrubSentryEvent\(event\); \} catch \(_\) \{ return null; \}/);
  assert.match(main, /beforeBreadcrumb:/);
});
