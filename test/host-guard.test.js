const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  isBlockedHost,
  isAllowedPrinterHost,
  isBlockedLoopbackOrMetadata,
  resolvesToBlockedHost,
  sanitizeMailgunDomain,
} = require('../lib/host-guard');

test('blocks empty and localhost names', () => {
  assert.equal(isBlockedHost(''), true);
  assert.equal(isBlockedHost('localhost'), true);
  assert.equal(isBlockedHost('LOCALHOST'), true);
});

test('blocks private and loopback IPv4', () => {
  assert.equal(isBlockedHost('127.0.0.1'), true);
  assert.equal(isBlockedHost('10.0.0.1'), true);
  assert.equal(isBlockedHost('192.168.0.1'), true);
  assert.equal(isBlockedHost('169.254.169.254'), true);
});

test('allows public hostnames and IPs', () => {
  assert.equal(isBlockedHost('api.telegram.org'), false);
  assert.equal(isBlockedHost('8.8.8.8'), false);
});

test('blocks common IPv6 loopback and ULA prefixes', () => {
  assert.equal(isBlockedHost('::1'), true);
  assert.equal(isBlockedHost('fe80::1'), true);
  assert.equal(isBlockedHost('fc00::1'), true);
});

test('isAllowedPrinterHost allows LAN printer addresses', () => {
  assert.equal(isAllowedPrinterHost('192.168.1.50'), true);
  assert.equal(isAllowedPrinterHost('10.0.0.42'), true);
  assert.equal(isAllowedPrinterHost('172.16.0.8'), true);
  assert.equal(isAllowedPrinterHost('octopi.local'), true);
  assert.equal(isAllowedPrinterHost('169.254.1.1'), true);
});

test('isBlockedLoopbackOrMetadata blocks loopback but allows LAN SMTP relays', () => {
  assert.equal(isBlockedLoopbackOrMetadata('127.0.0.1'), true);
  assert.equal(isBlockedLoopbackOrMetadata('169.254.169.254'), true);
  assert.equal(isBlockedLoopbackOrMetadata('192.168.1.10'), false);
  assert.equal(isBlockedLoopbackOrMetadata('mail.example.com'), false);
});

test('sanitizeMailgunDomain accepts valid hostnames only', () => {
  assert.equal(sanitizeMailgunDomain('mg.example.com'), 'mg.example.com');
  assert.equal(sanitizeMailgunDomain('MG.Example.COM'), 'mg.example.com');
  assert.equal(sanitizeMailgunDomain('evil.com/path'), null);
  assert.equal(sanitizeMailgunDomain('user@evil.com'), null);
  assert.equal(sanitizeMailgunDomain(''), null);
});

test('isAllowedPrinterHost blocks loopback and metadata', () => {
  assert.equal(isAllowedPrinterHost(''), false);
  assert.equal(isAllowedPrinterHost('localhost'), false);
  assert.equal(isAllowedPrinterHost('127.0.0.1'), false);
  assert.equal(isAllowedPrinterHost('169.254.169.254'), false);
  assert.equal(isAllowedPrinterHost('0.0.0.0'), false);
});

/* ── SSRF: the shape callers actually pass ──────────────────────────────── */

test('IPv6 loopback and private ranges are blocked in BRACKETED form', async () => {
  // This is the shape every production caller supplies: new URL(u).hostname returns an
  // IPv6 literal wrapped in brackets. The guard tested bare literals ("^::1$", "^fc",
  // "^fd", "^::ffff:"), so NONE of them ever matched a real caller — http://[::1]:PORT/
  // reached any loopback service while 127.0.0.1 was correctly refused. The pre-existing
  // tests passed the bare form, the only shape that worked.
  const cases = [
    'http://[::1]:8080/x',
    'http://[0:0:0:0:0:0:0:1]/x',      // long form — URL normalises it to [::1]
    'http://[::ffff:127.0.0.1]/x',     // IPv4-mapped
    'http://[fd00::1]/x',              // unique-local
    'http://[FD00::1]/x',              // uppercase must not evade
    'http://[fe80::1]/x',              // link-local
    'http://[::]/x',
  ];
  for (const u of cases) {
    const host = new URL(u).hostname;
    assert.equal(isBlockedHost(host), true, `SSRF NOT BLOCKED: ${u} (hostname ${host})`);
    assert.equal(await resolvesToBlockedHost(host), true, `DNS layer let it through: ${u}`);
  }
});

test('the bracketed form does not over-block legitimate destinations', async () => {
  for (const u of ['https://api.example.com/hook', 'http://192.0.2.5/x', 'https://[2606:4700::1111]/x']) {
    const host = new URL(u).hostname;
    if (host === '192.0.2.5' || host.startsWith('[2606')) {
      assert.equal(isBlockedHost(host), false, `wrongly blocked a public address: ${u}`);
    }
  }
});

test('outbound SMTP guard also handles the bracketed form', () => {
  assert.equal(isBlockedLoopbackOrMetadata(new URL('http://[::1]/x').hostname), true);
  assert.equal(isBlockedLoopbackOrMetadata(new URL('http://[::ffff:169.254.169.254]/x').hostname), true);
});

/* ── numeric IPv4 spellings ────────────────────────────────────────────────── */

/**
 * `connect()` goes through inet_aton, which accepts far more than four decimal
 * octets. All of these reach 127.0.0.1:
 *
 *     2130706433      0x7f000001      127.1      0177.0.0.1
 *
 * and none matches a `\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}` test. They fell past
 * the dotted-quad branch and landed on the permissive "bare hostname" return, so
 * isAllowedPrinterHost blocked `127.0.0.1` and allowed three other spellings of
 * it. Confirmed by opening a listener on 127.0.0.1 and connecting to each.
 *
 * The webhook path was never exposed — resolvesToBlockedHost() resolves the name
 * and caught all of them — but the printer path and the SMTP path have only the
 * syntactic check, so the syntactic check has to be right on its own.
 */

const LOOPBACK_SPELLINGS = ['2130706433', '0x7f000001', '127.1', '0177.0.0.1', '127.0.1'];

test('the printer guard refuses every spelling of loopback, not just the dotted one', () => {
  assert.equal(isAllowedPrinterHost('127.0.0.1'), false, 'the spelling that always worked');
  for (const h of LOOPBACK_SPELLINGS) {
    assert.equal(isAllowedPrinterHost(h), false, `${h} is 127.0.0.1 and must be refused`);
  }
});

test('outbound guards refuse them too, without a DNS lookup', () => {
  // isBlockedLoopbackOrMetadata guards outbound SMTP and has no resolving layer
  // behind it, so a syntactic miss there is the whole defence missing.
  for (const h of LOOPBACK_SPELLINGS) {
    assert.equal(isBlockedHost(h), true, `isBlockedHost(${h})`);
    assert.equal(isBlockedLoopbackOrMetadata(h), true, `isBlockedLoopbackOrMetadata(${h})`);
  }
});

test('a decimal spelling of a PRIVATE address is judged as that address', () => {
  // 167772161 is 10.0.0.1 — blocked outbound as RFC1918, allowed as a printer.
  assert.equal(isBlockedHost('167772161'), true);
  assert.equal(isAllowedPrinterHost('167772161'), true, 'a LAN printer may legitimately be 10.0.0.1');
});

/*
 * 100.64.0.0/10 — RFC 6598 carrier-grade NAT, and the whole of Tailscale.
 *
 * A PRIVATE NETWORK THAT IS NOT RFC 1918, and this list did not have it. A
 * shop that runs Tailscale to reach its printers from home has its machines,
 * its NAS and everything else on that tailnet addressed in 100.64–100.127,
 * and a webhook or cloud address pointed at any of it was sent. 10/8,
 * 172.16/12 and 192.168/16 were all blocked; this was the one private range
 * that was not.
 *
 * `100.100.100.100` is Tailscale's own MagicDNS resolver — the single most
 * likely thing on a tailnet to answer an HTTP request.
 */
test('the carrier-grade NAT range is private, and is blocked', () => {
  for (const h of ['100.64.0.0', '100.64.0.1', '100.100.100.100', '100.127.255.255']) {
    assert.equal(isBlockedHost(h), true, `${h} is inside 100.64.0.0/10 and was sent`);
  }
  // AND THE PRINTER GUARD IS A SEPARATE ANSWER, deliberately left as it was.
  //
  // `isAllowedPrinterHost` is an ALLOW list — RFC1918, link-local, .local —
  // and 100.64/10 is not on it, so a shop that reaches its printers over
  // Tailscale cannot add one. That is a gap, but it is a gap about what Khayt
  // supports, not about what it may send, and widening an allow list is not a
  // change to make inside a fix that narrows a block list. Pinned here so the
  // behaviour is stated rather than assumed either way.
  assert.equal(isAllowedPrinterHost('100.64.0.1'), false,
    'if this is changed, it is a decision about supporting tailnet printers');
});

/*
 * The range is a /10, so the second octet runs 64–127. The rest of 100/8 is
 * ordinary public address space: 100.0.0.0/10, 100.128.0.0/9 and so on are
 * routable, and blocking all of 100/8 would quietly break a shop whose cloud
 * or webhook host happens to live there.
 */
test('the rest of 100/8 is public and stays reachable', () => {
  for (const h of ['100.0.0.1', '100.5.5.5', '100.63.255.255', '100.128.0.0', '100.255.255.255']) {
    assert.equal(isBlockedHost(h), false, `${h} is public space and was refused`);
  }
});

test('real printers and real hostnames are unaffected', () => {
  for (const h of ['10.0.0.5', '192.168.1.50', '172.16.0.1', '169.254.1.5', 'octopi.local', 'printer-1']) {
    assert.equal(isAllowedPrinterHost(h), true, h);
  }
  assert.equal(isAllowedPrinterHost('169.254.169.254'), false, 'the metadata endpoint stays blocked');
  for (const h of ['example.com', '8.8.8.8', 'mail.corp.local']) {
    assert.equal(isBlockedHost(h), false, h);
  }
});

test('things that merely look numeric are still treated as hostnames', () => {
  // A hostname made only of hex-ish characters must not be mangled into an IP.
  assert.equal(isBlockedHost('deadbeef.example.com'), false);
  assert.equal(isAllowedPrinterHost('abc'), true, 'a bare hostname is still a hostname');
  assert.equal(isBlockedHost('1.2.3.4.5'), false, 'five parts is not an IPv4 address');
});

/* ------------------------------------------------------------------
 * The printer guard is one rule, in one place.
 *
 * The syntactic half lives in lib/printer-host.js so the Mac app — which polls
 * the same machines and has no `dns` — shares it. A second, more forgiving copy
 * in Swift is how two apps come to disagree about what they are willing to
 * connect to, and the disagreement would be invisible until somebody pointed
 * one of them at an address that was not a printer.
 * ------------------------------------------------------------------ */

test('the split kept every caller working', () => {
  const guard = require('../lib/host-guard.js');
  const pure = require('../lib/printer-host.js');
  assert.equal(guard.isAllowedPrinterHost, pure.isAllowedPrinterHost,
    'host-guard no longer re-exports the shared guard');
  assert.equal(guard.sanitizePrinterHost, pure.sanitizePrinterHost);
  assert.equal(guard.canonicalizeIpv4, pure.canonicalizeIpv4);
});

test('the shared half needs nothing Node-only', () => {
  // It runs in JavaScriptCore, which has no require, no fs, no dns.
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'printer-host.js'), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
  for (const forbidden of ["require('dns')", "require('fs')", "require('net')", 'process.']) {
    assert.ok(!src.includes(forbidden), `printer-host.js now uses ${forbidden}`);
  }
});

test('nobody strips a printer host by hand any more', () => {
  // Four call sites in main.js each wrote the same character class out. One of
  // them getting a character wrong is a URL that points somewhere else.
  const fs = require('fs');
  const path = require('path');
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.doesNotMatch(main, /replace\(\/\[\^a-zA-Z0-9\.\\-\]\/g, ''\)/,
    'a hand-written printer-host strip is back in main.js — use sanitizePrinterHost');
});
