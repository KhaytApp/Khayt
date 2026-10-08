/**
 * Application boot: setup wizard and DOMContentLoaded initialization.
 */

// Uncaught errors and dead promises are handled in error-report.js, which is
// loaded first so that boot itself is covered. See the comment there.

function detectSystemLang() {
  const raw = (navigator.language || 'en').toLowerCase();
  const map = { en: 'en', ar: 'ar', de: 'de', es: 'es', fr: 'fr', zh: 'zh', ja: 'ja' };
  const base = raw.split('-')[0];
  return map[base] || 'en';
}

/* ============================================================
   Setup wizard (Business Mode first-run)
   ============================================================ */
function shouldShowSetupWizard() {
  if (settings.firstRunDone) return false;
  if (settings.firstRun === false) return false;
  return true;
}

/** One-time fix: shops with data but wizard flags never persisted (import / upgrade). */
function normalizeWizardFlagsAfterLoad() {
  if (settings.firstRunDone) {
    if (settings.firstRun) {
      settings.firstRun = false;
      saveAll();
    }
    return;
  }
  // Real user activity = orders, clients, or machines. Inventory is intentionally
  // seeded with a few starter filaments on a fresh install, so it must NOT count
  // here — otherwise a brand-new shop looks "existing" and the onboarding wizard
  // is wrongly skipped for first-time users.
  const hasShopData =
    printLog.length > 0 ||
    clients.length > 0 ||
    machines.length > 0;
  if (hasShopData) {
    settings.firstRun = false;
    settings.firstRunDone = true;
    saveAll();
  }
}

function initWizard() {
  if (!shouldShowSetupWizard()) return;

  // Bed Ready is a solo maker app with sane defaults (enthusiast/commerce-free
  // mode, "Bed Ready" identity, one look). There's nothing to onboard, so skip
  // the wizard entirely — detect the system language for a good first start,
  // mark first-run done, and drop straight into the app.
  const IS_BR = (typeof document !== 'undefined' && document.documentElement.dataset.app === 'bedready');
  if (IS_BR) {
    // This runs only on a genuine first launch (shouldShowSetupWizard gate), so
    // there's no user-chosen language yet — match the OS locale for a good start.
    // (settings.lang defaults to 'en', so we must detect unconditionally here, not
    // fall back with `settings.lang || …`, which would always pick 'en'.)
    const lang = detectSystemLang();
    settings.lang = lang;
    try { i18n.set(lang, { silent: true }); } catch (e) { /* non-fatal */ }
    settings.firstRun = false;
    settings.firstRunDone = true;
    saveAll();
    return;
  }

  const wiz = $('#setup-wizard');
  if (!wiz) return;
  wiz.style.display = 'flex';

  // (Bed Ready returned above — the wizard below only runs for Khayt.)
  let selectedMode = 'simple';
  let selectedBizType = 'solo';
  let selectedDesign = settings.designTheme || 'workbench';
  let pendingPin = null;
  let pendingRecoveryCode = null;
  let securitySkipped = true;

  const langSel = $('#wizLang');
  if (langSel) {
    langSel.value = settings.lang || detectSystemLang();
    i18n.set(langSel.value, { silent: true });
  }
  i18n.applyToDom(wiz);

  function goToStep(n) {
    wiz.querySelectorAll('.wizard-step').forEach(s => s.style.display = 'none');
    const step = $(`#wiz-step-${n}`);
    if (step) step.style.display = '';
    wiz.querySelectorAll('.wizard-dot').forEach(d => {
      d.classList.toggle('active', parseInt(d.dataset.step, 10) <= n);
    });
    if (n === 2) {
      globalThis.KhaytThemePicker?.mountWizardPicker?.(
        $('#wizDesignThemePicker'),
        selectedDesign,
      );
    }
  }

  const wizEscHandler = (e) => {
    if (e.key !== 'Escape' || wiz.style.display === 'none') return;
    if (_escHandlerStack?.length) return;
    e.preventDefault();
    confirmModal(t('wiz.skip_confirm') || 'Skip setup and use defaults? You can finish this later in Settings.', {
      okText: t('wiz.skip_ok') || 'Skip for now',
      cancelText: t('common.cancel'),
    }).then((ok) => { if (ok) finishWizard(); });
  };
  document.addEventListener('keydown', wizEscHandler);

  wiz.addEventListener('click', e => {
    const backBtn = e.target.closest('[data-prev]');
    const nextBtn = e.target.closest('[data-next]');
    const finishBtn = e.target.closest('#wizFinish');

    if (backBtn) {
      goToStep(parseInt(backBtn.dataset.prev, 10));
      return;
    }

    if (nextBtn && nextBtn.id !== 'wizRecoveryContinue') {
      const step = parseInt(nextBtn.dataset.next, 10);
      // Business-type options auto-advance via data-next; capture the chosen mode
      // here because this branch runs before any .wizard-option handling.
      if (nextBtn.classList.contains('wizard-option') && nextBtn.dataset.mode) {
        wiz.querySelectorAll('.wizard-option').forEach(o => o.classList.remove('selected'));
        nextBtn.classList.add('selected');
        selectedMode = nextBtn.dataset.mode;
        selectedBizType = nextBtn.dataset.bizType || selectedMode;
      }
      // Persist the chosen language when leaving the language step — keyed on the
      // source step (not the destination) so it fires whether the next step is 2
      // (Khayt) or 3 (Bed Ready, which skips the design step).
      if (nextBtn.closest('#wiz-step-1')) {
        const lang = $('#wizLang')?.value || 'en';
        settings.lang = lang;
        i18n.set(lang);
        i18n.applyToDom(wiz);
        // ZATCA is Saudi e-invoicing, and its box ships ticked in the markup —
        // so a shop anywhere in the world sailed past it and started issuing
        // invoices stamped "ZATCA Phase 1 compliant" with a TLV QR code, to
        // customers who have never heard of the authority. Now that the same
        // flag also forces documents bilingual, leaving it on by default would
        // silently defeat the language fix as well. Tick it for an Arabic setup
        // and leave it to the owner otherwise — it stays visible either way,
        // because a Gulf shop may well work in English.
        const zEl = $('#wizEnableZatca');
        if (zEl) zEl.checked = KhaytInvoiceLanguage.zatcaDefaultFor(lang);
      }
      if (nextBtn.closest('#wiz-step-2')) {
        const picker = $('#wizDesignThemePicker');
        selectedDesign = globalThis.KhaytThemePicker?.getWizardSelection?.(picker) || selectedDesign;
        settings.designTheme = selectedDesign;
        const theme = globalThis.KhaytThemeRegistry?.getTheme(selectedDesign);
        if (theme?.defaultAppearance) {
          settings.theme = theme.defaultAppearance;
          if (typeof applyTheme === 'function') applyTheme(theme.defaultAppearance);
        }
        if (typeof applyDesignSettings === 'function') applyDesignSettings();
      }
      goToStep(step);
      return;
    }

    if (finishBtn) finishWizard();
  });

  $('#wizSecuritySkip')?.addEventListener('click', () => {
    pendingPin = null;
    pendingRecoveryCode = null;
    securitySkipped = true;
    goToStep(IS_BR ? 5 : 4);   // Bed Ready skips the business-type step
  });

  $('#wizSecurityContinue')?.addEventListener('click', () => {
    const errEl = $('#wizPinError');
    const pin = ($('#wizPin')?.value || '').trim();
    const confirm = ($('#wizPinConfirm')?.value || '').trim();
    if (!isValidPin(pin)) {
      if (errEl) errEl.textContent = t('sec.pin_invalid_format');
      return;
    }
    if (isWeakPin(pin)) {
      if (errEl) errEl.textContent = t('sec.pin_weak');
      return;
    }
    if (pin !== confirm) {
      if (errEl) errEl.textContent = t('sec.pin_mismatch');
      return;
    }
    if (errEl) errEl.textContent = '';
    pendingPin = pin;
    pendingRecoveryCode = generateRecoveryCode();
    securitySkipped = false;
    $('#wizSecuritySetup').style.display = 'none';
    $('#wizSecurityRecovery').style.display = '';
    const codeEl = $('#wizRecoveryCode');
    if (codeEl) codeEl.textContent = formatRecoveryCode(pendingRecoveryCode);
    const savedCb = $('#wizRecoverySaved');
    const contBtn = $('#wizRecoveryContinue');
    if (savedCb) savedCb.checked = false;
    if (contBtn) contBtn.disabled = true;
    i18n.applyToDom($('#wizSecurityRecovery'));
  });

  $('#wizRecoverySaved')?.addEventListener('change', e => {
    const contBtn = $('#wizRecoveryContinue');
    if (contBtn) contBtn.disabled = !e.target.checked;
  });

  $('#wizRecoveryContinue')?.addEventListener('click', () => {
    if (!$('#wizRecoverySaved')?.checked) return;
    goToStep(IS_BR ? 5 : 4);   // Bed Ready skips the business-type step
  });

  $('#wizRecoveryCopy')?.addEventListener('click', async () => {
    if (!pendingRecoveryCode) return;
    const res = await copyRecoveryCode(pendingRecoveryCode);
    toast(res.ok ? t('sec.copied') : t('sec.copy_failed'), res.ok ? 'success' : 'error');
  });

  $('#wizRecoveryDownload')?.addEventListener('click', async () => {
    if (!pendingRecoveryCode) return;
    const res = await downloadRecoveryCode(pendingRecoveryCode);
    toast(res.ok ? t('sec.downloaded') : t('sec.download_failed'), res.ok ? 'success' : 'error');
  });

  async function finishWizard() {
    const bizName = $('#wizBizName')?.value.trim();
    const currency = $('#wizCurrency')?.value;

    if (bizName) {
      settings.businessName = bizName;
      // Into the shop's FIRST content language, not English: a shop that set
      // itself up in Arabic had its name written to a field it never sees.
      KhaytContentLanguages.write(settings, 'biz',
        KhaytContentLanguages.contentLangs(settings)[0], bizName);
    }
    settings.currency = currency;
    settings.mode = selectedMode;
    settings.businessType = selectedBizType;
    // First printer (optional) — gives the queue + calculator a machine to use.
    const machName = $('#wizMachine')?.value.trim();
    if (machName && Array.isArray(machines) && machines.length === 0) {
      const palette = (typeof MACHINE_COLORS !== 'undefined' && MACHINE_COLORS.length) ? MACHINE_COLORS : ['#5b9cf0'];
      machines.push({ id: uid('MACH'), name: machName, color: palette[0] });
    }
    settings.designTheme = selectedDesign || settings.designTheme || 'studio';
    const finishTheme = globalThis.KhaytThemeRegistry?.getTheme(settings.designTheme);
    if (finishTheme?.defaultAppearance) settings.theme = finishTheme.defaultAppearance;
    else if (!settings.theme) settings.theme = 'light';
    if (selectedBizType === 'farm') {
      const w = { ...(settings.wipLimits || {}) };
      if (!w.printing) {
        settings.wipLimits = { pending: 30, printing: 6, post: 8, qc: 4, ...w };
      }
      if (locations.length === 1) {
        locations.push({ id: uid('LOC'), name: t('farm.second_site') || 'Site 2', address: '' });
      }
    }
    settings.enableZatca = $('#wizEnableZatca')?.checked !== false;
    const enableOnline = $('#wizEnableOnline')?.checked === true;
    settings.onlineEnabled = enableOnline;
    if (enableOnline && typeof applyOnlineLanPrefs === 'function') {
      settings.lanApi = applyOnlineLanPrefs(settings.lanApi, true);
    }
    // Enthusiast (hobbyist) mode has no commerce — force business toggles off.
    if (selectedMode === 'enthusiast') {
      settings.enableZatca = false;
      settings.onlineEnabled = false;
    }

    if (!securitySkipped && pendingPin && pendingRecoveryCode) {
      await setupAdminSecurity({ pin: pendingPin, recoveryCodePlain: pendingRecoveryCode });
      const admin = getAdminOperator();
      if (admin && bizName) admin.name = bizName;
    } else {
      settings.securityEnabled = false;
      settings.recoveryCodeHash = '';
      settings.operatorLockEnabled = false;
      operators = [];
      settings.activeOperatorId = null;
    }

    settings.firstRun = false;
    settings.firstRunDone = true;
    await flushSave();

    document.removeEventListener('keydown', wizEscHandler);
    wiz.style.display = 'none';
    applyTheme(settings.theme);
    if (typeof applyDesignSettings === 'function') applyDesignSettings();
    applyMode();
    loadSettingsIntoForm();
    if (enableOnline && typeof startLanServer === 'function') {
      startLanServer().catch(() => {});
    }
    applyOperatorPermissions();
    initialRender();
    refreshCurrencyLabels();
    toast(t('wiz.welcome_done'), 'success', 4000);
    // Kick off the guided tour for first-time owners.
    if (typeof startTour === 'function') setTimeout(startTour, 800);
  }

  goToStep(1);
}

/* ============================================================
   Boot
   ============================================================ */
if (typeof document !== 'undefined') {
/**
 * The main process changed ONE job on disk (a printer's move, a customer's survey): take that
 * job from the book and copy it into the object the window already holds. A whole-book reload
 * swapped every record for a new object, so an open editor saved into a copy nothing used.
 * A save still waiting out saveAll's 300 ms debounce is written FIRST — otherwise the read-back
 * would replace an edit made a moment ago to that very job.
 */
async function mergeOrderFromDisk(id) {
  if (typeof flushSave === 'function') await flushSave();
  const store = await window.hubAPI.loadStore();
  const fresh = store && !store.__corrupt && (store.printLog || []).find((o) => o && o.id === id);
  if (!fresh) return;
  const mine = printLog.find((o) => o && o.id === id);
  if (mine) {
    for (const k of Object.keys(mine)) if (!(k in fresh)) delete mine[k];
    Object.assign(mine, fresh);
  } else {
    printLog.unshift(fresh);
  }
}

document.addEventListener('DOMContentLoaded', async () => {
  await loadAll();
  pruneExpiredNotifs();

  restoreActiveLocationFromSession?.();
  normalizeWizardFlagsAfterLoad();
  if (!settings.firstRunDone && (printLog.length > 0 || clients.length > 0)) {
    settings.mode = settings.mode || 'professional';
  }

  applyTheme(settings.theme || 'light');
  if (typeof KhaytCustomThemes?.loadCustomThemes === 'function') {
    await KhaytCustomThemes.loadCustomThemes();
  }
  if (typeof applyDesignSettings === 'function') applyDesignSettings();
  applyMode();
  i18n.init();
  if (settings.lang) i18n.set(settings.lang, { silent: true });
  const langSel = $('#langSelect');
  if (langSel) langSel.value = i18n.current;

  wireEvents();
  loadSettingsIntoForm();
  // The calculator opens on the shop's own electricity price, not Khayt's 0.18.
  if (typeof seedCalcElecRate === 'function') seedCalcElecRate(0.18);
  refreshCurrencyLabels();
  initialRender();
  if (typeof wireFormLabels === 'function') wireFormLabels(); // a11y: associate static form labels
  updateNotifBadge();
  applyProductionPause();
  // Feature 7 (new 8-pack): Apply operator permissions at startup
  applyOperatorPermissions();
  // Show/hide the nav operator switch button
  const navOpBtn = $('#btnNavSwitchOp');
  if (navOpBtn) navOpBtn.style.display = settings.operatorLockEnabled ? 'inline-flex' : 'none';

  initAppShell();

  // Feature 2 (new batch): Start live printer polling for connected machines
  const apiMachines = machines.filter(m => m.printerApi?.type && m.printerApi.type !== 'none');
  if (apiMachines.length > 0 && window.hubAPI?.startPrinterPolling) {
    window.hubAPI.startPrinterPolling(apiMachines).then(cache => {
      machineStatusCache = cache || {};
      updateKanbanLiveStatus();
      if (typeof updateDashLivePrinters === 'function') updateDashLivePrinters();
      // The machines page reads the same poll. It had no live state at all, so a
      // printer mid-job showed only its (order-derived) job count — which is zero
      // for anything sent to the printer outside Khayt.
      if (typeof updateMachinesLiveStatus === 'function') updateMachinesLiveStatus();
      // Seed the alert baseline from the first poll; don't alert on initial state.
      if (typeof dispatchPrinterAlerts === 'function') dispatchPrinterAlerts(machineStatusCache);
    }).catch(() => {});
  }
  if (window.hubAPI?.onPrinterStatusUpdate) {
    window.hubAPI.onPrinterStatusUpdate(data => {
      machineStatusCache = data || {};
      updateKanbanLiveStatus();
      if (typeof updateDashLivePrinters === 'function') updateDashLivePrinters();
      if (typeof updateMachinesLiveStatus === 'function') updateMachinesLiveStatus();
      if (typeof dispatchPrinterAlerts === 'function') dispatchPrinterAlerts(machineStatusCache);
    });
  }

  let currentVersion = '2.0.16';
  if (window.hubAPI?.appVersion) {
    try { currentVersion = await window.hubAPI.appVersion(); }
    catch (_) {}
  }
  if ($('#appVersion')) $('#appVersion').textContent = currentVersion || '2.0.16 (dev)';
  const betaBadge = $('#appVersionBeta');
  if (betaBadge) betaBadge.hidden = !/-beta/i.test(String(currentVersion || ''));

  // ── Post-update "data survived" toast ────────────────────────────────────────
  // If the previous session stored a pending-update version and we're now running
  // that version (or any newer one), show a brief confirmation.
  (function checkPostUpdateNotice() {
    const pendingVer = localStorage.getItem('khayt_pending_update_to');
    if (!pendingVer) return;
    // Strip only the pre-release suffix ('2.1.0-beta.1' → '2.1.0') before comparing.
    // Don't use a regex that removes hyphens mid-string — that collapses '2.0.4-beta.1'
    // to '2.0.41' and confuses the comparator.
    const norm = v => (v || '').split('-')[0].split('.').map(n => parseInt(n, 10) || 0);
    const gte = (a, b) => {
      const [aa, ba] = [norm(a), norm(b)];
      const len = Math.max(aa.length, ba.length);
      for (let i = 0; i < len; i++) {
        if ((aa[i] || 0) > (ba[i] || 0)) return true;
        if ((aa[i] || 0) < (ba[i] || 0)) return false;
      }
      return true; // equal
    };
    // Extra guard: if currentVersion still carries a pre-release tag (e.g. '-beta.1')
    // the stable release hasn't landed yet — suppress the toast.
    const isStable = !String(currentVersion).includes('-');
    if (isStable && gte(currentVersion, pendingVer)) {
      localStorage.removeItem('khayt_pending_update_to');
      setTimeout(() => {
        const brand = (typeof document !== 'undefined' && document.documentElement.dataset.app === 'bedready') ? 'Bed Ready' : 'Khayt';
        toast(
          `✅ Updated to ${brand} ${currentVersion} — your data is intact. ` +
          'A pre-update backup was saved to Settings → Backup.',
          'success', 7000
        );
      }, 2500); // slight delay so the UI is fully painted first
    }
  })();

  // ── Auto-updater UI (changelog review before download/install) ─────
  // Push the saved beta-channel preference to main before the startup check,
  // so opted-in testers are offered beta builds on the launch auto-check.
  if (typeof settings !== 'undefined') {
    window.hubAPI?.setUpdateOptions?.({ allowBeta: !!settings.betaUpdates });
  }
  wireUpdateUI({ getCurrentVersion: () => currentVersion });

  // ── Manual "Check for updates" button in Settings ────────────────────────
  (function wireCheckForUpdatesBtn() {
    const btn = document.getElementById('btnCheckForUpdates');
    const msg = document.getElementById('updateStatusMsg');
    if (!btn || !window.hubAPI?.checkForUpdates) return;

    btn.addEventListener('click', async () => {
      btn.disabled = true;
      btn.textContent = 'Checking…';
      if (msg) msg.textContent = '';
      try {
        const res = await window.hubAPI.checkForUpdates();
        await handleManualUpdateCheckResult(res, { currentVersion, statusEl: msg });
      } catch (e) {
        if (msg) msg.textContent = '⚠ Check failed';
      } finally {
        btn.disabled = false;
        btn.textContent = t('set.check_updates') || 'Check for updates';
      }
    });
  })();

  // Email digest scheduler — checks every 5 minutes
  setInterval(checkAndSendDigest, 5 * 60 * 1000);
  setTimeout(checkAndSendDigest, 10_000); // also run ~10s after boot in case we're already in the send window

  // Daily auto-backup (silent) + populate last-backup label
  maybeAutoBackup();
  updateLastBackupDisplay();

  // Opt-in: auto-draft purchase orders for items at their reorder point.
  if (typeof maybeAutoDraftPurchaseOrders === 'function') { try { maybeAutoDraftPurchaseOrders(); } catch (e) { console.warn('auto-draft PO:', e); } }

  // Inject contextual coach tips on tagged inputs (respects settings.coachTips).
  if (typeof applyCoachTips === 'function') { try { applyCoachTips(document); } catch (e) { /* non-fatal */ } }

  // When connectivity returns, immediately flush any changes stranded offline
  // (resets the sync backoff). No-op when cloud sync is off.
  window.addEventListener('online', () => {
    try { if (window.KhaytCloudSync?.isOn()) KhaytCloudSync.flush(); } catch (e) { /* non-fatal */ }
  });

  // iOS companion: react to spools/orders changed via LAN API from phone
  // Quit handshake: persist the debounced save before the app exits. Without this, any
  // edit made within saveAll()'s ~300ms debounce of Cmd+Q or a window close was lost.
  if (window.hubAPI?.onFlushSaveRequest) {
    window.hubAPI.onFlushSaveRequest(() => {
      Promise.resolve()
        .then(() => flushSave())
        .catch((e) => console.error('flushSave on quit failed:', e))
        .finally(() => { try { window.hubAPI.flushSaveDone(); } catch (_) { /* quitting anyway */ } });
    });
  }
  // Backstop for paths that bypass before-quit (e.g. a reload or an OS-level close).
  window.addEventListener('pagehide', () => { try { flushSave(); } catch (_) { /* best effort */ } });

  if (window.hubAPI?.onLanSpoolAdded) {
    window.hubAPI.onLanSpoolAdded(spool => {
      // Phone added a spool — patch in-memory state and persist so next saveAll() doesn't clobber it
      if (spool && spool.id && !inventory.find(s => s.id === spool.id)) {
        inventory.push(spool);
        saveAll(); // keep in-memory and on-disk in sync before any UI save can overwrite
        renderInventory();
        toast('📱 ' + t('inv.spool_added_phone', { name: ((spool.brand || '') + ' ' + (spool.material || '')).trim() || spool.id }), 'success', 4000);
      }
    });
  }
  if (window.hubAPI?.onLanExpenseAdded) {
    window.hubAPI.onLanExpenseAdded((payload) => {
      // Phone photographed a receipt. The server has written both the image and
      // the store; patch in-memory state and re-save so an open desktop cannot
      // clobber it, exactly as onLanSpoolAdded does.
      const entry = payload && payload.entry;
      if (!entry || !entry.id) return;
      if (typeof expenses === 'undefined' || expenses.find((x) => x && x.id === entry.id)) return;
      expenses.unshift(entry);
      saveAll();
      if (typeof renderExpenses === 'function') renderExpenses();
      if (typeof toast === 'function') {
        toast('📱 ' + (t('exp.added_phone', { amount: fmtMoney(entry.amount) })
          || `Expense added from your phone: ${fmtMoney(entry.amount)}`), 'success');
      }
    });
  }
  if (window.hubAPI?.onLanWasteLogged) {
    window.hubAPI.onLanWasteLogged((payload) => {
      // Phone logged a failed print. The server has already written it to disk;
      // patch in-memory state and re-save so the next saveAll() from an open
      // desktop cannot clobber it — the same reason onLanSpoolAdded does.
      const entry = payload && payload.entry;
      if (!entry || !entry.id) return;
      if (typeof wasteLog === 'undefined' || wasteLog.find((w) => w && w.id === entry.id)) return;
      wasteLog.unshift(entry);
      // The server may also have deducted the grams from a spool; mirror that
      // here or the two views disagree until the next reload.
      const d = payload.deducted;
      if (d && d.id && typeof inventory !== 'undefined') {
        const spool = inventory.find((s) => s && s.id === d.id);
        if (spool) spool.weight = d.weight;
      }
      saveAll();
      if (typeof renderWasteLog === 'function') renderWasteLog();
      if (typeof renderInventory === 'function' && document.querySelector('#inventory-tab.active')) renderInventory();
      if (typeof toast === 'function') {
        toast('📱 ' + (t('waste.logged_phone', { material: entry.material }) || `Waste logged from your phone: ${entry.material}`), 'success');
      }
    });
  }
  if (window.hubAPI?.onLanOrderUpdated) {
    window.hubAPI.onLanOrderUpdated((payload) => {
      const { id, status } = payload;
      const idx = printLog.findIndex(o => o.id === id);
      if (idx !== -1) {
        printLog[idx].status = status;
        if (payload.clientApprovedAt) printLog[idx].clientApprovedAt = payload.clientApprovedAt;
        if (payload.quoteAcceptedAt) printLog[idx].quoteAcceptedAt = payload.quoteAcceptedAt;
        if (payload.quoteApproved) {
          const order = printLog[idx];
          if (!order.invoiceNum) {
            order.invoiceNum = nextInvoiceNumber();
            order.invoiceNumber = order.invoiceNum;
          }
          fireWebhook('quote_approved', { orderId: id, project: order.project, client: order.client });
        }
        if (!printLog[idx].statusHistory) printLog[idx].statusHistory = [];
        printLog[idx].statusHistory.push({ status, at: new Date().toISOString() });
        if (printLog[idx].statusHistory.length > 200) printLog[idx].statusHistory = printLog[idx].statusHistory.slice(-200);
        saveAll();
        renderLogs();
        renderKanban();
        renderDashboard();
        if (payload.quoteApproved) {
          toast('✅ ' + t('ord.client_quote_approved', { id }), 'success', 4000);
        } else {
          toast('📱 ' + t('ord.status_updated_phone', { id, status }), 'info', 3000);
        }
      } else if (id && payload.project && isValidOrder(payload)) {
        // New order from Salla/Zid (or other source): add to printLog, with any
        // missing date/status read as "" like every other job.
        printLog.unshift({ ...KhaytStoreValidate.normalizeOrder(payload) });
        saveAll();
        renderLogs();
        renderKanban();
        const src = payload.source === 'zid' ? t('zidOrderReceived') : t('sallaOrderReceived');
        toast('🛒 ' + (src || 'New order received'), 'success', 4000);
      }
    });
  }
  if (window.hubAPI?.onLanSurveySubmitted) {
    window.hubAPI.onLanSurveySubmitted(async ({ orderId, rating }) => {
      // Only the rated job, copied into the object the window holds — as for a printer's
      // move below: a whole-book reload left any open editor saving into a detached copy.
      try { await mergeOrderFromDisk(orderId); } catch (e) {
        console.error('reload job after survey:', e);
      }
      const o = printLog.find(x => x.id === orderId);
      if (o) {
        toast(`⭐ Survey received for "${o.project || orderId}": ${rating}/5`, 'success', 5000);
      }
    });
  }
  if (window.hubAPI?.onLanStartFailed) {
    window.hubAPI.onLanStartFailed(() => {
      settings.lanApi = { ...settings.lanApi, enabled: false };
      reconcileLanServerStatus?.();
      toast(t('lan.start_failed') || 'LAN server failed to start — port may be in use', 'warning', 6000);
    });
  }
  // The main process has ALREADY written the move, through the status rule:
  // the start time, the timer, the history entry. So read the book back, as the
  // survey handler above does. This used to set the status on the window's own
  // copy — which had none of those — push a second history entry, and save,
  // which wrote the stale copy over the main process's write: a job a printer
  // started lost its start time again the moment the window heard about it.
  //
  // Only THAT job is taken from the book, and it is copied INTO the object the
  // window already holds. Replacing the whole store swapped every record for a
  // new object, so an editor open on any job (notes, a discount) saved into an
  // object nothing pointed at any more — "Saved", and the edit was gone. The
  // printer's move writes this one job and nothing else (lib/lan-server.js).
  window.hubAPI?.onLanKanbanAdvanced?.(async ({ id, from, to, project }) => {
    try { await mergeOrderFromDisk(id); } catch (e) {
      console.error('reload job after printer move:', e);
    }
    renderKanban();
    renderLogs();
    toast(`🖨️ ${project || id}: ${from} → ${to}`, 'success');
  });
  window.hubAPI?.onTunnelStatusChanged?.(({ active, url, error }) => {
    const tRow = document.getElementById('tunnelStatusRow');
    if (!active) {
      if (tRow) tRow.textContent = error ? `❌ ${error}` : '⚫ Tunnel inactive';
    } else if (url && tRow) {
      tRow.innerHTML = `🟢 Active at <a href="#" class="lan-url-link" data-url="${escapeHtml(url)}" style="color:var(--primary)">${escapeHtml(url)}</a>`;
      tRow.querySelectorAll('.lan-url-link').forEach(a => { a.addEventListener('click', e => { e.preventDefault(); window.hubAPI?.openExternal?.(a.dataset.url); }); });
      updateWebhookUrlDisplay(url);
    }
  });

  // LAN intake form submission → add to waiting list and refresh
  // Resume any webhook retries left pending by a previous run (durable retry queue).
  try { if (typeof resumePendingWebhooks === 'function') resumePendingWebhooks(); } catch (e) { console.error('resumePendingWebhooks:', e); }
  try { if (typeof retryFailedAccountingPushes === 'function') retryFailedAccountingPushes(); } catch (e) { console.error('retryFailedAccountingPushes:', e); }

  window.hubAPI?.onLanIntakeSubmitted?.((entry) => {
    if (!entry?.id) return;
    if (waitingList.some(w => w.id === entry.id)) {
      renderWaitingList();
      updateWaitingBadge();
      toast(t('intakeFormSubmitted'), 'success');
      return;
    }
    const draft = {
      id: entry.id,
      project: entry.project || (entry.description ? entry.description.slice(0, 80) : null) || t('waiting.untitled'),
      clientName: entry.clientName || entry.name || '',
      notes: entry.notes || entry.description || '',
      email: entry.email,
      phone: entry.phone,
      material: entry.material,
      budget: entry.budget,
      referenceLink: entry.referenceLink,
      priority: entry.priority || 'normal',
      status: entry.status || 'active',
      source: entry.source || 'intake_form',
      estValue: entry.estValue || 0,
      reminderDate: entry.reminderDate || entry.deadline || entry.dueDate || null,
      createdAt: entry.submittedAt || entry.createdAt || new Date().toISOString(),
      // PDPL: carry the customer's recorded consent through verbatim — it is the
      // auditable proof of lawful basis for this submission and must not be rebuilt.
      consent: entry.consent || null,
      // The price we showed this customer, and — the part that matters — whether
      // it came off their slicer or off a guess about the shape of their model.
      // This draft is rebuilt field by field, so anything not named here is
      // dropped: without this line the shop inherits estValue with no way to
      // tell a measurement from an estimate.
      modelQuote: entry.modelQuote || undefined,
    };
    Object.keys(draft).forEach(k => draft[k] === undefined && delete draft[k]);
    waitingList.unshift(draft);
    saveAll();
    renderWaitingList();
    updateWaitingBadge();
    toast(t('intakeFormSubmitted'), 'success');
  });

  window.hubAPI?.encryptionAvailable?.().then((enc) => {
    if (enc && enc.ok === true && enc.available === false) {
      toast(t('security.no_keychain') || 'OS secure storage is unavailable — secrets may be stored unencrypted on disk.', 'warning', 10000);
    }
  }).catch(() => {});

  // Round 12: Start LAN API server if enabled
  if (settings.lanApi?.enabled) {
    startLanServer().then(async () => {
      await reconcileLanServerStatus?.();
      if (settings.lanApi?.tunnelEnabled) {
        await startTunnelFromSettings?.({ confirm: false });
      }
    }).catch(e => {
      console.error('LAN server failed to start:', e);
      settings.lanApi = { ...settings.lanApi, enabled: false };
      toast(t('lan.start_failed') || 'LAN server failed to start — port may be in use', 'warning', 6000);
    });
  }

  // Business Mode setup wizard (new first-run experience)
  initWizard();

  // Global search keyboard shortcut ⌘K / Ctrl+K, plus tab-nav shortcuts
  //
  // This map IS the handler — it used to be a switch statement, which meant the
  // shortcuts existed in two places (the switch, and the help modal that listed
  // them) and could drift apart silently. paintShortcutHints() reads the same
  // object, so a key can never be advertised on a screen that does not honour it.
  document.addEventListener('keydown', (e) => {
    // isGlobalSearchOpen() rather than the bare identifier: globalSearchOpen lives inside
    // shell.js's IIFE and is not visible here, so this handler threw on every keystroke.
    const searchOpen = (typeof KhaytShell !== 'undefined' && KhaytShell.isGlobalSearchOpen)
      ? KhaytShell.isGlobalSearchOpen() : false;
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault();
      searchOpen ? closeGlobalSearch() : openGlobalSearch();
      return;
    }
    if (searchOpen && typeof handleGlobalSearchKeydown === 'function' && handleGlobalSearchKeydown(e)) {
      return;
    }
    if (e.key === 'Escape' && searchOpen) {
      closeGlobalSearch();
      return;
    }
    // Single-key navigation shortcuts — only when no input/modal is focused
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.shiftKey && e.key !== '?') return;
    const tag = (document.activeElement?.tagName || '').toLowerCase();
    if (tag === 'input' || tag === 'textarea' || tag === 'select') return;
    if (document.querySelector('.modal-backdrop')) return; // modal open
    if (e.key === '?') { openHelpModal(); return; }
    const shortcutTab = TAB_SHORTCUTS[e.key.toLowerCase()];
    if (shortcutTab) switchTab(shortcutTab);
  });

  paintShortcutHints();

  const gsOverlay = $('#globalSearchOverlay');
  if (gsOverlay) {
    gsOverlay.addEventListener('click', (e) => {
      if (e.target === gsOverlay) closeGlobalSearch();
    });
    const gsInput = $('#globalSearchInput');
    if (gsInput) gsInput.addEventListener('input', (e) => renderGlobalResults(e.target.value));
  }
});

document.addEventListener('languagechange', () => {
  initialRender();
  refreshCurrencyLabels();
});
}

/**
 * Single-key tab shortcuts. Key → tab id.
 *
 * Also the source the sidebar hints are painted from, so the two cannot drift.
 */
const TAB_SHORTCUTS = {
  n: 'calculator-tab',
  o: 'logs-tab',
  q: 'queue-tab',
  i: 'inventory-tab',
  a: 'analytics-tab',
  c: 'clients-tab',
};

/**
 * Show each shortcut on the sidebar item it belongs to.
 *
 * Shortcut adoption is a display problem, not a user problem: with the key only
 * documented elsewhere, roughly a third of users ever reach for it, and putting
 * it on the command itself takes that to nearly all of them (Malacria et al.,
 * CHI 2013). Khayt listed these in the help modal only — which is precisely the
 * condition that measured worst. Showing the letter where the user already
 * clicks lets them rehearse the expert action while still working the slow way.
 *
 * Hidden from assistive tech: a screen reader gets the shortcut from the
 * button's aria-keyshortcuts, and a loose letter read after every nav label is
 * noise.
 */
function paintShortcutHints() {
  const byTab = {};
  for (const [key, tab] of Object.entries(TAB_SHORTCUTS)) byTab[tab] = key;
  document.querySelectorAll('.tab-btn[data-tab]').forEach((btn) => {
    const key = byTab[btn.dataset.tab];
    if (!key || btn.querySelector('.kbd-hint')) return;
    btn.setAttribute('aria-keyshortcuts', key.toUpperCase());
    const kbd = document.createElement('span');
    kbd.className = 'kbd-hint';
    kbd.setAttribute('aria-hidden', 'true');
    kbd.textContent = key.toUpperCase();
    btn.appendChild(kbd);
  });
}

(function (global) {
  global.TAB_SHORTCUTS = TAB_SHORTCUTS;
  global.paintShortcutHints = paintShortcutHints;
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { ...(module.exports || {}), TAB_SHORTCUTS };
  }
})(typeof globalThis !== 'undefined' ? globalThis : window);

(function (global) {
  global.initWizard = initWizard;
  global.KhaytAppBoot = { initWizard };
  if (typeof module !== 'undefined' && module.exports) module.exports = { initWizard };
})(typeof globalThis !== 'undefined' ? globalThis : window);
