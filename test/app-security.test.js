const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  generateRecoveryCode,
  normalizeRecoveryCode,
  formatRecoveryCode,
  isValidRecoveryCode,
  verifyRecoveryCode,
  hashSecret,
  isValidPin,
  isWeakPin,
  buildRecoveryCodeFile,
} = require('../lib/app-security');

test('generateRecoveryCode matches KHAYT format', () => {
  const code = generateRecoveryCode();
  assert.match(code, /^KHAYT-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/);
  assert.equal(isValidRecoveryCode(code), true);
});

test('normalizeRecoveryCode strips separators', () => {
  assert.equal(normalizeRecoveryCode('KHAYT-ABCD-EFGH-JKLM'), 'ABCDEFGHJKLM');
});

test('verifyRecoveryCode checks hash', () => {
  const code = 'KHAYT-ABCD-EFGH-JKLM';
  const hash = hashSecret(normalizeRecoveryCode(code));
  assert.equal(verifyRecoveryCode(code, hash), true);
  assert.equal(verifyRecoveryCode('KHAYT-XXXX-YYYY-ZZZZ', hash), false);
});

test('isValidPin and isWeakPin', () => {
  assert.equal(isValidPin('1234'), true);
  assert.equal(isValidPin('123'), false);
  assert.equal(isWeakPin('1234'), true);
  assert.equal(isWeakPin('58291'), false);
});

test('buildRecoveryCodeFile includes code', () => {
  const text = buildRecoveryCodeFile({ code: 'KHAYT-ABCD-EFGH-JKLM', businessName: 'Test Shop' });
  assert.match(text, /KHAYT-ABCD-EFGH-JKLM/);
  assert.match(text, /Test Shop/);
});

test('formatRecoveryCode normalizes input', () => {
  assert.equal(formatRecoveryCode('khaytabcd efgh jklm'), 'KHAYT-ABCD-EFGH-JKLM');
});
