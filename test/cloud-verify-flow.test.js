const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SRC = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'settings.js'), 'utf8');

/**
 * Sign-up sends a verification code by email. The app has to ask for it.
 *
 * It used to end with a success toast and a warning banner in the cloud settings
 * panel — a panel the shop had just finished with, behind the recovery-key modal
 * it was reading. The code arrived and there was visibly nowhere to type it,
 * which is how it was reported: "I got an email with a code but nowhere to enter
 * it."
 *
 * The banner is not the fix and is not removed: somebody who closes the dialog,
 * or whose email takes a few minutes, still needs a way back. The fix is asking
 * at the moment the email is sent.
 */

/** The body of the sign-up click handler. */
function signupHandler() {
  const i = SRC.indexOf("el.querySelector('#btnCloudSignup')");
  assert.ok(i > 0, 'the sign-up handler moved — this guard has rotted');
  const end = SRC.indexOf("el.querySelector('#btnCloudLogin')", i);
  assert.ok(end > i);
  return SRC.slice(i, end);
}

test('sign-up asks for the verification code, not only the banner', () => {
  assert.match(signupHandler(), /showVerifyEmailModal\(/,
    'sign-up sends a code and never opens the box to type it into');
});

test('the code is asked for AFTER the recovery key is acknowledged', () => {
  // The recovery key is shown once and losing it loses the data, so it has to be
  // dealt with first — and one modal cannot open over another.
  const h = signupHandler();
  const recovery = h.indexOf('showRecoveryKeyModal(');
  const verify = h.indexOf('showVerifyEmailModal(');
  assert.ok(recovery > 0 && verify > recovery,
    'the verify modal must be sequenced after the recovery key, not opened alongside it');
  assert.match(h, /showRecoveryKeyModal\(ks\.recoveryKey,\s*\(\)\s*=>/,
    'sequenced through the recovery modal’s completion, not fired at the same time');
});

test('no code is asked for when the server could not send one', () => {
  // A box waiting for a code that was never sent is a worse lie than the warning
  // toast beside it. TWO reasons none is coming, and both have to be checked:
  //
  //   emailFailed          the server tried and the provider refused
  //   emailConfigured:false  this server has no mail set up at all
  //
  // Only the first was checked, because lib/cloud-client.js's signup() dropped
  // the second from the response — so a self-hosted server with no SMTP sailed
  // straight into the dialog. The reset flow has always distinguished them.
  const h = signupHandler();
  assert.match(h, /su\.emailConfigured !== false && !su\.emailFailed/,
    'sign-up must check BOTH email facts before asking for a code');
  // And the shop must be told which of the two it was, not left guessing.
  assert.match(SRC, /su\.emailConfigured === false/,
    'the no-mail-server case needs its own message, not the "provider refused" one');
});

test('the banner and its button stay, as the way back', () => {
  assert.match(SRC, /const showUnverified = connected && c\.email && c\.verified === false;/);
  assert.match(SRC, /id="btnCloudVerify"/);
  assert.match(SRC, /el\.querySelector\('#btnCloudVerify'\)/);
});
