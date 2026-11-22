const crypto = require('crypto');

function asn1Len(n) {
  if (n < 0x80) return Buffer.from([n]);
  if (n < 0x100) return Buffer.from([0x81, n]);
  return Buffer.from([0x82, (n >> 8) & 0xff, n & 0xff]);
}

function asn1TL(tag, content) {
  return Buffer.concat([Buffer.from([tag]), asn1Len(content.length), content]);
}

const asn1Seq = (items) => asn1TL(0x30, Array.isArray(items) ? Buffer.concat(items) : items);
const asn1Set = (items) => asn1TL(0x31, Array.isArray(items) ? Buffer.concat(items) : items);
const asn1OStr = (b) => asn1TL(0x04, b);
const asn1BitStr = (b) => asn1TL(0x03, Buffer.concat([Buffer.from([0x00]), b]));
const asn1Int = (n) => asn1TL(0x02, Buffer.from([n]));
const asn1Utf8 = (s) => asn1TL(0x0c, Buffer.from(s, 'utf8'));
const asn1Print = (s) => asn1TL(0x13, Buffer.from(s, 'ascii'));
const asn1CtxX = (n, b) => asn1TL(0xa0 | n, b);

function asn1OID(oidStr) {
  const p = oidStr.split('.').map(Number);
  const bytes = [40 * p[0] + p[1]];
  for (let i = 2; i < p.length; i++) {
    let n = p[i];
    if (n < 0x80) {
      bytes.push(n);
      continue;
    }
    const chunk = [];
    while (n > 0) {
      chunk.unshift(n & 0x7f);
      n >>>= 7;
    }
    for (let j = 0; j < chunk.length - 1; j++) chunk[j] |= 0x80;
    bytes.push(...chunk);
  }
  return asn1TL(0x06, Buffer.from(bytes));
}

function buildZatcaCsrDer({
  privateKey,
  pubDer,
  cn,
  org,
  vat,
  invoiceType = '1100',
  location = 'Riyadh',
  industry = '3D Printing',
}) {
  const rdn = (oidStr, val, strTag = 0x0c) =>
    asn1Set([asn1Seq([asn1OID(oidStr), asn1TL(strTag, Buffer.from(val, 'utf8'))])]);

  const subject = asn1Seq([
    rdn('2.5.4.6', 'SA', 0x13),
    rdn('2.5.4.10', org),
    rdn('2.5.4.11', vat),
    rdn('2.5.4.3', cn),
  ]);

  const otherName = (typeOid, val) =>
    asn1CtxX(0, Buffer.concat([asn1OID(typeOid), asn1CtxX(0, asn1Utf8(val))]));

  const sanContent = asn1Seq([
    otherName('2.16.682.1.35.1.1.2', invoiceType),
    otherName('2.16.682.1.35.1.1.3', location),
    otherName('2.16.682.1.35.1.1.4', industry),
  ]);

  const extensions = asn1Seq([asn1Seq([asn1OID('2.5.29.17'), asn1OStr(sanContent)])]);

  const extReqAttr = asn1Seq([asn1OID('1.2.840.113549.1.9.14'), asn1Set([extensions])]);

  const crInfo = asn1Seq([
    asn1Int(0),
    subject,
    Buffer.from(pubDer),
    asn1CtxX(0, extReqAttr),
  ]);

  const signer = crypto.createSign('SHA256');
  signer.update(crInfo);
  const sig = signer.sign(privateKey);

  const sigAlg = asn1Seq([asn1OID('1.2.840.10045.4.3.2')]);
  return asn1Seq([crInfo, sigAlg, asn1BitStr(sig)]);
}

module.exports = {
  asn1Len,
  asn1TL,
  asn1Seq,
  asn1Set,
  asn1OStr,
  asn1BitStr,
  asn1Int,
  asn1Utf8,
  asn1Print,
  asn1CtxX,
  asn1OID,
  buildZatcaCsrDer,
};
