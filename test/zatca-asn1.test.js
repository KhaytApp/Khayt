const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const {
  asn1Len,
  asn1TL,
  asn1Seq,
  asn1OID,
  asn1Utf8,
  buildZatcaCsrDer,
} = require('../lib/zatca-asn1');

test('asn1Len encodes short and long lengths', () => {
  assert.deepEqual([...asn1Len(0)], [0]);
  assert.deepEqual([...asn1Len(127)], [127]);
  assert.deepEqual([...asn1Len(128)], [0x81, 128]);
  assert.deepEqual([...asn1Len(300)], [0x82, 1, 44]);
});

test('asn1OID encodes common name OID 2.5.4.3', () => {
  const der = asn1OID('2.5.4.3');
  assert.equal(der[0], 0x06);
  assert.deepEqual([...der.slice(2)], [0x55, 0x04, 0x03]);
});

test('asn1TL wraps UTF8 string', () => {
  const inner = asn1Utf8('Khayt');
  assert.equal(inner[0], 0x0c);
  assert.equal(inner.toString('utf8', 2), 'Khayt');
});

test('asn1Seq produces SEQUENCE tag', () => {
  const seq = asn1Seq([asn1Utf8('x')]);
  assert.equal(seq[0], 0x30);
});

test('buildZatcaCsrDer returns signed CSR SEQUENCE', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const pubDer = publicKey.export({ type: 'spki', format: 'der' });
  const csr = buildZatcaCsrDer({
    privateKey,
    pubDer,
    cn: 'Test Shop',
    org: 'Test Org',
    vat: '300000000000003',
  });
  assert.ok(Buffer.isBuffer(csr));
  assert.equal(csr[0], 0x30);
  assert.ok(csr.length > 200);
});
