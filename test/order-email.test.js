/**
 * lib/order-email.js is what a shop's email to a customer says, lifted.
 *
 * THE PROOF, as in `telegram-message.test.js`: the original
 * `autoSendEmailNotification` is copied below and run beside the module over
 * thousands of generated orders, customers and mail settings. What was going
 * to be SENT is compared — the address, the subject and the body.
 *
 * ── THE ORIGINAL IS QUOTED WITH ONE LINE REPAIRED, AND THAT IS THE POINT ───
 *
 * The shipped original opens with
 *
 *     const shopName = shopName() || 'Khayt';
 *
 * in a scope where `shopName` is also a global function. The const shadows the
 * function, so the initialiser reads the binding before it is initialised and
 * throws `ReferenceError: Cannot access 'shopName' before initialization` —
 * every time, before anything is sent. Nobody awaited the call, so it became an
 * unhandled rejection and no email has left the app since it appeared in #822
 * (2026-08-31).
 *
 * Comparing the module against THAT original would compare it against nothing.
 * So the quote below repairs that one line, and `shippedLineThrows` pins the
 * defect itself.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const Email = require('../lib/order-email.js');
globalThis.KhaytOrderEmail = Email;
const Status = require('../lib/order-status.js');

const escapeHtml = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[c]);

/**
 * `autoSendEmailNotification` as it stands in renderer/integrations.js, with
 * its transport replaced by a recorder — and with the shadowed `const` renamed
 * so that it can run at all. Everything else is character for character.
 */
function original(order, newStatus, settings, clients, shopNameFn, t, localName, sent, toasts) {
  const cfg = settings.emailConfig;
  if (!cfg || cfg.provider === 'none' || !(cfg.triggers || []).includes(newStatus)) return;
  if (!order.clientId) return;
  const client = clients.find(c => c.id === order.clientId);
  if (!client?.email) {
    if (cfg && cfg.provider !== 'none' && (cfg.triggers || []).includes(newStatus)) {
      toasts.push('no_email');
    }
    return;
  }
  const shop = shopNameFn() || 'Khayt';           // ← the repaired line
  const statusLabel = t('queue.' + newStatus) || newStatus;
  const subject = `${shop} — Order ${order.id} Update: ${statusLabel}`;
  const body = `<div style="font-family:sans-serif;max-width:500px;margin:0 auto;padding:20px;">
    <h2 style="color:#5E2E14;">${escapeHtml(shop)}</h2>
    <p>Dear ${escapeHtml(localName(client) || client.email)},</p>
    <p>Your order <strong>${escapeHtml(order.id)}</strong> (${escapeHtml(order.project || '')}) has been updated:</p>
    <p style="font-size:18px;font-weight:bold;color:#5E2E14;">${escapeHtml(statusLabel)}</p>
    ${order.dueDate ? `<p>Due date: ${escapeHtml(order.dueDate)}</p>` : ''}
    <p>Thank you for your business!</p>
    <p style="font-size:12px;color:#888;">— ${escapeHtml(shop)}</p>
  </div>`;
  sent.push({ to: client.email, subject, body });
}

// ── Generated shops ────────────────────────────────────────────────────────

function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const STATUSES = ['pending', 'printing', 'post', 'qc', 'completed', 'delivered', 'on_hold', 'quote'];
const PROVIDERS = ['none', 'sendgrid', 'mailgun', 'custom', ''];
// Names and projects that exercise the escaping: quotes, angle brackets,
// ampersands and an apostrophe are all customer-supplied text going into HTML.
const NAMES = ['Sara', 'A & B Design', '<script>x</script>', "O'Brien", 'مؤسسة الطباعة', ''];
const PROJECTS = ['Bracket', 'Gear "v2"', '<b>Sign</b>', "Cap & Lid", ''];

function shopFor(rnd) {
  const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
  const triggers = STATUSES.filter(() => rnd() < 0.4);
  const hasClient = rnd() < 0.85;
  const client = {
    id: 'C1',
    name: pick(NAMES),
    email: rnd() < 0.8 ? 'buyer@example.com' : '',
  };
  return {
    settings: {
      emailConfig: { provider: pick(PROVIDERS), triggers },
      bizEn: pick(NAMES),
    },
    clients: hasClient ? [client] : [],
    order: {
      id: 'ORD-' + Math.floor(rnd() * 9999),
      clientId: hasClient && rnd() < 0.9 ? 'C1' : '',
      project: pick(PROJECTS),
      dueDate: rnd() < 0.5 ? '2026-10-01' : '',
    },
    status: pick(STATUSES),
  };
}

test('the module sends exactly what the renderer would have sent', () => {
  const rnd = mulberry32(20260913);
  let compared = 0, sentCount = 0, unconfiguredCount = 0;
  for (let i = 0; i < 4000; i++) {
    const s = shopFor(rnd);
    const shopNameFn = () => s.settings.bizEn;
    const t = (key) => ({ 'queue.completed': 'Completed', 'queue.printing': 'Printing' })[key] || '';
    const localName = (c) => (c && c.name) || '';

    const sent = [], toasts = [];
    original(s.order, s.status, s.settings, s.clients, shopNameFn, t, localName, sent, toasts);

    const mail = Email.messageFor(s.order, s.status, {
      settings: s.settings, clients: s.clients,
      shopName: shopNameFn() || 'Khayt',
      clientName: localName(s.clients.find(c => c.id === s.order.clientId)),
      statusLabel: t('queue.' + s.status) || s.status,
    });

    // ── ONE DELIBERATE DIVERGENCE: A PROVIDER THAT IS THE EMPTY STRING ─────
    //
    // The renderer refused only the literal `'none'`, so a shop whose provider
    // is `''` — never configured, or cleared — built a whole email and handed
    // it to `hub:send-email`, which matches no provider and returns the
    // `mailto:` fallback. The renderer ignores that fallback ("no toast"), so
    // the message was assembled, addressed, and dropped.
    //
    // `outboundFor` has always said the opposite — `email.provider &&` — which
    // means the two halves of this app disagreed about whether an unconfigured
    // shop emails its customers. The module keeps `outboundFor`'s answer,
    // because it is the one that is true: nothing is delivered either way.
    const unconfigured = !s.settings.emailConfig.provider;
    if (unconfigured) {
      assert.equal(mail, null, 'an unconfigured provider must build nothing');
      unconfiguredCount++;
      compared++;
      continue;
    }

    if (sent.length === 0) {
      assert.equal(mail, null, `renderer sent nothing; module built one (${s.status})`);
    } else {
      assert.ok(mail, `renderer sent one; module built nothing (${s.status})`);
      assert.equal(mail.to, sent[0].to);
      assert.equal(mail.subject, sent[0].subject);
      assert.equal(mail.html, sent[0].body);
      sentCount++;
    }
    compared++;
  }
  assert.equal(compared, 4000);
  // The corpus must actually reach the sending path, or this proves nothing.
  assert.ok(sentCount > 300, `only ${sentCount} of 4000 shops sent an email`);
  // And the divergence above must actually be exercised, not assumed.
  assert.ok(unconfiguredCount > 100, `only ${unconfiguredCount} shops had no provider set`);
});

test('the shipped line cannot run: a const shadowing the function it calls', () => {
  // Exactly the shape that has been in renderer/integrations.js since #822.
  function shopName() { return 'A Shop'; }
  assert.throws(() => {
    // eslint-disable-next-line no-shadow
    const shopName = shopName() || 'Khayt';   // ← TDZ: reads itself
    return shopName;
  }, ReferenceError);
});

test('no renderer file still shadows a function with a const of its own name', () => {
  // The defect was in three separate functions, and a fourth would be just as
  // silent: the caller never awaits, so the rejection is swallowed.
  const dir = path.join(__dirname, '..', 'renderer');
  const offenders = [];
  for (const name of fs.readdirSync(dir)) {
    if (!name.endsWith('.js')) continue;
    const src = fs.readFileSync(path.join(dir, name), 'utf8');
    for (const m of src.matchAll(/(?:const|let)\s+([A-Za-z_$][\w$]*)\s*=\s*\1\s*\(/g)) {
      offenders.push(`${name}: ${m[0].trim()}`);
    }
  }
  assert.deepEqual(offenders, [], 'self-shadowing binding — throws before it can do anything');
});

test('outboundFor announces an email exactly when one would be built', () => {
  const rnd = mulberry32(7771);
  for (let i = 0; i < 2000; i++) {
    const s = shopFor(rnd);
    const reaches = Status.outboundFor(s.order, s.status, {
      settings: s.settings, clients: s.clients,
    });
    const announced = reaches.find(r => r.channel === 'email');
    const mail = Email.messageFor(s.order, s.status, {
      settings: s.settings, clients: s.clients, shopName: 'X', statusLabel: s.status,
    });
    assert.equal(!!announced, !!mail,
      `outboundFor and messageFor disagree for ${s.status}/${s.settings.emailConfig.provider}`);
    if (announced) assert.equal(announced.via, s.settings.emailConfig.provider);
  }
});

test('a host that speaks only HTTPS knows which providers it can carry', () => {
  assert.equal(Email.isHttpProvider('sendgrid'), true);
  assert.equal(Email.isHttpProvider('mailgun'), true);
  // SMTP: a socket and a dialogue, which the Mac app does not have. It must
  // refuse the move rather than make it and skip the email.
  assert.equal(Email.isHttpProvider('custom'), false);
  assert.equal(Email.isHttpProvider('none'), false);
  assert.equal(Email.isHttpProvider(''), false);
});

test('outboundFor refuses to guess when the module is missing', () => {
  const saved = globalThis.KhaytOrderEmail;
  delete globalThis.KhaytOrderEmail;
  try {
    assert.throws(() => Status.outboundFor({ id: 'O1' }, 'completed', { settings: {}, clients: [] }),
      /order-email\.js is not loaded/);
  } finally {
    globalThis.KhaytOrderEmail = saved;
  }
});

test('mailgunDomainPatternMatchesLib: the Mac copies the rule, it does not rewrite it', () => {
  // A Swift regex that "reads the same" is how two apps come to disagree about
  // which sending domain is valid. The first draft of the Swift one accepted a
  // label beginning with a hyphen and rejected a numeric TLD this one accepts.
  const libSrc = fs.readFileSync(path.join(__dirname, '..', 'lib', 'host-guard.js'), 'utf8');
  const libPattern = libSrc.match(/if \(!(\/\^\[a-z0-9\].*?\/)\.test\(d\)\) return null;/);
  assert.ok(libPattern, 'could not find the domain pattern in lib/host-guard.js');
  // The literal as JavaScript writes it, minus the slashes.
  const libBody = libPattern[1].slice(1, -1);

  const swiftPath = path.join(__dirname, '..', 'mac', 'KhaytCore', 'Sources',
                              'KhaytApp', 'EmailClient.swift');
  const swiftSrc = fs.readFileSync(swiftPath, 'utf8');
  const swiftMatch = swiftSrc.match(/mailgunDomainPattern\s*=\s*\n?\s*"([^"]+)"/);
  assert.ok(swiftMatch, 'could not find mailgunDomainPattern in EmailClient.swift');
  // Swift escapes a backslash in a plain string literal; the pattern itself is
  // what has to match, so undo that one difference and nothing else.
  const swiftBody = swiftMatch[1].replace(/\\\\/g, '\\');

  assert.equal(swiftBody, libBody);
});
