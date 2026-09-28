const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { subscriberSource, SUBSCRIBER_PATH, FIELDS } = require('../lib/medusa-subscriber.js');
const { storefront, MARKETS } = require('../lib/integrations-registry.js');

const URL = 'https://cloud.khaytapp.com/v1/shops/abc123/import/medusa';

test('the generated subscriber carries the shop\'s own import URL', () => {
  const src = subscriberSource(URL);
  assert.ok(src.includes(`const GENERATED_IMPORT_URL = "${URL}"`), 'URL is baked in');
  assert.ok(src.includes('event: "order.placed"'), 'listens to the right event');
  assert.ok(src.includes(SUBSCRIBER_PATH), 'names the file it should be saved as');
});

test('it fetches the order, because the event does not carry one', () => {
  // This is the whole reason Medusa needs code rather than a webhook URL:
  // order.placed hands a subscriber `{ id }`. A generated file that POSTed
  // `data` straight through would send Khayt an object with one property.
  const src = subscriberSource(URL);
  assert.ok(src.includes('SubscriberArgs<{ id: string }>'), 'typed as the id-only payload');
  // Through Medusa's own order-detail workflow, which is the one read that
  // works out payment_status (see 'payment status is asked of the workflow').
  assert.ok(src.includes('getOrderDetailWorkflow(container).run('), 'resolves the order before sending');
  assert.ok(src.includes('order_id: data.id'));
  // It posts `payload` — the order with the product's material folded onto each
  // line and the product object dropped. Still the order, not the event.
  assert.ok(src.includes('JSON.stringify(payload)'), 'sends the ORDER, not the event payload');
  assert.ok(src.includes('const payload = {') && src.includes('...rest,'), 'and payload is built from the order');
  assert.ok(!/body: JSON\.stringify\(data\)/.test(src), 'must not post the bare event payload');
});

test('every expandable field the mapper reads is requested', () => {
  // Medusa marks items and the addresses @expandable: a graph query that does
  // not name them returns an order without them, and the import lands with no
  // line items and no customer name. That failure looks like a Khayt bug and is
  // not one, so the field list is pinned here.
  const src = subscriberSource(URL);
  for (const f of ['items.*', 'shipping_address.*', 'billing_address.*', 'display_id', 'email']) {
    assert.ok(FIELDS.includes(f), `${f} in FIELDS`);
    assert.ok(src.includes(`"${f}"`), `${f} requested in the generated query`);
  }
});

test('a failed POST is thrown, so Medusa retries it', () => {
  /* This used to assert the opposite, and the reason it did has gone away.
   *
   * A subscriber that throws is retried by Medusa, and swallowing was right
   * while a retry could become a second order request. The import endpoint
   * deduplicates on `medusa:#{display_id}`, answers 200 to a repeat with
   * `duplicate: true`, and notifies the shop only on a genuine first delivery —
   * proven by a contract test against both backends, not assumed.
   *
   * So swallowing is now the worse option: it puts a failed import in a log and
   * nowhere else. Throwing means Medusa keeps trying until it lands.
   */
  const src = subscriberSource(URL);
  assert.ok(src.includes('try {') && src.includes('catch'), 'the POST is still guarded');
  assert.ok(/logger\.error/.test(src), 'and the failure is still reported before it propagates');
  assert.ok(/throw new Error\(/.test(src), 'a non-2xx throws');
  assert.ok(/throw e/.test(src), 'and an unreachable endpoint rethrows rather than being swallowed');
});

test('the URL cannot break out of the string literal it is placed in', () => {
  // It is Khayt's own cloud URL, not a stranger's — but "it comes from our own
  // settings" is how injection bugs get argued for, and this file is handed to a
  // shop to run.
  const nasty = 'https://x/"; process.exit(1); const y = "';
  const src = subscriberSource(nasty);
  const line = src.split('\n').find((l) => l.startsWith('const GENERATED_IMPORT_URL'));
  assert.equal(line, 'const GENERATED_IMPORT_URL = "https://x/\\"; process.exit(1); const y = \\""');
  // And no newline can split the declaration across lines.
  assert.equal(subscriberSource('https://x/\n\ndelete-everything')
    .split('\n').filter((l) => l.includes('GENERATED_IMPORT_URL =')).length, 1);
});

test('junk in does not throw', () => {
  for (const v of [undefined, null, '', 0, {}, []]) {
    assert.equal(typeof subscriberSource(v), 'string', String(v));
  }
});

test('Medusa is offered in every market, and marked as needing code', () => {
  const sf = storefront('medusa');
  assert.ok(sf, 'registered');
  assert.equal(sf.name, 'Medusa');
  assert.deepEqual(sf.dir, ['in'], 'inbound only — Khayt does not publish a catalog to Medusa');
  assert.equal(sf.setup, 'subscriber', 'the directory uses this to offer the code button');

  // Self-hosted, so it is not a market's local platform — it is available in all
  // of them, and a shop switching the market selector should not lose it.
  for (const [loc, m] of Object.entries(MARKETS)) {
    assert.ok(m.storefronts.some((s) => s.id === 'medusa'), `medusa listed for ${loc}`);
  }
});

test('the renderer actually loads the module it calls', () => {
  // renderer/settings.js calls KhaytMedusa.subscriberSource; a global that is
  // never scripted in is a button that silently copies nothing.
  const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
  assert.ok(html.includes('lib/medusa-subscriber.js'), 'script tag present');
  const settings = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'settings.js'), 'utf8');
  assert.ok(settings.includes('KhaytMedusa.subscriberSource'), 'the renderer uses it');
});

test('a fallback the mapper relies on is actually requested', () => {
  // The 2026-08-27 audit's finding here, and it is the quiet kind: the cloud
  // mapper reads `custom_display_id` when `display_id` is empty, and reads
  // `it.detail.quantity` when a line item carries no quantity of its own.
  // Neither was in the field list, so neither could ever arrive — the fallbacks
  // read as handled cases and were dead code. A ref fell through to the raw
  // internal id instead of the number the shop and the buyer both say aloud.
  const src = subscriberSource(URL);
  for (const f of ['custom_display_id', 'items.detail.*']) {
    assert.ok(FIELDS.includes(f), `${f} in FIELDS`);
    assert.ok(src.includes(`"${f}"`), `${f} requested in the generated query`);
  }

  // `items.*` does NOT expand a nested relation — Medusa's own shipped
  // subscriber lists `items.product.is_giftcard` explicitly alongside `items.*`
  // for that exact reason — so `items.detail.*` has to stand on its own line
  // and is not implied by the wildcard above it.
  assert.ok(FIELDS.includes('items.*'), 'the wildcard is still there');
  assert.notEqual(FIELDS.indexOf('items.detail.*'), FIELDS.indexOf('items.*'));
});

test('the generated file imports its types the way Medusa itself does', () => {
  // Medusa's own subscribers use `import type { SubscriberArgs, SubscriberConfig }`.
  // Khayt imported SubscriberArgs as a VALUE, which compiles under the default
  // starter tsconfig (it sets neither verbatimModuleSyntax nor isolatedModules)
  // and stops compiling the moment a shop turns either on. This is a file Khayt
  // hands someone to paste into a repository it will never see, so matching the
  // vendor's own form costs nothing and removes a break Khayt could not observe.
  const src = subscriberSource(URL);
  assert.match(src, /import type \{ SubscriberArgs, SubscriberConfig \} from "@medusajs\/framework"/);
  assert.ok(!/import \{ SubscriberArgs/.test(src), 'a type is never imported as a value');
});

test('the event and its payload are the ones Medusa emits', () => {
  // Verified against Medusa's own source, not inferred: OrderWorkflowEvents
  // declares `PLACED: "order.placed"` with an @eventPayload of `{ id }`. If
  // either changed, this subscriber would sit in a shop's repo firing never,
  // and nothing on either side would say so.
  const src = subscriberSource(URL);
  assert.match(src, /event: "order\.placed"/);
  assert.match(src, /SubscriberArgs<\{ id: string \}>/);
  assert.match(src, /order_id: data\.id/, 'the id from the event is what is fetched');
});

test('material is fetched from the product, because the line does not carry it', () => {
  /* `material` is a native PRODUCT column. The line-item DTO denormalises some
   * product columns — product_title, product_description, product_subtitle —
   * but not that one, so a subscriber asking only for `items.*` sends nothing
   * for it, for ever, silently. Khayt's importer reads `items[].metadata`, so
   * the subscriber has to fetch the product's column and fold it onto the line.
   *
   * Found by the integrator running the first real Medusa storefront, against a
   * freshly migrated database rather than the DTO's types — which cannot tell
   * you what the module graph can traverse.
   */
  const src = subscriberSource(URL);
  assert.ok(FIELDS.includes('items.product.*'),
    '`items.*` does not bring material — the relation has to be named (`.*` is its own columns, material among them)');
  assert.match(src, /material: line\.metadata\?\.material \?\? product\?\.material/,
    'folded onto the line, with the line winning so a commission can override the catalogue');
  assert.match(src, /\(\{ product, variant, \.\.\.line \}/,
    'and the product is taken apart rather than sent whole');
  assert.match(src, /product: product \? \{ external_id: product\.external_id/,
    'only the ids that match the line to the catalogue go back out');
});

test('the admin link is optional and never invented', () => {
  // Khayt cannot derive it: the admin lives wherever the shop hosts it. Absent
  // env var means no admin_url key at all, rather than a broken link.
  const src = subscriberSource(URL);
  assert.match(src, /const MEDUSA_ADMIN_URL = \(process\.env\.MEDUSA_ADMIN_URL \?\? ""\)/);
  assert.match(src, /MEDUSA_ADMIN_URL \? \{ admin_url:/, 'only added when it is set');
});

// ── Paid orders and lines as data (docs/handoffs/webstore-order-status.md, §A) ──

const { createHash } = require('crypto');
const CLOUD_PENDING = ['payment_status', 'items.product.*', 'items.variant.*',
  'items.variant.options.*', 'items.variant.options.option.*'];

test('every field Khayt Cloud listed as pending is requested', () => {
  // khayt-cloud's contracts/medusa-subscriber-fields.json names these as read
  // by its mapper and not yet asked for. Until they are, `paid` and `lines[]`
  // can never be built for a Medusa order, and it waits for a person.
  const src = subscriberSource(URL);
  for (const f of CLOUD_PENDING) {
    assert.ok(FIELDS.includes(f), `${f} in FIELDS`);
    assert.ok(src.includes(`"${f}"`), `${f} requested in the generated query`);
  }
  assert.equal(new Set(FIELDS).size, FIELDS.length, 'no field is listed twice');
});

test('FIELDS hashes to the value khayt-cloud must pin', () => {
  /* khayt-cloud's contract test pins sha256(JSON.stringify(FIELDS)). Changing
   * FIELDS here means that repo's copy must move too, so the hash is pinned on
   * THIS side as well: a change to the list fails here first, with the number
   * the other lane needs. */
  const sha = createHash('sha256').update(JSON.stringify(FIELDS)).digest('hex');
  assert.equal(sha, '3db7e319a97baeee6cc3b3aecfacb7ec9b22f9f86639ad997e29a591dea0cecb');
});

test('payment status is asked of the workflow, because a bare graph query cannot answer it', () => {
  /* Measured against a migrated Medusa 2.21.1 database, not assumed:
   * query.graph accepts `payment_status` and answers undefined, for ever — it
   * is not a column. getOrderDetailWorkflow computes it from the payment
   * collections (getLastPaymentStatus) and answers "captured", "not_paid" …
   * A subscriber that asked the graph would send no payment status, and no
   * Medusa order would ever become a paid job. */
  const src = subscriberSource(URL);
  assert.match(src, /import \{ getOrderDetailWorkflow \} from "@medusajs\/medusa\/core-flows"/);
  assert.ok(!src.includes('query.graph('), 'no bare graph query remains');
  // What the workflow adds to do its sum is not Khayt's business.
  assert.match(src, /const \{ payment_collections, fulfillments, \.\.\.rest \} = order/);
  // A missing order is still a warning, not a retry storm.
  assert.match(src, /e\?\.type === "not_found"/);
});

test('the chosen options travel as title and value', () => {
  const src = subscriberSource(URL);
  assert.ok(src.includes('options: (variant.options ?? []).map((o: any) => ({ value: o?.value, option: { title: o?.option?.title } }))'));
});

test('the import key comes from the environment and is sent as a header', () => {
  const src = subscriberSource(URL);
  assert.ok(src.includes('const KHAYT_IMPORT_KEY = (process.env.KHAYT_IMPORT_KEY ?? "").trim()'));
  assert.ok(src.includes('...(KHAYT_IMPORT_KEY ? { "X-Khayt-Import-Key": KHAYT_IMPORT_KEY } : {})'),
    'sent only when set — an empty header would be a wrong key, and refused');
  assert.ok(!/[?&]key=/.test(src), 'never in the URL, where it would reach logs');
  // A 401 names the fix, rather than reading like Khayt being down.
  assert.ok(src.includes('res.status === 401'));
  assert.ok(src.includes('KHAYT_IMPORT_KEY is missing or out of date'));
});

test('an unset key is said once, not on every order', () => {
  const src = subscriberSource(URL);
  assert.ok(src.includes('let saidSetup = false'));
  assert.match(src, /if \(!saidSetup\) \{\s*saidSetup = true/);
  assert.equal((src.match(/logger\.warn\("Khayt: KHAYT_IMPORT_KEY is not set/g) || []).length, 1);
});

test('no key is ever embedded in the generated source', () => {
  // subscriberSource takes the URL and nothing else, so there is no way to hand
  // it a key. Pinned so a later "convenience" parameter has to delete this test.
  assert.equal(subscriberSource.length, 1, 'one parameter: the import URL');
  const src = subscriberSource(URL);
  assert.ok(!/ik_[A-Za-z0-9_-]{8,}/.test(src));
  assert.ok(!/"X-Khayt-Import-Key": "/.test(src), 'the header value is never a literal');
});

test('the generated comments tell the shop what the key does', () => {
  const src = subscriberSource(URL);
  assert.ok(src.includes("KHAYT_IMPORT_KEY  Your shop's import key"));
  assert.ok(src.includes('restart it after setting any of them'));
  assert.ok(src.includes('KHAYT_IMPORT_URL  Where to send orders'));
  assert.ok(src.includes('MEDUSA_ADMIN_URL  Your admin\'s bare origin'));
  assert.ok(src.includes('/app/orders/{id}, where Medusa v2 serves it'));
});

// ── Running the generated file, not reading it ─────────────────────────────
//
// The checks above match text. These RUN the subscriber: the TypeScript is
// stripped of its types by Node itself, the three Medusa imports are replaced
// by stand-ins, and the handler is called with a fake container and fetch.
// Behaviour the storefront verified against its live Medusa v2 is pinned here.

const { stripTypeScriptTypes } = require('node:module');
const canRun = typeof stripTypeScriptTypes === 'function';

const ORDER = {
  id: 'order_01', display_id: 42, email: 'a@b.c', payment_status: 'captured', metadata: {},
  payment_collections: [{ status: 'captured' }], fulfillments: [],
  items: [{ title: 'Dragon', quantity: 1, unit_price: 50, metadata: {},
    product: { external_id: 'cat_1', material: 'PLA', title: 'x' },
    variant: { id: 'v', title: 'Red', sku: 's', options: [{ value: 'Red', option: { title: 'Colour' } }] } }],
};

/** Load the generated handler under the given environment. */
function load(env = {}, { order = ORDER, respond = () => ({ ok: true, status: 200 }) } = {}) {
  let src = subscriberSource(URL);
  src = src.replace(/^import .*$/gm, '');
  src = src.replace('export default async function', 'async function')
    .replace('export const config', 'const config');
  const js = stripTypeScriptTypes(src);
  const calls = [];
  const logs = [];
  const fakeFetch = async (url, init) => {
    calls.push({ url, init });
    const r = respond(url, init);
    if (r instanceof Error) throw r;
    return { ok: r.status >= 200 && r.status < 300, status: r.status, text: async () => 'why' };
  };
  const logger = {};
  for (const level of ['info', 'warn', 'error']) logger[level] = (m) => logs.push([level, String(m)]);
  const container = { resolve: () => logger };
  const workflow = () => ({ run: async ({ input }) => {
    if (!order) { const e = new Error('Order id not found'); e.type = 'not_found'; throw e; }
    return { result: JSON.parse(JSON.stringify({ ...order, id: order.id || input.order_id })) };
  } });
  const fakeProcess = { env: { ...env } };
  // eslint-disable-next-line no-new-func
  const handler = new Function('ContainerRegistrationKeys', 'getOrderDetailWorkflow', 'fetch', 'process',
    `${js}\nreturn khaytOrderPlaced;`)({ LOGGER: 'logger' }, workflow, fakeFetch, fakeProcess);
  const run = () => handler({ event: { data: { id: 'order_01' } }, container });
  return { run, calls, logs };
}

test('the admin link is /app/orders/{id}, whichever way the origin is spelt', { skip: !canRun }, async () => {
  // Medusa v2 serves its admin under /app: /app/orders/{id} answers 200 and
  // /orders/{id} 404 (checked against the live storefront's Medusa).
  for (const spelt of ['https://admin.example.com', 'https://admin.example.com/',
    'https://admin.example.com/app', 'https://admin.example.com/app/', ' https://admin.example.com/app ']) {
    const h = load({ MEDUSA_ADMIN_URL: spelt });
    await h.run();
    const body = JSON.parse(h.calls[0].init.body);
    assert.equal(body.metadata.admin_url, 'https://admin.example.com/app/orders/order_01', spelt);
  }
  const none = load({});
  await none.run();
  assert.ok(!('admin_url' in JSON.parse(none.calls[0].init.body).metadata), 'unset means no link');
});

test('KHAYT_IMPORT_URL wins over the generated link, and where it goes is said once without the key', { skip: !canRun }, async () => {
  const h = load({ KHAYT_IMPORT_URL: ' https://staging.example/v1/shops/test/import/medusa?key=ik_SECRETSECRET ', KHAYT_IMPORT_KEY: 'ik_OTHERSECRET' });
  await h.run();
  await h.run();
  assert.equal(h.calls[0].url, 'https://staging.example/v1/shops/test/import/medusa?key=ik_SECRETSECRET');
  const said = h.logs.filter(([, m]) => m.includes('sending orders to'));
  assert.equal(said.length, 1, 'said once per start, not per order');
  assert.match(said[0][1], /staging\.example\/v1\/shops\/test\/import\/medusa \(from KHAYT_IMPORT_URL\)/);
  for (const [, m] of h.logs) assert.ok(!m.includes('SECRET'), `a log carries the key: ${m}`);

  const fallback = load({ KHAYT_IMPORT_URL: '   ' });
  await fallback.run();
  assert.equal(fallback.calls[0].url, URL, 'blank falls back to the generated link');
  assert.ok(fallback.logs.some(([, m]) => m.includes('(as generated)')));
});

test('the key header is sent exactly when the variable is set', { skip: !canRun }, async () => {
  const keyed = load({ KHAYT_IMPORT_KEY: ' ik_abc ' });
  await keyed.run();
  assert.equal(keyed.calls[0].init.headers['X-Khayt-Import-Key'], 'ik_abc');
  assert.ok(!keyed.logs.some(([, m]) => m.includes('KHAYT_IMPORT_KEY is not set')));

  const bare = load({});
  await bare.run();
  await bare.run();
  assert.ok(!('X-Khayt-Import-Key' in bare.calls[0].init.headers));
  assert.equal(bare.logs.filter(([, m]) => m.includes('KHAYT_IMPORT_KEY is not set')).length, 1);
});

test('only what a retry can fix is thrown: network, 5xx, 429 and 401', { skip: !canRun }, async () => {
  for (const status of [500, 502, 503, 429, 401]) {
    const h = load({}, { respond: () => ({ status }) });
    await assert.rejects(h.run(), undefined, `${status} must throw so Medusa retries`);
  }
  const offline = load({}, { respond: () => new Error('ECONNREFUSED') });
  await assert.rejects(offline.run(), /ECONNREFUSED/);
  assert.ok(offline.logs.some(([l, m]) => l === 'error' && m.includes('could not reach')));

  // Every other 4xx is about this order; sending it again cannot change it.
  for (const status of [400, 403, 404, 405, 409, 413, 422]) {
    const h = load({}, { respond: () => ({ status }) });
    await h.run();
    assert.equal(h.calls.length, 1);
    assert.ok(h.logs.some(([l, m]) => l === 'error' && m.includes(`${status}`) && m.includes('not retrying')), `${status} logged`);
  }
  const fine = load({});
  await fine.run();
  assert.ok(!fine.logs.some(([l]) => l === 'error'));
});

test('an order with no display number is not sent', { skip: !canRun }, async () => {
  for (const blank of [{ display_id: null }, { display_id: undefined, custom_display_id: '' }, { display_id: '  ' }]) {
    const h = load({}, { order: { ...ORDER, ...blank } });
    await h.run();
    assert.equal(h.calls.length, 0, JSON.stringify(blank));
    assert.ok(h.logs.some(([l, m]) => l === 'error' && m.includes('no display number')));
  }
  // A custom number alone is enough.
  const custom = load({}, { order: { ...ORDER, display_id: null, custom_display_id: 'WEB-7' } });
  await custom.run();
  assert.equal(custom.calls.length, 1);
});

test('what is sent: payment status in, bookkeeping out, lines trimmed', { skip: !canRun }, async () => {
  const h = load({});
  await h.run();
  const body = JSON.parse(h.calls[0].init.body);
  assert.equal(body.payment_status, 'captured');
  assert.ok(!('payment_collections' in body) && !('fulfillments' in body));
  const line = body.items[0];
  assert.deepEqual(line.product, { external_id: 'cat_1' });
  assert.equal(line.metadata.material, 'PLA');
  assert.deepEqual(line.variant.options, [{ value: 'Red', option: { title: 'Colour' } }]);

  const gone = load({}, { order: null });
  await gone.run();
  assert.equal(gone.calls.length, 0, 'a vanished order is a warning, not a send');
});
