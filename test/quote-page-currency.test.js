/**
 * The quote approval page must not name a currency it does not know.
 *
 * This page is where a CUSTOMER agrees to a price. It used to default the unit to
 * 'SAR' in two places — the caller in lib/lan-server.js and the parameter default
 * here — and Khayt ships a flavour (Bed Ready) whose default currency is USD. A
 * shop whose store carried no `settings.currency` therefore showed "100 SAR" for a
 * $100 quote: understating it roughly 3.75x, to the one person who cannot check.
 *
 * Reachable because the LAN server reads the store straight off disk, with no
 * defaultSettings() merge behind it — unlike the renderer, where settings.currency
 * is always present, which is why the two dozen `settings.currency || 'SAR'`
 * fallbacks over there are unreachable and were left alone.
 *
 * Reproduced against the real server before the fix: the page rendered
 * `100 SAR`. After: `100`.
 *
 * A missing unit is ambiguous. A wrong one is a lie with a number attached.
 *
 * ONE MUTANT SURVIVES, AND SHOULD.
 *
 * Restoring the unconditional space — `${price} ${esc(currencyLabel)}` — is not
 * caught, and chasing it would be over-fitting. lanEscapeHtml is `String(s ?? '')`,
 * so an absent label renders a trailing space and nothing else; "100 " and "100"
 * are the same to every reader. The conditional is tidiness. The two mutations
 * that matter — either default coming back — are both killed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { renderLanQuoteApprovalPage } = require('../lib/lan-quote-page.js');

const order = { id: 'Q1', project: 'bracket', price: 100, quoteApprovalToken: 'tok', parts: [] };
const page = (over = {}) => renderLanQuoteApprovalPage({
  order, shopName: 'A Shop', approvePath: '/order/Q1/approve', approvalToken: 'tok', ...over,
});

/** The total cell, which is the only place money is shown. */
const totalCell = (html) => {
  const m = html.match(/class="total-row"><td>Total<\/td><td[^>]*>([^<]*)</);
  assert.ok(m, 'could not find the total row — this test is blind, fix the extraction');
  return m[1].trim();
};

test('an unknown currency shows the number with no unit', () => {
  assert.equal(totalCell(page()), '100');
  assert.equal(totalCell(page({ currencyLabel: '' })), '100');
  assert.equal(totalCell(page({ currencyLabel: null })), '100');
  assert.equal(totalCell(page({ currencyLabel: undefined })), '100');
});

test('a known currency is shown', () => {
  assert.equal(totalCell(page({ currencyLabel: 'SAR' })), '100 SAR');
  assert.equal(totalCell(page({ currencyLabel: 'USD' })), '100 USD');
  assert.equal(totalCell(page({ currencyLabel: 'EUR' })), '100 EUR');
});

test('the page never invents SAR on its own', () => {
  // The specific regression: no code path may put SAR on a page whose caller did
  // not ask for it. Checked across the WHOLE page, not just the total, since the
  // unit could reappear in a summary line later.
  for (const label of [undefined, '', null, 'USD']) {
    const html = page({ currencyLabel: label });
    assert.ok(!/\bSAR\b/.test(html), `currencyLabel=${String(label)} produced SAR somewhere on the page`);
  }
});

test('the caller passes the shop currency through without a default', () => {
  // The other half of the fix lives in lib/lan-server.js. A default restored
  // there would put SAR back on the page with this file unchanged, so the guard
  // has to look at both.
  const fs = require('node:fs');
  const path = require('node:path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'lan-server.js'), 'utf8');
  const m = src.match(/currencyLabel:\s*([^\n,]+)/);
  assert.ok(m, 'lan-server no longer passes currencyLabel — check this still applies');
  assert.ok(!/'SAR'|"SAR"/.test(m[1]),
    `lan-server defaults the currency to SAR again: ${m[1].trim()}`);
});

test('a currency label is escaped, not interpolated raw', () => {
  const html = page({ currencyLabel: '<script>x</script>' });
  assert.ok(!html.includes('<script>x</script>'), 'the label must be escaped');
});

/**
 * The same class, one page over: the customer intake form's budget ranges.
 *
 * Those said "Less than 100 SAR" as a LITERAL — not a fallback, so no store
 * setting could change it. Khayt ships a USD flavour, where every customer who
 * opened the form was asked to pick a budget on the wrong scale, every time.
 * Found by widening the sweep from `|| 'SAR'` to money rendered any other way.
 *
 * Checked against a running server: SAR shop → "Less than 100 SAR", USD shop →
 * "Less than 100 USD", no currency → "Less than 100".
 */
const fs = require('node:fs');
const path = require('node:path');

test('the intake budget ranges are not hardcoded to one currency', () => {
  // The template lives in the shared module now (`lib/lan-intake.js`), which
  // the Mac app serves from as well; the server only calls it.
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'lan-intake.js'), 'utf8');
  const form = src.match(/const renderIntakeFormPage = [\s\S]*?\n\s*(?:const|let|\/\/|\}|\/\*\*)/);
  assert.ok(form, 'could not find renderIntakeFormPage — this test is blind, fix the extraction');
  const body = form[0];

  assert.match(body, /Budget Range/, 'found the wrong block');
  assert.ok(!/Less than 100 SAR|100 – 500 SAR|1,000\+ SAR/.test(body),
    'the budget labels name SAR outright again — they must follow the shop currency');
  assert.match(body, /\$\{currency \? ' ' \+ currency : ''\}/,
    'the labels no longer interpolate the shop currency');

  // The option VALUES are stored on intake records; rewriting them would orphan
  // every request already taken. They must stay exactly as they were.
  for (const v of ['value="&lt;100"', 'value="100-500"', 'value="500-1000"', 'value="1000+"']) {
    assert.ok(body.includes(v), `the stored option value ${v} changed — that orphans existing intake records`);
  }

  // And the caller has to actually supply it. Mutation testing found this gap:
  // dropping the argument leaves `currency` undefined, so every shop silently
  // gets bare numbers — not wrong, but the shop's own unit is gone and nothing
  // says so. The template check above passes either way.
  const call = src.match(/renderIntakeFormPage\(shopName[^)]*\)/);
  assert.ok(call, 'renderIntakeFormPage is never called — check this still applies');
  assert.match(call[0], /currency/,
    `the intake form is rendered without the shop currency: ${call[0]}`);
});

test('no customer-facing page in lib/ names a currency it was not given', () => {
  // The guard for the class rather than the two instances. Any literal currency
  // in a page template is wrong for some shop; the shop's own setting is the only
  // right answer, and no unit beats a wrong one.
  const files = fs.readdirSync(path.join(__dirname, '..', 'lib'))
    .filter((f) => f.startsWith('lan-') && f.endsWith('.js'));
  assert.ok(files.length >= 2, `only found ${files.length} lan-* modules — the walk broke`);

  const offenders = [];
  for (const f of files) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'lib', f), 'utf8');
    src.split('\n').forEach((line, i) => {
      if (line.trim().startsWith('//') || line.trim().startsWith('*')) return;
      // A currency code sitting next to a number, inside markup.
      if (/<[^>]*>[^<]*\b\d[\d,.]*\s*(SAR|USD|EUR|GBP|AED)\b/.test(line)
          || /\b\d[\d,.]*\s+(SAR|USD|EUR|GBP|AED)\b(?![^<]*\$\{)/.test(line)) {
        offenders.push(`${f}:${i + 1}`);
      }
    });
  }
  assert.deepEqual(offenders, [],
    'a currency is written into a page template — pass the shop currency in instead');
});
