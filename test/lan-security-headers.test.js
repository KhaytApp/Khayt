const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const SRC = fs.readFileSync(path.join(__dirname, '..', 'lib', 'lan-server.js'), 'utf8');

/**
 * Khayt Online's security headers must be applied CENTRALLY, not per route.
 *
 * They used to be per route, at sixteen call sites, and the page that matters
 * most had been missed: `GET /intake` — the intake form itself, the one page a
 * shop hands to its customers and the only public surface that takes their
 * input — was served with no CSP, no X-Frame-Options, no nosniff and no
 * Referrer-Policy, while the quote and tracking pages had all four. The 429
 * shown when intake sessions are rate-limited and five quote-approval error
 * pages were missing them too.
 *
 * None of the sixteen calls was wrong. The defect was that the protection was
 * OPT-IN: a route that forgets ships unprotected and looks exactly like a route
 * that did not need it. Nothing errors, nothing is slow, the page just has no
 * headers. That is this codebase's recurring shape — a guard that is absent
 * rather than broken, and therefore silent.
 *
 * A test that listed the pages and checked each would inherit the same flaw: it
 * would pass for a page nobody added it to. So this asserts the STRUCTURE — the
 * headers go on before routing can begin — which is the property that makes
 * forgetting impossible.
 */

/** The body of the `http.createServer((req, res) => {` callback, up to the first route. */
function handlerPreamble() {
  const i = SRC.indexOf('http.createServer((req, res) => {');
  assert.ok(i > 0, 'could not find the LAN request handler — this guard has rotted');
  const start = SRC.indexOf('{', SRC.indexOf('=> {', i));
  return SRC.slice(start, start + 2000);
}

test('every response gets the security headers before any route runs', () => {
  const preamble = handlerPreamble();
  assert.match(preamble, /setLanHtmlSecurityHeaders\(res\);/,
    'the LAN request handler does not apply security headers up front — a route that '
    + 'forgets to call them would ship a customer-facing page with no CSP and no '
    + 'X-Frame-Options, which is exactly how GET /intake shipped.');

  // Before ROUTING, not merely somewhere in the handler: applied after a branch
  // has already returned a response, it protects nothing on that branch.
  const call = preamble.indexOf('setLanHtmlSecurityHeaders(res);');
  const firstBranch = preamble.search(/\n\s+(if|else if)\s*\(/);
  assert.ok(firstBranch === -1 || call < firstBranch,
    'security headers are applied after routing has already begun');
});

test('the header set still covers the four that matter', () => {
  // Named individually so removing one is a failure rather than a silent
  // weakening of a function whose name still promises all of them.
  const fn = SRC.slice(SRC.indexOf('function setLanHtmlSecurityHeaders'));
  const body = fn.slice(0, fn.indexOf('\n}'));
  for (const h of ['X-Content-Type-Options', 'X-Frame-Options', 'Referrer-Policy', 'Content-Security-Policy']) {
    assert.match(body, new RegExp(h), `setLanHtmlSecurityHeaders no longer sets ${h}`);
  }
  assert.match(body, /nosniff/);
  assert.match(body, /DENY/);
  assert.match(body, /object-src 'none'/, 'CSP no longer blocks plugin content');
  assert.match(body, /base-uri 'none'/, "CSP no longer pins <base>, so an injected tag could re-root every relative URL");
});

/**
 * The directives above are the ones an injected TAG uses. These are the ones an
 * injected tag uses to GET THE DATA OUT, and they were missing for the same
 * reason the headers themselves once were: nothing names what is not there.
 *
 * A CSP restricts only the directives it lists. With no `default-src`, a policy
 * naming four directives leaves `img-src`, `connect-src` and `frame-src` wide
 * open, and `form-action` and `frame-ancestors` stay open even WITH one, because
 * neither falls back to it. On the intake form — the one public page that takes
 * a customer's name, email and phone — that was the difference between an
 * injection being contained and it being able to post the lot to another host.
 *
 * Asserted one directive at a time, with the consequence spelled out, so that
 * dropping any of them fails loudly instead of quietly widening the policy.
 */
test('the CSP closes the routes an injection would exfiltrate through', () => {
  const fn = SRC.slice(SRC.indexOf('function setLanHtmlSecurityHeaders'));
  const body = fn.slice(0, fn.indexOf('\n}'));

  assert.match(body, /default-src 'self'/,
    'CSP has no default-src, so every directive it does not name — img-src and '
    + 'connect-src among them — is unrestricted, and a pixel is enough to carry a quote out');
  assert.match(body, /form-action 'self'/,
    'CSP no longer pins form-action. It does NOT fall back to default-src, so without it '
    + "an injected <form> on /intake can post the customer's name, email and phone to any host");
  assert.match(body, /frame-ancestors 'none'/,
    'CSP no longer pins frame-ancestors. X-Frame-Options still says DENY, but it is the '
    + 'legacy half of the pair and frame-ancestors does not fall back to default-src either');
});

/**
 * `script-src` keeps `'unsafe-inline'` because these pages embed their script —
 * the tracking page reloads itself every 30s, the intake form submits by fetch.
 * That is a fact to design around, not one to fix by deleting the keyword: drop
 * it and the customer-facing pages stop working, which is why no future tidy-up
 * should. The test exists so that the next person to read the policy and reach
 * for it finds out here rather than from a shop.
 */
test("inline script is permitted on purpose, and the pages still need it", () => {
  const fn = SRC.slice(SRC.indexOf('function setLanHtmlSecurityHeaders'));
  const body = fn.slice(0, fn.indexOf('\n}'));
  assert.match(body, /script-src 'self' 'unsafe-inline'/,
    'the LAN pages embed their own script; removing unsafe-inline stops the tracking '
    + 'page refreshing and the intake form submitting');

  for (const page of ['lan-order-page.js', 'lan-intake.js']) {
    const src = fs.readFileSync(path.join(__dirname, '..', 'lib', page), 'utf8');
    assert.match(src, /<script>/,
      `${page} no longer embeds script — if that is true of every LAN page, `
      + "'unsafe-inline' can and should come out of the CSP");
  }
});

test('no HTML response is left relying on its own header call', () => {
  // The inverse check. With the central call in place a per-route call is
  // harmless and idempotent, but a NEW html response written without one must
  // still be covered — which it now is by construction. This asserts the thing
  // that would break that: an early `return` before the central call.
  const preamble = handlerPreamble();
  const call = preamble.indexOf('setLanHtmlSecurityHeaders(res);');
  const before = preamble.slice(0, call);
  assert.doesNotMatch(before, /\breturn\b/,
    'the handler can return before the security headers are set, so some responses skip them');
});
