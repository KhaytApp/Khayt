'use strict';
const test = require('node:test');
const assert = require('node:assert');
const wa = require('../lib/wa-template.js');

/**
 * A shop writes its templates once and sends them from whichever app is open.
 * If the two apps knew different placeholder names, a template written in one
 * would go out of the other with `{{due}}` printed literally, to a customer.
 */

test('every placeholder the editor advertises is filled', () => {
  // The editor's own hint line: {{client}} · {{id}} · {{price}} · {{due}} · {{status}}
  const body = 'Hi {{client}}, order {{id}} — {{price}} {{currency}}, due {{due}} ({{status}})';
  assert.strictEqual(
    wa.fillTemplate(body, {
      client: 'Layla', id: 'O-7', price: '250.00', currency: 'SAR',
      due: '2026-09-30', status: 'Ready',
    }),
    'Hi Layla, order O-7 — 250.00 SAR, due 2026-09-30 (Ready)');
});

test('a placeholder used twice is filled twice', () => {
  assert.strictEqual(wa.fillTemplate('{{id}} and {{id}}', { id: 'O-1' }), 'O-1 and O-1');
});

test('a nameless customer keeps the sentence shape, and a missing date is an em dash', () => {
  // "Hi ..., your order is ready" reads as a template somebody forgot to
  // fill — which is what it is, and what the shop should notice before
  // sending. The em dash is the mark this app uses for a figure it lacks.
  const out = wa.fillTemplate('Hi {{client}}, due {{due}}', {});
  assert.strictEqual(out, 'Hi ..., due —');
  assert.strictEqual(wa.fillTemplate('{{client}}', { client: '' }), '...');
  assert.strictEqual(wa.fillTemplate('{{client}}', { client: null }), '...');
});

test('a placeholder with no blank of its own disappears rather than showing braces', () => {
  // A customer must never see `{{price}}`.
  assert.strictEqual(wa.fillTemplate('{{id}}|{{price}}|{{currency}}|{{status}}', {}), '|||');
});

test('a value holding a replacement pattern is inserted literally', () => {
  // The reason this splits and joins rather than building a regex: `$&` in a
  // replacement string means "the whole match", so a customer called `$&`
  // would rewrite their own name — and `$'` would paste the rest of the
  // message in.
  assert.strictEqual(wa.fillTemplate('{{client}}', { client: '$&' }), '$&');
  assert.strictEqual(wa.fillTemplate('a{{client}}b', { client: "$'" }), "a$'b");
  assert.strictEqual(wa.fillTemplate('{{client}}', { client: '$$' }), '$$');
});

test('a value that is itself a placeholder is not filled again', () => {
  // Otherwise a customer named "{{price}}" would have a price printed as
  // their name — substitution running over its own output.
  assert.strictEqual(wa.fillTemplate('{{client}} {{price}}',
    { client: '{{price}}', price: '99' }), '{{price}} 99');
});

test('a template with no placeholders comes back unchanged', () => {
  assert.strictEqual(wa.fillTemplate('Thank you!', { client: 'X' }), 'Thank you!');
});

test('a missing or odd template does not throw', () => {
  for (const body of [undefined, null, '', 0, false, 42, {}, []]) {
    assert.doesNotThrow(() => wa.fillTemplate(body, { client: 'X' }));
  }
  assert.strictEqual(wa.fillTemplate(null, {}), '');
  assert.strictEqual(wa.fillTemplate(undefined, {}), '');
});

test('the placeholder list is the one the defaults actually use', () => {
  // The shipped templates are the contract: a placeholder one of them uses
  // and this list does not know would go out with braces in it.
  const defaults = [
    'Hi {{client}}, your order {{id}} is ready! Total: {{price}} {{currency}}. Please arrange pickup or delivery. Thank you!',
    "Hi {{client}}, we've received order {{id}} and it's now in our production queue. We'll notify you when it's ready.",
    'Hi {{client}}, gentle reminder: payment of {{price}} {{currency}} is outstanding for order {{id}}. Thank you!',
  ];
  for (const body of defaults) {
    const filled = wa.fillTemplate(body, {
      client: 'Layla', id: 'O-7', price: '250.00', currency: 'SAR',
      due: '2026-09-30', status: 'Ready',
    });
    assert.ok(!/\{\{|\}\}/.test(filled), `braces left in: ${filled}`);
  }
});

test('usesPlaceholder answers about the template, not about the values', () => {
  assert.strictEqual(wa.usesPlaceholder('a {{due}} b', 'due'), true);
  assert.strictEqual(wa.usesPlaceholder('a {{due}} b', 'price'), false);
  assert.strictEqual(wa.usesPlaceholder(null, 'due'), false);
});
