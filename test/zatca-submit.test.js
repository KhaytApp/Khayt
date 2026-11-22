const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  xmlToBase64,
  zatcaPhase2Ready,
  nextZatcaIcv,
  orderEligibleForZatcaSubmit,
  zatcaSubmitAccepted,
  appendZatcaSubmissionLog,
} = require('../lib/zatca-submit');

test('xmlToBase64 encodes UTF-8 XML', () => {
  const b64 = xmlToBase64('<?xml version="1.0"?><Invoice/>');
  assert.equal(Buffer.from(b64, 'base64').toString('utf8'), '<?xml version="1.0"?><Invoice/>');
});

test('zatcaPhase2Ready requires enable flag and CSID', () => {
  assert.equal(zatcaPhase2Ready({ enableZatca: true, zatcaPhase2: { enabled: true, csid: 'x' } }), true);
  assert.equal(zatcaPhase2Ready({ enableZatca: false, zatcaPhase2: { enabled: true, csid: 'x' } }), false);
  assert.equal(zatcaPhase2Ready({ enableZatca: true, zatcaPhase2: { enabled: true } }), false);
});

test('nextZatcaIcv reuses pending ICV on retry', () => {
  const z2 = { invoiceCounter: 5 };
  const order = { zatcaSubmission: { icv: 6 } };
  assert.equal(nextZatcaIcv(z2, order), 6);
  assert.equal(nextZatcaIcv(z2, {}), 6);
});

test('orderEligibleForZatcaSubmit accepts completed orders only', () => {
  assert.equal(orderEligibleForZatcaSubmit({ status: 'completed' }), true);
  assert.equal(orderEligibleForZatcaSubmit({ status: 'printing' }), false);
  assert.equal(orderEligibleForZatcaSubmit({ status: 'completed', voidedAt: 'x' }), false);
});

test('zatcaSubmitAccepted interprets validation status', () => {
  assert.equal(zatcaSubmitAccepted(true, { validationResults: { status: 'PASS' } }), true);
  assert.equal(zatcaSubmitAccepted(true, { validationResults: { status: 'REJECTED' } }), false);
  assert.equal(zatcaSubmitAccepted(false, {}), false);
});

test('appendZatcaSubmissionLog keeps newest 100 entries', () => {
  const z2 = { submissions: [] };
  for (let i = 0; i < 105; i++) appendZatcaSubmissionLog(z2, { orderId: `o${i}` });
  assert.equal(z2.submissions.length, 100);
  assert.equal(z2.submissions[0].orderId, 'o104');
});

/**
 * THE COPY THAT SHIPS HAS TO BE THIS ONE.
 *
 * Everything above tests `lib/zatca-submit.js`, and for a long time nothing
 * loaded it: `renderer/invoicing.js` had its own `zatcaPhase2Ready`,
 * `nextZatcaIcv`, `appendZatcaSubmissionLog` and `zatcaSubmitAccepted`, and the
 * Electron window ran those. They agreed with these, checked line by line — but
 * that is a fact about one afternoon, and what these rules decide is not
 * cosmetic. `nextZatcaIcv` numbers an invoice in a sequence ZATCA requires to
 * be unbroken; `zatcaSubmitAccepted` decides whether a document already handed
 * to a customer counts as reported.
 *
 * Same failure as the slicer allowlist and `lib/app-security.js`: the tested
 * half and the running half were different halves.
 */
test('the window uses this module rather than its own copy of these rules', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const renderer = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'invoicing.js'), 'utf8');
  const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');

  // Loaded, and before the file that reaches for it — a script tag added after
  // its caller is a global that is undefined exactly when it is wanted.
  const moduleAt = html.indexOf('lib/zatca-submit.js');
  const callerAt = html.indexOf('"invoicing.js"');
  assert.ok(moduleAt > 0, 'index.html does not load lib/zatca-submit.js');
  assert.ok(callerAt > moduleAt, 'invoicing.js is loaded before the module it reaches for');

  // No second opinion left behind. Each of these is a `function name(` that
  // used to stand here with its own body; it must now be a wrapper that asks
  // the module. Checked by locating the definition and reading the few lines
  // that follow, rather than by a regex over a 1,500-line file — a failure
  // message there is the whole file.
  for (const name of ['zatcaPhase2Ready', 'nextZatcaIcv', 'appendZatcaSubmissionLog',
                      'zatcaSubmitAccepted']) {
    const at = renderer.indexOf(`function ${name}(`);
    assert.ok(at > 0, `renderer/invoicing.js no longer defines ${name}`);
    const body = renderer.slice(at, renderer.indexOf('\n}', at));
    assert.ok(body.includes('ZatcaSubmit()'),
      `renderer/invoicing.js still answers ${name} itself instead of asking the module`);
  }
});

/**
 * The XML that is base64'd here is the XML that gets hashed, signed and
 * reported. If the window and the main process encode it differently, one of
 * them submits a document whose hash does not match what was signed — and the
 * failure arrives from ZATCA, about an invoice a customer already has.
 */
test('the window and the main process encode the invoice identically', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const vm = require('node:vm');

  // A context with no Buffer, which is the whole point.
  const sandbox = {
    TextEncoder,
    btoa: (binary) => Buffer.from(binary, 'binary').toString('base64'),
    console,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(
    fs.readFileSync(path.join(__dirname, '..', 'lib', 'zatca-submit.js'), 'utf8'),
    sandbox,
  );
  const web = sandbox.KhaytZatcaSubmit;
  assert.ok(web, 'the module did not publish its api to a browser-shaped global');
  assert.equal(typeof Buffer, 'function', 'this half of the test needs Node');

  for (const xml of [
    '<Invoice/>',
    '<Invoice><Name>Athar Tuwaiq</Name></Invoice>',
    // Arabic, because a Saudi invoice is bilingual and UTF-8 is where a
    // hand-rolled base64 goes wrong.
    '<Invoice><Name>أثر طويق</Name><City>الرياض</City></Invoice>',
    '<Invoice><Note>مرحبا — 100% ✓</Note></Invoice>',
    '', null, undefined,
  ]) {
    assert.equal(web.xmlToBase64(xml), xmlToBase64(xml),
      `the two hosts disagree on ${JSON.stringify(xml)}`);
  }
});
