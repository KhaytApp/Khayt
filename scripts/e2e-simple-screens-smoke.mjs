/**
 * E2E smoke — Simple's reduced screens, S4 cards 6–8
 * (Figma 7Iqw0GcrLLRW7CLDEhTa1P, page "S4 · Simple mode (desktop)").
 *
 * The mode is switched with real clicks on Settings › General, and back.
 * In Simple:
 *   - card 6: the board has four columns (Quote · Queued · Printing · Ready);
 *     a job on hold, in post-processing, in QC or shipped sits in one of them
 *     with a note. A customer opens as five fields; saving keeps the business
 *     details, the second name and the other addresses it does not show.
 *   - card 7: Production shows the checklist (Remove) and the custom order
 *     fields (Edit renames); WIP, QC, delivery estimates and the environment
 *     log are not drawn.
 *   - card 8: Library & Files lists this computer / a folder / Google Drive;
 *     S3, tiering and the backup copy are not drawn; a bucket in use says
 *     "Set up in Professional"; "Connect…" opens the Drive set-up.
 * In Professional each screen is as it was.
 *
 * Run: npm run test:e2e:simplescreens
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  // Sample book (sample data only).
  await window.evaluate(() => {
    settings.mode = 'professional';
    const day = localDateStr();
    const job = (id, status, extra) => ({ id, project: 'Job ' + id, status, price: 50, printTime: 1, clientId: 'CLI-s4', parts: [{ name: 'a', printWeight: 10 }], date: day, ...extra });
    printLog.push(
      job('ORD-q', 'quote'), job('ORD-p', 'pending'), job('ORD-h', 'on_hold', { holdReason: 'Waiting on filament' }),
      job('ORD-r', 'printing'), job('ORD-pp', 'post'), job('ORD-qc', 'qc'), job('ORD-c', 'completed'),
      job('ORD-s', 'completed', { shippedAt: new Date().toISOString() }),
    );
    clients.push({
      id: 'CLI-s4', nameEn: 'Layla Design Studio', nameAr: 'استوديو ليلى', phone: '+966500000000', email: 'layla@example.com',
      cr: '1010101010', vat: '300000000000003', paymentTermsDays: 30, creditLimit: 5000, notes: 'Prefers pickup on Thursdays',
      addresses: [{ id: 'ADDR-a', label: 'Studio', address: 'Old Road' }, { id: 'ADDR-b', label: 'Home', address: 'Al Malqa' }],
      priceList: [{ product: 'Bracket', price: 12, note: '' }],
    });
    settings.postChecklist = [{ id: 'PCH-1', label: 'Remove supports' }, { id: 'PCH-2', label: 'Sand contact faces' }];
    settings.customFields = [{ id: 'CF-1', label: 'Engraving', type: 'text' }];
    settings.printLibrary = Object.assign({}, settings.printLibrary, { s3: { enabled: true, bucket: 'sample-bucket' } });
    settings.queueViewChosen = false;
    saveAll();
    loadSettingsIntoForm();
    applyMode();
  });

  const shown = (sel) => window.evaluate((s) => {
    const el = document.querySelector(s);
    if (!el) return 'missing';
    for (let n = el; n && n !== document.body; n = n.parentElement) {
      if (getComputedStyle(n).display === 'none') return false;
    }
    return true;
  }, sel);
  const closeModal = () => window.evaluate(() => document.querySelectorAll('#modalMount > *').forEach((n) => n.remove()));
  const openPane = async (section) => {
    await window.click('#tabbtn-settings-tab');
    await window.click(`.settings-nav-item[data-settings-section="${section}"]`);
    await window.waitForSelector(`#settings-panel-${section}.active`);
  };
  const clickMode = async (mode) => {
    await openPane('general');
    await window.click(mode === 'simple' ? '#btnModeSimple' : '#btnModePro');
    await window.waitForFunction((m) => settings.mode === m && document.body.classList.contains('mode-simple') === (m === 'simple'), mode);
  };

  const board = async () => {
    await window.click('#tabbtn-queue-tab');
    await window.waitForSelector('#queue-tab.active');
    return window.evaluate(() => {
      const kb = document.querySelector('.kanban');
      const cols = [...kb.children].filter((c) => c.classList.contains('kanban-col') && getComputedStyle(c).display !== 'none');
      const head = (c) => (c.querySelector('h3 [data-i18n], .quotes-section-header [data-i18n]')?.textContent || '').trim();
      const inCol = (status, id) => !!document.querySelector(`#list-${status} [data-order-id="${id}"]`);
      const note = (id) => document.querySelector(`[data-order-id="${id}"] .sm-stage-note`)?.textContent || null;
      return {
        heads: cols.map(head),
        quotesOnBoard: document.getElementById('quotesSection').parentElement === kb,
        quoteCard: !!document.querySelector('#list-quote [data-id="ORD-q"]'),
        held: inCol('pending', 'ORD-h'), heldNote: note('ORD-h'),
        heldResume: !!document.querySelector('[data-order-id="ORD-h"] [data-act="status"][data-to="pending"]'),
        post: inCol('printing', 'ORD-pp'), postNote: note('ORD-pp'),
        qc: inCol('printing', 'ORD-qc'), qcNote: note('ORD-qc'),
        shipped: inCol('completed', 'ORD-s'), shippedNote: note('ORD-s'),
        anyNote: !!document.querySelector('.kanban .sm-stage-note'),
      };
    });
  };

  const fullEditor = async () => {
    await window.click('#tabbtn-clients-tab');
    await window.click('[data-act="cl-edit"][data-id="CLI-s4"]');
    await window.waitForSelector('#modalMount .modal');
    const r = await window.evaluate(() => ({
      simple: !!document.querySelector('#smCustName'),
      terms: !!document.querySelector('#cePaymentTerms'),
      fields: document.querySelectorAll('#modalMount .modal-body input:not([type=checkbox]):not([type=hidden])').length,
    }));
    await closeModal();
    return r;
  };

  const production = async () => {
    await openPane('production');
    return {
      x: await shown('#postChecklistItems .sm-pro-form'),
      remove: await shown('#postChecklistItems .sm-simple-only'),
      cfEdit: await shown('#customFieldsList [data-act="edit-custom-field"]'),
      cfDel: await shown('#customFieldsList [data-act="del-custom-field"]'),
      wip: await shown('#set_wip_pending'),
      qc: await shown('#set_qcEnabled'),
      lead: await shown('#set_leadFinishingDays'),
      envLog: await shown('#btnLogEnv'),
      checklist: await shown('#postCheckInput'),
      fields: await shown('#customFieldInput'),
    };
  };

  const library = async () => {
    await openPane('library');
    return {
      places: await shown('#plibPlacesCard'),
      root: await shown('#set_plibRoot'),
      mirror: await shown('#set_plibMirror'),
      s3: await shown('#set_plibS3On'),
      tier: await shown('#set_plibTierOn'),
      drive: await shown('#set_plibGDriveOn'),
      rows: await window.evaluate(() => [...document.querySelectorAll('#plibPlaces .sm-row')].map((r) => r.dataset.place + (r.querySelector('.sm-pill-in-use') ? ':in-use' : ''))),
    };
  };

  // ── Professional: the baseline ──
  const proBoard = await board();
  ok(proBoard.heads.length === 8 && !proBoard.quotesOnBoard && !proBoard.anyNote, `Professional: eight columns, quotes above the board (${proBoard.heads.join(' · ')})`);
  const proCust = await fullEditor();
  ok(!proCust.simple && proCust.terms, 'Professional: the customer editor is the full one');
  const proProd = await production();
  ok(proProd.x === true && proProd.remove === false && proProd.cfDel === true && proProd.cfEdit === false && proProd.wip && proProd.qc && proProd.lead,
    `Professional: Production as before (${JSON.stringify(proProd)})`);
  await openPane('printers');
  ok(await shown('#btnLogEnv') === true, 'Professional: the environment log is in Printers & Slicers');
  const proLib = await library();
  ok(proLib.places === false && proLib.root && proLib.mirror && proLib.s3 && proLib.tier && proLib.drive, `Professional: Library & Files as before (${JSON.stringify(proLib)})`);

  // ── Simple, by clicking it ──
  await clickMode('simple');
  ok(true, 'Settings › General › Simple was clicked');

  const b = await board();
  ok(JSON.stringify(b.heads) === JSON.stringify(['Quote', 'Queued', 'Printing', 'Ready']), `Simple: four columns, Quote · Queued · Printing · Ready (${b.heads.join(' · ')})`);
  ok(b.quotesOnBoard && b.quoteCard, 'Simple: the quote is a card in the Quote column');
  ok(b.held && /on hold/i.test(b.heldNote || '') && b.heldResume, `Simple: the job on hold is in Queued, says so, and can be resumed (${b.heldNote})`);
  ok(b.post && /post/i.test(b.postNote || ''), `Simple: the post-processing job is in Printing with a note (${b.postNote})`);
  ok(b.qc && /QC/.test(b.qcNote || ''), `Simple: the QC job is in Printing with a note (${b.qcNote})`);
  ok(b.shipped && /shipped/i.test(b.shippedNote || ''), `Simple: the shipped job is in Ready with a note (${b.shippedNote})`);

  // Card 6: the customer.
  await window.click('#tabbtn-clients-tab');
  await window.click('[data-act="cl-edit"][data-id="CLI-s4"]');
  await window.waitForSelector('#smCustName');
  const form = await window.evaluate(() => ({
    ids: [...document.querySelectorAll('#modalMount .modal-body input')].map((i) => i.id),
    name: document.getElementById('smCustName').value,
    address: document.getElementById('smCustAddress').value,
    pro: document.querySelector('#modalMount .sm-cust-pro')?.textContent || '',
    terms: !!document.querySelector('#cePaymentTerms, #ceCreditLimit, [data-f="vat"]'),
  }));
  ok(JSON.stringify(form.ids) === JSON.stringify(['smCustName', 'smCustPhone', 'smCustEmail', 'smCustAddress', 'smCustNotes']), `Simple: the customer is five fields (${form.ids.join(', ')})`);
  ok(form.name === 'Layla Design Studio' && form.address === 'Old Road' && !form.terms, 'Simple: they hold the name and first address; no business fields');
  ok(/Business details/.test(form.pro) && /Professional/.test(form.pro), `Simple: a line says the business details are in Professional (${form.pro.trim()})`);
  await window.click('#smCustAddress');
  await window.fill('#smCustAddress', 'Prince Sultan Road, Al Olaya, Riyadh');
  await window.click('#smCustPhone');
  await window.fill('#smCustPhone', '+966511111111');
  await window.click('#modalMount [data-act="save"]');
  await window.waitForFunction(() => !document.querySelector('#modalMount .modal'));
  const saved = await window.evaluate(() => JSON.parse(JSON.stringify(clients.find((c) => c.id === 'CLI-s4'))));
  ok(saved.phone === '+966511111111' && saved.addresses[0].address === 'Prince Sultan Road, Al Olaya, Riyadh' && saved.addresses[0].label === 'Studio',
    'Simple: saving writes the phone and the first address');
  ok(saved.cr === '1010101010' && saved.vat === '300000000000003' && saved.paymentTermsDays === 30 && saved.creditLimit === 5000
    && saved.nameAr === 'استوديو ليلى' && saved.addresses[1].address === 'Al Malqa' && saved.priceList.length === 1,
    'Simple: what it does not show is kept (CR, VAT, terms, credit limit, Arabic name, second address, price list)');

  await window.click('#btnAddClient');
  await window.waitForSelector('#smCustName');
  await window.click('#smCustName');
  await window.fill('#smCustName', 'Sample Maker');
  await window.click('#smCustAddress');
  await window.fill('#smCustAddress', 'King Fahd Road');
  await window.click('#modalMount [data-act="save"]');
  await window.waitForFunction(() => !document.querySelector('#modalMount .modal'));
  const added = await window.evaluate(() => clients.find((c) => c.nameEn === 'Sample Maker'));
  ok(added && added.addresses.length === 1 && added.addresses[0].address === 'King Fahd Road', 'Simple: a new customer is added from the five fields');

  // Card 7: production.
  const p = await production();
  ok(p.checklist && p.fields && p.remove === true && p.x === false && p.cfEdit === true && p.cfDel === false, `Simple: the checklist (Remove) and custom fields (Edit) (${JSON.stringify(p)})`);
  ok(p.wip === false && p.qc === false && p.lead === false, 'Simple: WIP limits, QC and delivery estimates are not drawn');
  await window.click('#postChecklistItems [data-idx="1"].sm-simple-only');
  ok(await window.evaluate(() => settings.postChecklist.map((c) => c.label).join('|')) === 'Remove supports', 'Simple: Remove takes a step off the checklist');
  await window.click('#customFieldsList [data-act="edit-custom-field"]');
  await window.waitForSelector('#smCfLabel');
  await window.fill('#smCfLabel', 'Engraving text');
  await window.click('#modalMount [data-act="save"]');
  await window.waitForFunction(() => !document.querySelector('#modalMount .modal'));
  const cf = await window.evaluate(() => settings.customFields[0]);
  ok(cf.label === 'Engraving text' && cf.id === 'CF-1' && cf.type === 'text', 'Simple: Edit renames a custom field and keeps its id and type');
  await openPane('printers');
  ok(await shown('#btnLogEnv') === false, 'Simple: the environment log is not drawn');

  // Card 8: library storage.
  const l = await library();
  ok(l.places === true && l.root === false && l.mirror === false && l.s3 === false && l.tier === false && l.drive === false,
    `Simple: the three places, no S3, tiering, backup copy or Drive form (${JSON.stringify(l)})`);
  ok(JSON.stringify(l.rows) === JSON.stringify(['computer:in-use', 'folder', 'drive', 'bucket']), `Simple: this computer is in use; the bucket is listed (${l.rows.join(', ')})`);
  ok(/Set up in Professional/.test(await window.evaluate(() => document.querySelector('#plibPlaces [data-place="bucket"]').innerText)), 'Simple: the bucket says "Set up in Professional"');
  await window.click('#plibPlaces [data-act="sm-lib-drive"]');
  ok(await shown('#set_plibGDClientId') === true, 'Simple: Connect… opens the Google Drive set-up');

  // ── Back to Professional, by clicking it ──
  await clickMode('professional');
  const proBoard2 = await board();
  ok(JSON.stringify(proBoard2) === JSON.stringify(proBoard), 'Professional again: the board is the eight columns it was');
  ok(JSON.stringify(await fullEditor()) === JSON.stringify(proCust), 'Professional again: the full customer editor');
  const proProd2 = await production();
  ok(proProd2.x && !proProd2.remove && proProd2.cfDel && !proProd2.cfEdit && proProd2.wip && proProd2.qc && proProd2.lead, 'Professional again: Production as before');
  const proLib2 = await library();
  ok(!proLib2.places && proLib2.root && proLib2.mirror && proLib2.s3 && proLib2.tier && proLib2.drive, 'Professional again: Library & Files as before');

  console.log('e2e-simple-screens: ok');
} catch (err) {
  failed = true;
  console.error('e2e-simple-screens FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
