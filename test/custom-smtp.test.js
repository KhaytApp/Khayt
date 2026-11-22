const { test } = require('node:test');
const assert = require('node:assert/strict');
const { sanitizeHeader, dotStuff } = require('../lib/custom-smtp.js');

test('sanitizeHeader strips CR/LF and control chars to block header/command injection', () => {
  // CRLF injection attempt collapses to a single inert header line.
  assert.equal(
    sanitizeHeader('a@b.com\r\nBcc: evil@x.com'),
    'a@b.com Bcc: evil@x.com',
  );
  assert.equal(sanitizeHeader('Subj\r\nRCPT TO:<x>'), 'Subj RCPT TO:<x>');
  assert.equal(sanitizeHeader('tab\there'), 'tab here');
  // Legitimate punctuation (dash, dot, plus, spaces) must be preserved.
  assert.equal(sanitizeHeader('Order a-b.c+1 #42'), 'Order a-b.c+1 #42');
  assert.equal(sanitizeHeader(null), '');
});

test('dotStuff escapes leading dots and normalizes line endings (RFC 5321)', () => {
  assert.equal(dotStuff('.hidden'), '..hidden');
  assert.equal(dotStuff('a\r\n.b\r\n.'), 'a\r\n..b\r\n..');
  // A lone "." line can no longer terminate DATA early.
  assert.equal(dotStuff('body\n.\nmore'), 'body\r\n..\r\nmore');
  assert.equal(dotStuff('no dots here'), 'no dots here');
});
