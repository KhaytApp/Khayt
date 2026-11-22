/**
 * The small pages around a customer's quote — not found, a bad link, expired,
 * cannot approve, approved — used to be written inline in the LAN server's
 * routes. They live in lib/lan-quote-page.js now so the Mac app serves the same
 * bytes. Copied here VERBATIM from those routes and compared to the module.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { notice, lanEscapeHtml } = require('../lib/lan-quote-page.js');

const originals = {
  quote_not_found: () => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Not Found</title></head><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Quote not found</h2></body></html>`,
  invalid_link: () => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Invalid link</title></head><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Invalid link</h2><p style="color:#94a3b8;margin-top:8px;">Open the quote from the link your shop sent you.</p></body></html>`,
  order_not_found: () => `<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Order not found</h2></body></html>`,
  invalid_link_approve: () => `<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Invalid link</h2><p>Open the quote page from the link your shop sent you, then approve from there.</p></body></html>`,
  expired: () => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Quote Expired</title></head><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Quote expired</h2><p>This quote is no longer valid. Please contact the shop for an updated quote.</p></body></html>`,
  cannot_approve: () => `<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Cannot approve</h2><p>This quote is no longer awaiting approval.</p></body></html>`,
  approved: (projectName) => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Quote Approved</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#6366f1}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Quote Approved!</h2><p>Your approval for <strong>${projectName}</strong> has been received. We'll start working on your order shortly.</p></div></body></html>`,
};

test('every notice is the route\'s own page, byte for byte', () => {
  for (const kind of ['quote_not_found', 'invalid_link', 'order_not_found', 'invalid_link_approve', 'expired', 'cannot_approve']) {
    assert.equal(notice(kind), originals[kind](), kind);
  }
  for (const project of ['Bracket', lanEscapeHtml('<b>&</b> "x"'), 'مقبض', '']) {
    assert.equal(notice('approved', { project }), originals.approved(project), `approved: ${project}`);
  }
  assert.equal(notice('nothing'), '');
});

test('the server draws every one of them from the module', () => {
  const fs = require('node:fs');
  const src = fs.readFileSync(require('node:path').join(__dirname, '..', 'lib', 'lan-server.js'), 'utf8');
  for (const kind of ['quote_not_found', 'invalid_link', 'order_not_found', 'invalid_link_approve', 'expired', 'cannot_approve', 'approved']) {
    assert.ok(src.includes(`LanQuotePage.notice('${kind}'`), `the server no longer calls notice('${kind}')`);
  }
  assert.ok(!src.includes('<h2>Quote not found</h2>'), 'an inline copy of the not-found page is back in the server');
  assert.ok(!src.includes('<h2>Cannot approve</h2>'), 'an inline copy of the cannot-approve page is back in the server');
});
