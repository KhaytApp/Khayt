/**
 * E2E smoke — what language a customer-facing document actually comes out in.
 *
 * lib/invoice-language.js decides, and its unit tests cover the decision. They
 * cannot cover the part that went wrong: renderInvoice had roughly twenty
 * separate places that emitted a second language — hardcoded Arabic label
 * halves, the shop's own secondary name and address, a Hijri date row — and
 * missing any one of them leaves Arabic on an English quote while every unit
 * test still passes.
 *
 * So this renders the real document in a real window and reads the text back.
 *
 * The case that matters most is ZATCA: Saudi Phase 1 requires Arabic on a tax
 * invoice, so "print one language" must NOT be reachable there, whatever the
 * setting says. That is a compliance guarantee, and it is asserted here against
 * a rendered document rather than against the resolver that decides it.
 *
 * Run: npm run test:e2e:invlang
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  /** Render a quote under one configuration and report what reached the page. */
  const render = (opts) => window.evaluate(async (o) => {
    settings.lang = o.lang;
    settings.enableZatca = o.zatca;
    settings.invoiceBilingual = o.mode;
    settings.invoiceSecondLang = o.sec || 'ar';
    // The shipped default, and the reason gating the toggle alone was not enough:
    // stores created before the fix already carry `true`.
    settings.useHijri = true;
    settings.bizEn = 'Erickson 3D Prints';
    settings.bizAr = 'خيط';
    settings.addrEn = 'Columbus, Ohio';
    // The default seed. An English shop never typed this and must never print it.
    settings.addrAr = 'الرياض، المملكة العربية السعودية';
    i18n.set(o.lang, { silent: true });
    clients.length = 0;
    clients.push({ id: 'C1', name: 'Acme Robotics' });
    const order = {
      id: 'Q1', status: 'quote', clientId: 'C1', project: 'Acme Robotics',
      date: '2026-08-10', price: 120, material: 'PLA', printTime: 6,
      parts: [{ name: 'Bracket', material: 'PLA', printTime: 6, printWeight: 210, baseCost: 120 }],
      extraLines: [],
    };
    await renderInvoiceForOrder(order);
    const txt = document.querySelector('#invoice-print-area').innerText;
    return {
      text: txt,
      arabic: (txt.match(/[؀-ۿ]/g) || []).length,
      // The English label halves an Arabic document carries when bilingual.
      english: ['Quotation', 'Billed To', 'Total due'].filter((s) => txt.includes(s)).length,
      hijri: /Hijri|هجري/i.test(txt),
      // Proof the document rendered at all, so a blank page cannot pass as "no Arabic".
      rendered: txt.trim().length > 200,
    };
  }, opts);

  // ---- the reported bug: an English shop, English quote ----
  const en = await render({ lang: 'en', zatca: false, mode: 'auto' });
  ok(en.rendered, 'the English quote actually rendered');
  ok(en.arabic === 0, `no Arabic on an English quote (found ${en.arabic} characters)`);
  ok(!en.hijri, 'no Hijri date row on an English quote');

  // ---- the same bug, worse: Arabic was never "the other language" ----
  for (const lang of ['fr', 'de', 'tr']) {
    const r = await render({ lang, zatca: false, mode: 'auto' });
    ok(r.rendered && r.arabic === 0, `no Arabic on a ${lang.toUpperCase()} quote (found ${r.arabic})`);
  }

  // ---- no regression for the shops the document was designed for ----
  const ar = await render({ lang: 'ar', zatca: false, mode: 'auto' });
  ok(ar.rendered && ar.arabic > 0, 'an Arabic shop still gets its Arabic document');
  ok(ar.english === 3, `and keeps the English pairing that serves its overseas customers (${ar.english}/3)`);
  ok(ar.hijri, 'and keeps the Hijri date');

  // ---- opting in ----
  const both = await render({ lang: 'en', zatca: false, mode: 'both' });
  ok(both.arabic > 0, 'an English shop that chooses bilingual gets Arabic back');

  // ---- opting out, from the other side ----
  const arSingle = await render({ lang: 'ar', zatca: false, mode: 'single' });
  ok(arSingle.rendered && arSingle.arabic > 0, 'an Arabic single-language document is still Arabic');
  ok(arSingle.english === 0, `and drops the English half (${arSingle.english} English labels left)`);

  // ---- the second language is the shop's to choose ----
  // The original fault was not only that documents were bilingual, but that the
  // second half could only ever BE Arabic. These labels come out of the locale
  // files, so an unreachable doc.* key shows up here as a missing word rather
  // than as a raw key nobody notices.
  const PAIRS = [
    { sec: 'fr', words: ['Devis', 'Facturé à', 'Montant'] },
    { sec: 'ja', words: ['見積書', '請求先', '金額'] },
    { sec: 'es', words: ['Presupuesto', 'Facturado a', 'Importe'] },
    { sec: 'de', words: ['Angebot', 'Rechnung an', 'Betrag'] },
  ];
  for (const { sec, words } of PAIRS) {
    const r = await render({ lang: 'en', zatca: false, mode: 'both', sec });
    const missing = words.filter((w) => !r.text.includes(w));
    ok(missing.length === 0, `English + ${sec}: the ${sec} labels print (missing: ${missing.join(', ') || 'none'})`);
    ok(r.arabic === 0, `English + ${sec}: and no Arabic leaks in (found ${r.arabic})`);
  }

  // The shop's own name and address exist only as an English/Arabic pair. A
  // French document must not pair French headings with an Arabic address.
  const enFr = await render({ lang: 'en', zatca: false, mode: 'both', sec: 'fr' });
  ok(!enFr.text.includes('الرياض'), 'the seeded Arabic address stays off an English/French document');

  // The primary language was hardcoded English-or-Arabic too, so a German shop
  // printed English headings however it was configured.
  const de = await render({ lang: 'de', zatca: false, mode: 'both', sec: 'es' });
  ok(de.text.includes('Angebot') && de.text.includes('Datum'),
    'a German shop gets German headings, not English ones');

  // ---- the other three documents, which were English-or-Arabic throughout ----
  // The invoice was only the reported half. A credit note, a delivery note and a
  // shop-floor work order printed every label as an English/Arabic ternary, so a
  // German shop got an English document however it was configured — the app
  // language was not consulted at all.
  const others = await window.evaluate(async () => {
    settings.lang = 'de';
    settings.enableZatca = false;
    settings.invoiceBilingual = 'single';
    i18n.set('de', { silent: true });
    clients.length = 0;
    clients.push({ id: 'C1', name: 'Acme GmbH' });
    const order = {
      id: 'O1', status: 'completed', clientId: 'C1', project: 'Acme GmbH',
      date: '2026-08-11', dueDate: '2026-08-20', price: 120, material: 'PLA', printTime: 6,
      courierName: 'DHL', trackingNumber: 'X1', deliveryAddress: 'Berlin',
      parts: [{ name: 'Halter', material: 'PLA', printTime: 6, printWeight: 210, baseCost: 120, qty: 2, supports: true }],
      extraLines: [],
    };
    printLog.push(order);
    saveAll();
    const inv = () => document.querySelector('#invoice-print-area').innerText;
    const out = {};
    await generateDeliveryNote('O1'); out.delivery = inv();
    await generateCreditNote(order, 50, 'test'); out.credit = inv();
    await generateWorkOrder('O1'); out.work = document.querySelector('#work-order-print-area').innerText;
    return out;
  });
  const german = [
    ['delivery note', others.delivery, ['Lieferschein', 'Liefern an', 'Sendungsnummer']],
    ['credit note', others.credit, ['Gutschrift', 'Ausgestellt an', 'Betrag']],
    ['work order', others.work, ['Arbeitsauftrag', 'Kunde', 'Gewicht (g)']],
  ];
  for (const [name, text, words] of german) {
    const missing = words.filter((w) => !text.includes(w));
    ok(missing.length === 0, `the ${name} is in German (missing: ${missing.join(', ') || 'none'})`);
    ok(!/[؀-ۿ]/.test(text), `and the ${name} carries no Arabic on a single-language setting`);
  }

  // ---- the compliance guarantee ----
  // Arabic is mandatory on a Saudi tax invoice. Every mode must fail to remove it.
  for (const mode of ['auto', 'both', 'single']) {
    const z = await render({ lang: 'en', zatca: true, mode });
    ok(z.arabic > 0, `ZATCA keeps Arabic on the document with mode="${mode}" (${z.arabic} characters)`);
  }
  // Picking another second language is not a route around the mandate either: a
  // tax invoice in English and French carries no Arabic and is not compliant.
  const zFr = await render({ lang: 'en', zatca: true, mode: 'both', sec: 'fr' });
  ok(zFr.arabic > 0, `ZATCA overrides a French second language (${zFr.arabic} Arabic characters)`);
  ok(!zFr.text.includes('Devis'), 'and the French labels are replaced, not merely added to');

  console.log('\ninvoice language smoke: all assertions passed');
} catch (err) {
  failed = true;
  console.error('\n' + (err && err.message ? err.message : String(err)));
} finally {
  // A DEADLINE, not politeness for its own sake.
  //
  // Every assertion above printed "all assertions passed" and then this close
  // never returned, so `npm run test:e2e:all` killed the suite and reported it
  // FAILED — a suite that passes and reports failure teaches people to ignore
  // it, and it cost ten minutes of every full run.
  //
  // It is not the invoice render: launching the app, rendering one document
  // and closing takes 142ms. Something this suite accumulates over its fifteen
  // renders keeps the app from quitting, and what that is has not been found.
  // Since `process.exit` on the next line is what actually ends the run, the
  // close gets ten seconds to be tidy and then the run ends anyway.
  await Promise.race([
    electronApp.close().catch(() => {}),
    new Promise((resolve) => setTimeout(resolve, 10_000)),
  ]);
}
process.exit(failed ? 1 : 0);
