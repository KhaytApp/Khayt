const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { appcast, NOTES_MAX, XML_ILLEGAL } = require('../scripts/mac-appcast.js');
const { extract, verify, publicKeyFromMakeApp } = require('../scripts/mac-appcast-verify.js');

/* ────────────────────────────────────────────────────────────────────────────
 * The Mac's update feed is signed when it is published, and (one release
 * later) the app refuses any feed that is not: mac-custom-updater-plan.md,
 * decision 4. A feed that does not verify then means no Mac updates, so the
 * check the publish lane makes is held here.
 *
 * EVERY KEY IN THIS FILE IS MADE IN THIS FILE. The real one is a CI secret and
 * a Keychain item, used only by `sign_update` inside the publish workflows.
 * `sign` below does what the `sign_update` executable does to a feed (2.9.6,
 * sign_update/main.swift): it first takes off anything from the last signature
 * marker on (SPUExtractAppcastContent), then appends the block `signAppcast`
 * writes. It exists only to give `verify` something to check.
 * ──────────────────────────────────────────────────────────────────────────── */

function keys() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  // The raw 32 bytes, base64: the form SUPublicEDKey takes.
  return { privateKey, publicKey: publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64') };
}
function sign(file, privateKey, { length, raw = false } = {}) {
  // `raw`: sign these bytes as they are (to build blocks sign_update never would).
  const content = raw ? file : extract(file).content;
  if (length == null) length = content.length;
  const sig = crypto.sign(null, content, privateKey).toString('base64');
  return Buffer.concat([content, Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${sig}\nlength: ${length}\n-->\n`)]);
}
const feed = (extra = {}) => Buffer.from(appcast({
  version: '4.0.0-beta.44', build: 44, archiveBytes: 100, signature: 'sig==',
  url: 'https://example.com/Khayt-4.0.0-beta.44.zip', pubDate: new Date(0), ...extra,
}));

test('a feed signed with the key verifies, and what is signed is every byte before the block', () => {
  const k = keys();
  const content = feed({ notes: '## Before you update\n- Update every computer first.' });
  const signed = sign(content, k.privateKey);
  assert.deepEqual(verify(signed, k.publicKey), { ok: true });
  const x = extract(signed);
  assert.ok(x.content.equals(content));
  assert.equal(x.length, content.length);
});

test('an unsigned feed, an edited one, one signed with another key, and a wrong length are all refused', () => {
  const k = keys(), other = keys();
  const content = feed();
  const signed = sign(content, k.privateKey);
  // What a hand-edited block could hold and a Mac would refuse: stray characters in the signature.
  assert.match(verify(Buffer.from(signed.toString('utf8').replace(/edSignature: (.{10})/, 'edSignature: $1 \u00a0!')), k.publicKey).reason, /not an Ed25519 signature/);
  assert.match(verify(content, k.publicKey).reason, /not signed/);
  assert.match(verify(signed, other.publicKey).reason, /does not match/);
  // One byte changed anywhere in what was signed: the version, the URL, the length.
  for (const [from, to] of [['<sparkle:version>44<', '<sparkle:version>45<'], ['example.com', 'examp1e.com'], ['length="100"', 'length="101"']]) {
    const edited = Buffer.from(signed.toString('utf8').replace(from, to));
    assert.notEqual(edited.toString(), signed.toString(), from);
    assert.equal(verify(edited, k.publicKey).ok, false, from);
  }
  // A formatter's trailing space, and a byte-order mark put in front.
  assert.equal(verify(Buffer.from(signed.toString('utf8').replace('</rss>\n', '</rss> \n')), k.publicKey).ok, false);
  assert.equal(verify(Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), signed]), k.publicKey).ok, false);
  // The block says another length than the content has. Sparkle only words its error with it; this is stricter.
  assert.match(verify(sign(content, k.privateKey, { length: content.length + 1 }), k.publicKey).reason, /bytes were signed/);
  // Keys and signatures that are not what they should be.
  assert.match(verify(signed, 'AAAA').reason, /32-byte/);
  assert.match(verify(signed, '').reason, /32-byte/);
  assert.match(verify(Buffer.from(signed.toString('utf8').replace(/edSignature: .*/, 'edSignature: AAAA')), k.publicKey).reason, /not an Ed25519 signature/);
  assert.match(verify(Buffer.alloc(0), k.publicKey).reason, /empty/);
});

test('it reads the block as Sparkle does: the LAST one, and a signature over something else proves nothing', () => {
  const k = keys(), attacker = keys();
  // Notes that quote the marker: sign_update takes the LAST marker in the file as the start of an old
  // block and signs only what is before it. So the marker must never be in the file's bytes.
  const quoting = 'How feeds are signed:\n<!-- sparkle-signatures:\nedSignature: AAAA\nlength: 1\n-->\ndone';
  const content = feed({ notes: quoting });
  assert.ok(!content.includes('<!-- sparkle-signatures:'), 'the marker is in the feed: sign_update would cut it there');
  assert.ok(extract(content).content.equals(content), 'the unsigned feed already reads as signed');
  const signedQuoting = sign(content, k.privateKey);
  assert.deepEqual(verify(signedQuoting, k.publicKey), { ok: true });
  assert.ok(extract(signedQuoting).content.equals(content), 'what was signed is not the whole feed');
  // And a parser joins the split sections back into the text that was written.
  const joined = [...content.toString('utf8').matchAll(/<!\[CDATA\[([\s\S]*?)\]\]>/g)].map((m) => m[1]).join('');
  assert.equal(joined, quoting);
  // Were the marker left in, the lane would stop: what gets signed has no enclosure.
  const leaked = Buffer.from(content.toString('utf8').replace('<!-]]><![CDATA[- sparkle-signatures:', '<!-- sparkle-signatures:'));
  assert.match(verify(sign(leaked, k.privateKey), k.publicKey).reason, /not an update feed/);
  // A second block appended by somebody else replaces nothing: it must itself verify with OUR key.
  const signed = sign(feed(), k.privateKey);
  assert.equal(verify(sign(signed, attacker.privateKey, { raw: true }), k.publicKey).ok, false);
  // A block that is not UTF-8 is no block, as in Sparkle.
  assert.match(verify(Buffer.concat([feed(), Buffer.from('<!-- sparkle-signatures:\nedSignature: '), Buffer.from([0xff, 0xfe]), Buffer.from('\n-->\n')]), k.publicKey).reason, /not signed/);
  // A block with no end is no block.
  assert.match(verify(Buffer.concat([feed(), Buffer.from('<!-- sparkle-signatures:\nedSignature: AAAA\n')]), k.publicKey).reason, /not signed/);
  // Correctly signed bytes that are not a feed.
  assert.match(verify(sign(Buffer.from('hello'), k.privateKey), k.publicKey).reason, /not an update feed/);
});

test('a character XML does not allow never reaches the feed, and a feed that holds one is refused though it is correctly signed', () => {
  const k = keys();
  // ESC from pasted terminal colours, a form feed, a NUL, U+FFFE: gone. Tab and newline stay.
  const xml = appcast({ version: '1.0.0', build: 1, archiveBytes: 1, signature: 's', url: 'https://example.com/a.zip',
    notes: 'fixed \u001b[31mred\u001b[0m\u000c text\u0000\ufffe\n\tkept' });
  assert.ok(!XML_ILLEGAL.test(xml)); XML_ILLEGAL.lastIndex = 0;
  assert.ok(xml.includes('fixed [31mred[0m text\n\tkept'));
  // Signing never reads the file as XML, so a signature says nothing about this. The check does.
  const poisoned = Buffer.from(feed().toString('utf8').replace('<language>en</language>', '<language>e\u001bn</language>'));
  const r = verify(sign(poisoned, k.privateKey), k.publicKey);
  assert.equal(r.ok, false);
  assert.match(r.reason, /U\+001B/);
  // Cut off before the end of the document: also not a feed a Mac can read.
  const short = Buffer.from(feed().toString('utf8').replace('</rss>', ''));
  assert.match(verify(sign(short, k.privateKey), k.publicKey).reason, /not an update feed/);
});

test('the notes ride inside the feed, never behind a link Sparkle would have to verify', () => {
  const xml = appcast({
    version: '4.0.0-beta.44', build: 44, archiveBytes: 100, signature: 'sig==', url: 'https://example.com/a.zip',
    notes: '## Before you update\r\n- A ]]> B & <c>\n', notesUrl: 'https://github.com/KhaytApp/khayt-mac/releases/tag/v4.0.0-beta.44',
  });
  // With SURequireSignedFeed, notes fetched from releaseNotesLink need their own signature. A GitHub page has none.
  assert.ok(!xml.includes('sparkle:releaseNotesLink'));
  assert.match(xml, /<sparkle:fullReleaseNotesLink>https:\/\/github\.com\/KhaytApp\/khayt-mac\/releases\/tag\/v4\.0\.0-beta\.44<\/sparkle:fullReleaseNotesLink>/);
  // Markdown, in CDATA, with the one sequence that would end it early split; the rest is not escaped.
  assert.match(xml, /<description sparkle:format="markdown"><!\[CDATA\[## Before you update\n- A \]\]\]\]><!\[CDATA\[> B & <c>\]\]><\/description>/);
  // No notes: no element, and the feed is still a feed.
  const bare = appcast({ version: '1.0.0', build: 1, archiveBytes: 1, signature: 's', url: 'https://example.com/a.zip', notes: '  \n' });
  assert.ok(!bare.includes('<description sparkle:format') && bare.includes('<enclosure '));
  // A promotion's whole section does not go into the update window.
  const long = appcast({ version: '1.0.0', build: 1, archiveBytes: 1, signature: 's', url: 'https://example.com/a.zip',
    notes: Array.from({ length: 5000 }, (_, i) => `- change number ${i}`).join('\n'), notesUrl: 'https://example.com/notes' });
  const body = /<!\[CDATA\[([\s\S]*)\]\]><\/description>/.exec(long)[1];
  assert.ok(body.length < NOTES_MAX + 200 && body.includes('The rest is in the full release notes: https://example.com/notes'));
  // Cut at the end of a line, not through one.
  assert.match(body.split('\n\n…')[0].split('\n').pop(), /^- change number \d+$/);
  assert.ok(body.startsWith('- change number 0\n'));
  assert.throws(() => appcast({ version: '1.0.0', build: 1, archiveBytes: 1, signature: 's', url: 'https://example.com/a.zip', notesUrl: 'http://example.com' }), /notes URL must be https/);
});

test('the public key the check uses is the one the app is built with', () => {
  const key = publicKeyFromMakeApp(fs.readFileSync(path.join(__dirname, '..', 'mac', 'make-app.sh'), 'utf8'));
  assert.equal(Buffer.from(key, 'base64').length, 32);
  assert.equal(publicKeyFromMakeApp('no key here'), null);
});

test('both publish lanes sign the feed with the archive\'s key, check it twice, and never write it again', () => {
  const read = (f) => fs.readFileSync(path.join(__dirname, '..', '.github', 'workflows', f), 'utf8');
  for (const [name, tool] of [['mac-publish.yml', 'sparkle/bin/sign_update'], ['mac-release.yml', '"$SIGN"']]) {
    const wf = read(name);
    const signAt = wf.indexOf(`${tool} -f - --disable-signing-warning "$FEED"`);
    assert.ok(signAt > 0, `${name}: the feed is not signed`);
    // Written once, before it is signed. A second write after signing would publish an unsigned feed.
    const writes = [...wf.matchAll(/^\s*\$NODE scripts\/mac-appcast\.js \\$/gm)].map((m) => m.index);
    assert.ok(!/^\s*node scripts\/mac-appcast\.js/m.test(wf), `${name}: the feed is written outside the signing step`);
    assert.equal(writes.length, 1, `${name}: the feed is written more than once`);
    assert.ok(writes[0] < signAt, `${name}: the feed is written after it is signed`);
    // Sparkle's own verify, then ours with the public key, both after signing; and again on the copy that is committed.
    assert.ok(wf.indexOf(`${tool} -f - --verify "$FEED"`) > signAt, name);
    const ours = wf.indexOf('$NODE scripts/mac-appcast-verify.js --feed "$FEED"');
    assert.ok(ours > signAt, name);
    // Against the key INSIDE the app that is about to ship, and as XML a Mac can parse.
    assert.match(wf.slice(ours, ours + 200), /--public-key "\$\(plutil -extract SUPublicEDKey raw "[^"]*Khayt\.app\/Contents\/Info\.plist"\)"/, name);
    assert.ok(wf.indexOf('xmllint --noout "$FEED"') > signAt, name);
    assert.ok(wf.indexOf('node scripts/mac-appcast-verify.js --feed site/mac/appcast.xml') > wf.indexOf('cp "$RUNNER_TEMP/appcast.xml" site/mac/appcast.xml'), name);
    // The feed is checked before the release is public: a feed that fails must not leave a release no Mac is told about.
    const publicAt = Math.max(wf.indexOf('--draft=false'), wf.indexOf('gh release create "$TAG"'));
    if (name === 'mac-publish.yml') assert.ok(signAt < publicAt, `${name}: the release is published before the feed is known good`);
    // The key reaches the tool on stdin only, and nothing prints it.
    assert.ok(!/sign_update[^\n]*\$SPARKLE_PRIVATE_KEY/.test(wf) && !/"\$SIGN"[^\n]*\$SPARKLE_PRIVATE_KEY/.test(wf), `${name}: the key is on a command line`);
    assert.ok(!/echo[^\n]*SPARKLE_PRIVATE_KEY"?\s*$/m.test(wf) && !/set -x/.test(wf), name);
    // Every use of the secret in a script is the one pipe into sign_update, or the test that it is set.
    for (const line of wf.split('\n').filter((l) => l.includes('$SPARKLE_PRIVATE_KEY'))) {
      assert.ok(/^\s*(SIG="\$\()?printf '%s' "\$SPARKLE_PRIVATE_KEY" \| \S+ -f - /.test(line) || /^\s*(\[|if \[) -[nz] "\$SPARKLE_PRIVATE_KEY" \]/.test(line), `${name}: ${line.trim()}`);
    }
    assert.ok(wf.includes('NODE="env -u SPARKLE_PRIVATE_KEY node"'), name);
    assert.ok(!wf.includes('sparkle:releaseNotesLink') && wf.includes('--notes-file'), name);
  }
});

test('the app REQUIRES a signed feed: release N (beta.43) signed it and a Mac updated through it; this is N+1', () => {
  // From here on an unsigned feed strands every Mac with this build, so both
  // publish lanes must keep signing and verifying it (the tests above).
  const script = fs.readFileSync(path.join(__dirname, '..', 'mac', 'make-app.sh'), 'utf8');
  assert.ok(script.includes('<key>SURequireSignedFeed</key><true/>'));
  assert.ok(script.includes('<key>SUVerifyUpdateBeforeExtraction</key><true/>'), 'Sparkle refuses SURequireSignedFeed without it');
});
