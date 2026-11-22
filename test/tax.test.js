const { test } = require('node:test');
const assert = require('node:assert/strict');

const T = require('../lib/tax.js');

/**
 * Khayt computed one tax, at one rate, priced one way: VAT, 15%, included in the
 * listed price. Correct for the Gulf and most of Europe; wrong for the US and
 * Canada, where a price is quoted WITHOUT tax and the tax is added at the end.
 *
 * The invariant every test below is really defending: on an invoice the shop
 * prints subtotal, tax and total next to each other, so they must add up
 * EXACTLY at two decimal places. Inclusive pricing extracts the tax rather than
 * adding it, which is where the pennies go missing.
 */

const VAT15 = { mode: 'inclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] };
const US = { mode: 'exclusive', rates: [{ id: 'st', label: 'Sales Tax', percent: 8.25 }] };

/**
 * The guarantee, asserted the same way everywhere.
 *
 * Compared in CENTS. Adding two values that are each exact to 2dp can still
 * drift in binary floating point — 86.95 + 13.04 is 99.99000000000001 — and that
 * is an artefact of the comparison, not a penny anyone is missing. Integer cents
 * is the only representation in which "these three numbers add up" is a
 * statement about money rather than about IEEE 754.
 */
const cents = (n) => Math.round(n * 100);
const addsUp = (r, label) =>
  assert.equal(cents(r.subtotal) + cents(r.taxTotal), cents(r.total),
    `${label}: ${r.subtotal} + ${r.taxTotal} must equal ${r.total}`);

test('inclusive matches the arithmetic Khayt has always used', () => {
  // The old formula, written out in ten places: price * rate / (100 + rate).
  const r = T.computeTax(115, VAT15);
  assert.equal(r.total, 115, 'the customer still pays the listed price');
  assert.equal(r.subtotal, 100);
  assert.equal(r.taxTotal, 15);
  addsUp(r, 'inclusive 115');
});

test('exclusive ADDS the tax — the thing the old model could not express', () => {
  const r = T.computeTax(100, US);
  assert.equal(r.subtotal, 100, 'the quoted price is the pre-tax price');
  assert.equal(r.taxTotal, 8.25);
  assert.equal(r.total, 108.25, 'and the customer pays more than the sticker');
  addsUp(r, 'exclusive 100');
});

test('the two modes are not the same sum dressed differently', () => {
  // 100 inclusive of 15% is not 100 plus 15%. Getting this wrong overcharges or
  // undercharges every order a shop takes.
  const inc = T.computeTax(100, VAT15);
  const exc = T.computeTax(100, { ...VAT15, mode: 'exclusive' });
  assert.equal(inc.total, 100);
  assert.equal(exc.total, 115);
  assert.notEqual(inc.subtotal, exc.subtotal);
});

test('no rates means no tax, and the amount passes through untouched', () => {
  for (const mode of ['inclusive', 'exclusive']) {
    const r = T.computeTax(99.99, { mode, rates: [] });
    assert.deepEqual({ s: r.subtotal, t: r.taxTotal, tot: r.total }, { s: 99.99, t: 0, tot: 99.99 });
  }
});

test('a zero or negative rate is dropped rather than charged', () => {
  const r = T.computeTax(100, { mode: 'exclusive', rates: [{ percent: 0 }, { percent: -5 }, { percent: 10 }] });
  assert.equal(r.taxes.length, 1);
  assert.equal(r.total, 110);
});

/* ── more than one tax ─────────────────────────────────────────────────── */

test('two taxes appear as two lines, because they are two remittances', () => {
  // India: CGST and SGST go to different authorities and must be listed apart.
  const r = T.computeTax(1000, { mode: 'exclusive', rates: [
    { id: 'cgst', label: 'CGST', percent: 9 },
    { id: 'sgst', label: 'SGST', percent: 9 },
  ] });
  assert.equal(r.taxes.length, 2);
  assert.deepEqual(r.taxes.map((t) => t.amount), [90, 90]);
  assert.equal(r.total, 1180);
  addsUp(r, 'CGST+SGST');
});

test('two taxes extract correctly from an inclusive price too', () => {
  const r = T.computeTax(1180, { mode: 'inclusive', rates: [
    { id: 'cgst', label: 'CGST', percent: 9 },
    { id: 'sgst', label: 'SGST', percent: 9 },
  ] });
  assert.equal(r.subtotal, 1000);
  assert.equal(r.total, 1180);
  addsUp(r, 'inclusive CGST+SGST');
});

test('a compound rate charges on the base plus what came before it', () => {
  // 100 → GST 10 → PST on 110, not on 100.
  const r = T.computeTax(100, { mode: 'exclusive', rates: [
    { id: 'gst', label: 'GST', percent: 10 },
    { id: 'pst', label: 'PST', percent: 10, compound: true },
  ] });
  assert.equal(r.taxes[0].amount, 10);
  assert.equal(r.taxes[1].amount, 11, 'the compound rate is charged on 110');
  assert.equal(r.total, 121);
  addsUp(r, 'compound');
});

test('a compound rate inverts exactly from an inclusive total', () => {
  const rates = [{ id: 'gst', percent: 10 }, { id: 'pst', percent: 10, compound: true }];
  const r = T.computeTax(121, { mode: 'inclusive', rates });
  assert.equal(r.subtotal, 100, 'the base is recovered, not approximated');
  addsUp(r, 'inclusive compound');
});

/* ── the pennies ───────────────────────────────────────────────────────── */

test('the parts add up to the whole on an inclusive total that does not divide', () => {
  // 99.99 at 15% inclusive: the exact subtotal is 86.947826…, so subtotal and
  // tax both round, and independently rounded they can miss the total by a cent.
  const r = T.computeTax(99.99, VAT15);
  assert.equal(r.total, 99.99, 'the customer pays exactly what was quoted');
  addsUp(r, '99.99 inclusive');
});

test('the invariant holds across a sweep, not just the examples I picked', () => {
  // A hand-picked case proves the formula on that case. This is the assertion
  // that would actually catch a rounding bug.
  const profiles = [
    VAT15,
    { mode: 'inclusive', rates: [{ percent: 20 }] },
    { mode: 'exclusive', rates: [{ percent: 8.25 }] },
    { mode: 'inclusive', rates: [{ percent: 9 }, { percent: 9 }] },
    { mode: 'exclusive', rates: [{ percent: 5 }, { percent: 9.975, compound: true }] },
    { mode: 'inclusive', rates: [{ percent: 8.1 }] },
  ];
  for (const p of profiles) {
    for (let c = 1; c <= 2000; c++) {
      const amount = c / 100;
      const r = T.computeTax(amount, p);
      assert.equal(
        cents(r.subtotal) + cents(r.taxTotal), cents(r.total),
        `${p.mode} ${JSON.stringify(p.rates)} @ ${amount}: ${r.subtotal} + ${r.taxTotal} ≠ ${r.total}`,
      );
      if (p.mode === 'inclusive') {
        assert.equal(r.total, Math.round(amount * 100) / 100, `inclusive total must equal the listed price @ ${amount}`);
      }
    }
  }
});

test('the reconciling cent lands on the largest tax line', () => {
  // With two very different rates the adjustment must not distort the small one
  // out of proportion.
  const r = T.computeTax(99.99, { mode: 'inclusive', rates: [
    { id: 'big', percent: 20 }, { id: 'small', percent: 1 },
  ] });
  addsUp(r, 'lopsided pair');
  assert.ok(r.taxes[0].amount > r.taxes[1].amount, 'the 20% line is still the larger one');
});

/* ── input handling ────────────────────────────────────────────────────── */

test('junk in does not produce NaN out', () => {
  for (const bad of [undefined, null, NaN, 'abc', {}]) {
    const r = T.computeTax(bad, VAT15);
    assert.equal(Number.isFinite(r.total), true, `amount=${String(bad)}`);
    assert.equal(r.total, 0);
  }
  const r = T.computeTax(100, { mode: 'nonsense', rates: 'not-an-array' });
  assert.equal(r.total, 100);
  assert.equal(r.mode, 'inclusive', 'an unrecognised mode falls back to what Khayt has always done');
});

/* ── presets ───────────────────────────────────────────────────────────── */

test('the US and Canada are exclusive — the reason this module exists', () => {
  assert.equal(T.presetFor('US').mode, 'exclusive');
  assert.equal(T.presetFor('CA').mode, 'exclusive');
  assert.equal(T.presetFor('IN').mode, 'exclusive');
});

test('the Gulf and Europe stay inclusive, so nothing changes for them', () => {
  for (const c of ['SA', 'AE', 'GB', 'DE', 'FR', 'TR']) {
    assert.equal(T.presetFor(c).mode, 'inclusive', c);
  }
  assert.equal(T.presetFor('SA').rates[0].percent, 15, 'Saudi VAT is unchanged');
});

test('the tax has the name and the registration label the country actually uses', () => {
  // Printing "VAT No." above an Australian ABN is wrong in a way an accountant
  // spots immediately.
  assert.equal(T.presetFor('AU').registration, 'ABN');
  assert.equal(T.presetFor('IN').registration, 'GSTIN');
  assert.equal(T.presetFor('US').name, 'Sales Tax');
  assert.equal(T.presetFor('FR').rates[0].label, 'TVA');
});

test('an unlisted country gets a generic profile and charges nothing', () => {
  // Better than a confidently wrong rate the shop never notices.
  for (const c of ['ZZ', '', null, undefined, 'Atlantis']) {
    const p = T.presetFor(c);
    assert.deepEqual(p.rates, [], String(c));
    assert.equal(p.mode, 'inclusive');
  }
});

test('presets are copies — editing one shop’s rates cannot alter the table', () => {
  const a = T.presetFor('SA');
  a.rates[0].percent = 99;
  assert.equal(T.presetFor('SA').rates[0].percent, 15);
});

/* ── migration ─────────────────────────────────────────────────────────── */

test('an existing shop keeps computing the identical number', () => {
  // Every shop in the field has enableVat + vatRate and nothing else, and its
  // prices are inclusive because that is the only thing Khayt ever did.
  const p = T.profileFromSettings({ enableVat: true, vatRate: 15 });
  assert.equal(p.mode, 'inclusive');
  const r = T.computeTax(115, p);
  assert.deepEqual({ s: r.subtotal, t: r.taxTotal }, { s: 100, t: 15 });
});

test('VAT switched off means no tax, not a zero-rate line', () => {
  const p = T.profileFromSettings({ enableVat: false, vatRate: 15 });
  assert.deepEqual(p.rates, []);
  assert.equal(T.computeTax(115, p).total, 115);
});

test('a new-style profile is used in preference to the legacy fields', () => {
  const p = T.profileFromSettings({
    enableVat: true, vatRate: 15,
    tax: { name: 'Sales Tax', mode: 'exclusive', registration: 'EIN', rates: [{ id: 's', label: 'ST', percent: 8.25 }] },
  });
  assert.equal(p.mode, 'exclusive');
  assert.equal(p.rates[0].percent, 8.25);
});

test('empty settings are safe', () => {
  for (const s of [undefined, null, {}]) {
    const p = T.profileFromSettings(s);
    assert.deepEqual(p.rates, []);
    assert.equal(T.computeTax(50, p).total, 50);
  }
});

/* ── the rest of the app, not just the invoice ─────────────────────────────── */

/**
 * Exclusive pricing shipped on the invoice first, while nine other money paths
 * still divided tax out of the price unconditionally — right only when the price
 * includes tax. For a US shop that meant analytics, loyalty points and the
 * accounting export all disagreed with the invoice the customer was sent.
 *
 * These pin the two shapes the rest of the app relies on.
 */

test('subtotal is the net figure in BOTH modes, without the caller branching', () => {
  // This is why every call site could become one expression: exclusive returns
  // the amount untouched (it is already net), inclusive divides the tax out.
  const inc = { mode: 'inclusive', rates: [{ percent: 15 }] };
  const exc = { mode: 'exclusive', rates: [{ percent: 15 }] };
  assert.equal(T.computeTax(115, inc).subtotal, 100, 'inclusive: tax comes out');
  assert.equal(T.computeTax(100, exc).subtotal, 100, 'exclusive: the price IS the net');
});

test('tax collected is right in both modes, from the same call', () => {
  // The reporting figure. Under exclusive it is price x rate; under inclusive it
  // is the portion already inside the price. One call, no branch at the caller.
  const inc = { mode: 'inclusive', rates: [{ percent: 15 }] };
  const exc = { mode: 'exclusive', rates: [{ percent: 15 }] };
  assert.equal(T.computeTax(115, inc).taxTotal, 15);
  assert.equal(T.computeTax(100, exc).taxTotal, 15);
});

test('an exclusive shop owes MORE than the price it entered', () => {
  // The bug in one line: anything reporting `price` as the total understates an
  // exclusive shop's invoice by the whole tax.
  const exc = { mode: 'exclusive', rates: [{ percent: 8.25 }] };
  const r = T.computeTax(100, exc);
  assert.ok(r.total > 100, `total must exceed the entered price (${r.total})`);
  assert.equal(r.total, 108.25);
});
