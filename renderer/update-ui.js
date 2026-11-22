/**
 * In-app update UI: changelog review before download/install.
 */
(function (global) {
  let updateOverlay = null;
  let activeUpdateInfo = null;
  let promptedVersion = null;
  let openingModal = false; // synchronous latch: an open is in-flight across its await
  /* Has the shop accepted the changes in the update currently on offer?
   *
   * Module state rather than a DOM read, because the checkbox does not survive
   * a state change — and every state that can reach a download has to be able
   * to ask. Reset whenever a different version is offered. */
  let consentGiven = false;

  // Product name for update copy — Bed Ready runs the same renderer via its own
  // flavor marker on <html>, so never hard-code "Khayt" in user-facing strings.
  const PRODUCT = (typeof document !== 'undefined' && document.documentElement.dataset.app === 'bedready')
    ? 'Bed Ready' : 'Khayt';

  function tr(key, fallback, vars) {
    if (typeof t === 'function') {
      const v = t(key, vars);
      if (v && v !== key) return v;
    }
    if (vars && fallback) {
      let s = fallback;
      for (const k of Object.keys(vars)) s = s.replaceAll(`{${k}}`, String(vars[k]));
      return s;
    }
    return fallback;
  }

  function closeUpdateModal() {
    if (updateOverlay) {
      updateOverlay.remove();
      updateOverlay = null;
    }
  }

  async function formatNotes(info) {
    try {
      const formatted = await window.hubAPI?.formatReleaseNotes?.(info.releaseNotes || '', {
        version: info.version,
        releaseDate: info.releaseDate,
      });
      if (formatted?.html) return formatted.html;
    } catch (e) {
      console.warn('[update-ui] formatReleaseNotes failed', e);
    }
    return `<p class="update-notes-paragraph">${escapeHtml(tr('upd.no_notes', 'Release notes were not included with this update.'))}</p>`;
  }

  function withTimeout(promise, ms, label) {
    return Promise.race([
      promise,
      new Promise((resolve) => setTimeout(() => {
        console.warn(`[update] ${label} timed out after ${ms}ms — continuing`);
        resolve(null);
      }, ms)),
    ]);
  }

  async function prepareAndInstall(version) {
    if (typeof flushSave === 'function') {
      await withTimeout(flushSave(), 20_000, 'flushSave');
    }
    await withTimeout(
      window.hubAPI?.writeUpdateBackup?.('__COPY_STORE__', version),
      12_000,
      'writeUpdateBackup',
    );
    localStorage.setItem('khayt_pending_update_to', String(version));
    setTimeout(() => {
      if (localStorage.getItem('khayt_pending_update_to') === String(version)) {
        localStorage.removeItem('khayt_pending_update_to');
        toast(tr('upd.install_failed', 'Update installation failed — please restart the app manually.'), 'error', 8000);
      }
    }, 30_000);
    await window.hubAPI?.installUpdate?.(null);
  }

  function setModalBody(html) {
    const body = updateOverlay?.querySelector('#updateModalBody');
    if (body) body.innerHTML = html;
  }

  function setModalFooter(html) {
    const footer = updateOverlay?.querySelector('#updateModalFooter');
    if (footer) footer.innerHTML = html;
  }

  function wireFooterActions() {
    updateOverlay?.querySelector('[data-upd="later"]')?.addEventListener('click', closeUpdateModal);
    updateOverlay?.querySelector('[data-upd="download"]')?.addEventListener('click', () => {
      startUpdateDownload();
    });
    updateOverlay?.querySelector('[data-upd="install"]')?.addEventListener('click', async () => {
      const btn = updateOverlay?.querySelector('[data-upd="install"]');
      if (btn) btn.disabled = true;
      try {
        setModalFooter(
          `<button class="btn primary" disabled>${escapeHtml(tr('upd.installing', 'Installing…'))}</button>`,
        );
        await prepareAndInstall(activeUpdateInfo.version);
      } catch (err) {
        console.error('[update] install prep failed:', err);
        toast(tr('upd.install_retry', 'Could not prepare update — trying install anyway.'), 'warning', 6000);
        try { await window.hubAPI?.installUpdate?.(null); } catch (_) {}
      }
    });
    updateOverlay?.querySelector('[data-upd="close"]')?.addEventListener('click', closeUpdateModal);
  }

  /**
   * The changes this release says you have to agree to, or nothing.
   *
   * Deliberately loud and ABOVE the notes: an update that moves the controls
   * somebody uses fifty times a day is not a detail to be found by scrolling.
   * Deliberately a list of sentences rather than a version number and a link —
   * "3.8.0" tells a shop nothing about what its morning is going to be like.
   */
  function consentPanelHtml(items) {
    return `
      <div class="update-consent" role="group" aria-labelledby="updConsentHead">
        <h4 class="update-consent-head" id="updConsentHead">${escapeHtml(tr('upd.consent_head', 'This update changes how you work'))}</h4>
        <ul class="update-consent-list">
          ${items.map((x) => `<li>${escapeHtml(x)}</li>`).join('')}
        </ul>
        <label class="update-consent-accept">
          <input type="checkbox" id="updAccept">
          <span>${escapeHtml(tr('upd.consent_accept', 'I have read these changes and want to update'))}</span>
        </label>
      </div>`;
  }

  function renderReviewState(notesHtml) {
    const version = escapeHtml(activeUpdateInfo.version);
    const current = escapeHtml(activeUpdateInfo.currentVersion || '');
    const major = activeUpdateInfo.majorChanges;
    const gated = !!(major && major.needsConsent && Array.isArray(major.items) && major.items.length);

    setModalBody(`
      ${gated ? consentPanelHtml(major.items) : ''}
      <p class="update-notes-intro">${escapeHtml(gated
        ? tr('upd.intro_consent', 'Everything else in this update:')
        : tr('upd.intro', 'Review what is new before installing.'))}</p>
      ${current ? `<p class="update-notes-meta">${escapeHtml(tr('upd.from_version', 'Current version'))}: <strong>${current}</strong> → <strong>${version}</strong></p>` : ''}
      <div class="update-notes-panel">${notesHtml}</div>
    `);
    setModalFooter(`
      <button class="btn ghost" data-upd="later">${escapeHtml(tr('upd.later', 'Later'))}</button>
      <button class="btn primary" data-upd="download"${gated ? ' disabled' : ''}>${escapeHtml(tr('upd.download', 'Download update'))}</button>
    `);
    wireFooterActions();

    /* THE GATE IS ON THE DOWNLOAD, NOT THE INSTALL, and that is not a detail:
     * `autoInstallOnAppQuit` is true in lib/updater.js, so a downloaded update
     * installs on the next quit whether or not anybody presses anything. Gating
     * the install button would be no gate at all. The download is the last
     * moment at which "no" still means no. */
    if (gated) {
      const accept = updateOverlay?.querySelector('#updAccept');
      const download = updateOverlay?.querySelector('[data-upd="download"]');
      accept?.addEventListener('change', () => {
        consentGiven = !!accept.checked;
        if (download) download.disabled = !accept.checked;
      });
    }
  }

  /** Bytes → "12.4 MB". Update payloads are always MB-to-GB, never smaller. */
  function formatBytes(n) {
    const mb = (+n || 0) / 1048576;
    return mb >= 1024 ? `${(mb / 1024).toFixed(2)} GB` : `${mb.toFixed(1)} MB`;
  }

  /** Seconds → "about 3 min" / "about 45 sec". Deliberately coarse: a precise
   *  ETA that jitters every tick reads as less trustworthy, not more. */
  function formatEta(seconds) {
    const s = Math.max(0, Math.round(+seconds || 0));
    if (!s || !isFinite(s)) return '';
    if (s < 60) return tr('upd.eta_sec', 'about {n} sec', { n: String(s) });
    return tr('upd.eta_min', 'about {n} min', { n: String(Math.max(1, Math.round(s / 60))) });
  }

  /**
   * The download is 150 MB+. A bar and a bare percentage that creeps a point
   * every few seconds is indistinguishable from a frozen one — reported from
   * the field as "started the download but nothing is downloading" when the
   * download was in fact running fine and finished on its own.
   *
   * So show the numbers that prove liveness: bytes transferred, current speed,
   * and a coarse ETA. main already sends all three; this used to discard them
   * and keep only `percent`.
   *
   * Updates in place after the first render. Re-running setModalBody on every
   * tick replaced the aria-live region wholesale, which makes a screen reader
   * re-announce the whole block several times a second.
   */
  function renderDownloadingState(progress) {
    const p = (typeof progress === 'number') ? { percent: progress } : (progress || {});
    const percent = Math.max(0, Math.min(100, Math.round(+p.percent || 0)));
    const detail = (p.total > 0)
      ? `${formatBytes(p.transferred)} / ${formatBytes(p.total)}`
      : '';
    const speed = (p.bytesPerSecond > 0) ? `${formatBytes(p.bytesPerSecond)}/s` : '';
    const eta = (p.bytesPerSecond > 0 && p.total > 0)
      ? formatEta((p.total - p.transferred) / p.bytesPerSecond)
      : '';
    const meta = [detail, speed, eta].filter(Boolean).join(' · ');

    const fill = updateOverlay?.querySelector('.update-progress-fill');
    if (fill) {
      fill.style.width = `${percent}%`;
      // The bar carries the accessible value; updating only the visual fill
      // leaves a screen reader announcing 0% for the whole download.
      updateOverlay.querySelector('.update-progress-bar')?.setAttribute('aria-valuenow', String(percent));
      const label = updateOverlay.querySelector('.update-progress-label');
      if (label) label.textContent = `${percent}%`;
      const metaEl = updateOverlay.querySelector('.update-progress-meta');
      if (metaEl) metaEl.textContent = meta;
      return;
    }

    setModalBody(`
      <p class="update-notes-intro">${escapeHtml(tr('upd.downloading', 'Downloading update…'))}</p>
      <div class="update-progress-wrap">
        <div class="update-progress-bar" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${percent}">
          <div class="update-progress-fill" style="width:${percent}%"></div>
        </div>
        <div class="update-progress-label">${percent}%</div>
        <div class="update-progress-meta">${escapeHtml(meta)}</div>
      </div>
    `);
    setModalFooter(`
      <button class="btn ghost" data-upd="later">${escapeHtml(tr('upd.continue_bg', 'Continue in background'))}</button>
    `);
    wireFooterActions();
  }

  /**
   * A download that emits no progress for this long is not merely slow. Say so
   * and offer the direct link, rather than leaving a bar that will never move.
   * The download is NOT cancelled — it may still recover, and if it does the
   * next progress event clears this notice.
   */
  const STALL_AFTER_MS = 45_000;
  let stallTimer = null;

  function noteDownloadProgress() {
    if (stallTimer) clearTimeout(stallTimer);
    const stalled = updateOverlay?.querySelector('.update-progress-stalled');
    if (stalled) stalled.remove();
    stallTimer = setTimeout(() => {
      const wrap = updateOverlay?.querySelector('.update-progress-wrap');
      if (!wrap || wrap.querySelector('.update-progress-stalled')) return;
      const note = document.createElement('p');
      note.className = 'update-notes-meta update-progress-stalled';
      note.textContent = tr('upd.stalled', 'The download has not progressed for a while. It may still recover — or you can download it manually.');
      wrap.appendChild(note);
    }, STALL_AFTER_MS);
  }

  function stopStallWatch() {
    if (stallTimer) clearTimeout(stallTimer);
    stallTimer = null;
  }

  function renderReadyState() {
    const version = activeUpdateInfo.version;
    setModalBody(`
      <p class="update-notes-intro">${escapeHtml(tr('upd.ready', 'Update downloaded and ready to install.'))}</p>
      <p class="update-notes-meta">${escapeHtml(tr('upd.ready_version', PRODUCT + ' {version} will install after restart.', { version }))}</p>
      <p class="update-notes-hint">${escapeHtml(tr('upd.backup_hint', 'A pre-update backup is saved automatically before restart.'))}</p>
    `);
    setModalFooter(`
      <button class="btn ghost" data-upd="later">${escapeHtml(tr('upd.later', 'Later'))}</button>
      <button class="btn primary" data-upd="install">${escapeHtml(tr('upd.restart_install', 'Restart & install'))}</button>
    `);
    wireFooterActions();
  }

  /** Does the update on offer still need consent that has not been given? */
  function stillGated() {
    const major = activeUpdateInfo && activeUpdateInfo.majorChanges;
    if (!(major && major.needsConsent && Array.isArray(major.items) && major.items.length)) return false;
    return !consentGiven;
  }

  function renderErrorState(message) {
    setModalBody(`
      <p class="update-notes-intro">${escapeHtml(tr('upd.error_title', 'Update failed'))}</p>
      <p class="update-notes-error">${escapeHtml(message || tr('upd.error_generic', 'Unknown update error'))}</p>
    `);
    /* RETRY IS A DOWNLOAD, SO IT IS GATED TOO.
     *
     * This rebuilt the footer with an ENABLED download and no consent panel, so
     * any update-error arriving while the gated review modal was open replaced
     * the gate with a live button. `gated` was computed once, in
     * renderReviewState, and every other state discarded it — the gate was one
     * error away from gone. Derived here instead. */
    const gated = stillGated();
    setModalFooter(`
      <button class="btn ghost" data-upd="close">${escapeHtml(tr('common.close', 'Close'))}</button>
      <button class="btn primary" data-upd="download"${gated ? ' disabled' : ''}>${escapeHtml(tr('upd.retry_download', 'Retry download'))}</button>
    `);
    wireFooterActions();
  }

  function startUpdateDownload() {
    if (!activeUpdateInfo) return;
    // The last word. Every button that reaches here is meant to be disabled
    // while consent is outstanding; this is so that being wrong about one of
    // them costs nothing.
    if (stillGated()) return;
    renderDownloadingState(0);
    // Arm the watch here, not on first progress: a download that never emits a
    // single event is exactly the case this needs to catch.
    noteDownloadProgress();
    window.hubAPI?.startUpdateDownload?.();
  }

  async function showUpdateChangesModal(info, { currentVersion, initialState = 'review' } = {}) {
    if (!info?.version || !window.hubAPI) return;
    // Already showing (or mid-open, across the async formatNotes gap) for this version →
    // ignore the duplicate. A manual check fires BOTH the update-available event and the
    // IPC result for the same version; without this latch they race into two stacked modals.
    if (promptedVersion === info.version && (updateOverlay || openingModal)) return;
    openingModal = true;

    // A different version is a different set of changes to accept.
    if (promptedVersion !== info.version) consentGiven = false;
    promptedVersion = info.version;
    activeUpdateInfo = {
      version: info.version,
      releaseDate: info.releaseDate || null,
      releaseNotes: info.releaseNotes || '',
      currentVersion: currentVersion || info.currentVersion || '',
      /* Parsed in main and carried here, so the gate arrives WITH the offer.
         A renderer that had to go and ask would have to render the download
         button before it knew whether to disable it. */
      majorChanges: info.majorChanges || null,
    };

    closeUpdateModal();

    const notesHtml = await formatNotes(activeUpdateInfo);
    const version = escapeHtml(activeUpdateInfo.version);

    updateOverlay = appendStackedModal(`
      <div class="modal modal-form modal-lg update-modal" role="dialog" aria-modal="true" aria-labelledby="updateModalTitle">
        <div class="modal-header">
          <h3 id="updateModalTitle">${escapeHtml(tr('upd.title', 'Update available'))} — ${escapeHtml(PRODUCT)} ${version}</h3>
          <button class="btn ghost small" data-upd="later" aria-label="${escapeHtml(tr('common.close', 'Close'))}" title="${escapeHtml(tr('common.close', 'Close'))}">×</button>
        </div>
        <div class="modal-body" id="updateModalBody"></div>
        <div class="modal-footer" id="updateModalFooter"></div>
      </div>
    `, { zIndex: 10060 });
    openingModal = false;

    updateOverlay.querySelector('.modal-header [data-upd="later"]')?.addEventListener('click', closeUpdateModal);
    updateOverlay.addEventListener('click', (e) => {
      if (e.target === updateOverlay) closeUpdateModal();
    });

    if (initialState === 'ready') renderReadyState();
    else renderReviewState(notesHtml);
  }

  function wireUpdateUI({ getCurrentVersion } = {}) {
    window.hubAPI?.onUpdateAvailable?.((info) => {
      const currentVersion = typeof getCurrentVersion === 'function' ? getCurrentVersion() : '';
      showUpdateChangesModal(info, { currentVersion });
    });

    window.hubAPI?.onUpdateDownloadProgress?.((progress) => {
      if (!updateOverlay || !activeUpdateInfo) return;
      renderDownloadingState(progress || {});
      noteDownloadProgress();
    });

    window.hubAPI?.onUpdateDownloaded?.((info) => {
      stopStallWatch();
      if (info?.version) {
        activeUpdateInfo = { ...(activeUpdateInfo || {}), version: info.version };
      }
      if (!updateOverlay) {
        showUpdateChangesModal(activeUpdateInfo || info, { initialState: 'ready' });
        return;
      }
      renderReadyState();
    });

    window.hubAPI?.onUpdateError?.((err) => {
      stopStallWatch();
      if (!updateOverlay) return;
      renderErrorState(err?.message || '');
    });
  }

  async function handleManualUpdateCheckResult(res, { currentVersion, statusEl } = {}) {
    if (res?.status === 'available') {
      if (statusEl) statusEl.textContent = '';
      await showUpdateChangesModal(res, { currentVersion });
      return;
    }
    if (res?.status === 'dev') {
      if (statusEl) {
        const ver = res.currentVersion || currentVersion || '';
        if (PRODUCT !== 'Khayt') {
          // Bed Ready: no Khayt-repo workflow — show the flavor's own dev message.
          statusEl.textContent = res.message || `Source build${ver ? ` (${ver})` : ''}.`;
        } else {
          statusEl.innerHTML =
            `Source build${ver ? ` (${escapeHtml(ver)})` : ''}. ` +
            'New features ship on <strong>main</strong> first — in your repo folder run ' +
            '<code>git pull origin main</code> then <code>npm start</code>. ' +
            'Installed DMG/auto-update only moves when a new GitHub Release is published ' +
            '(see <a href="https://github.com/khaytapp/Khayt/blob/main/docs/RELEASE-HOLD.md" target="_blank" rel="noopener">release hold</a>).';
        }
      }
      return;
    }
    if (res?.status === 'error') {
      if (statusEl) {
        statusEl.textContent = `⚠ Update check failed: ${res.message || 'unknown error'}`;
        // The library's own wording, kept but not shouted. `message` is now an
        // explanation for recognised failures, and the raw text is what somebody
        // quotes when reporting one — throwing it away would trade an unreadable
        // message for an undiagnosable one.
        if (res.detail) statusEl.title = res.detail;
        else statusEl.removeAttribute('title');
      }
      return;
    }
    if (res?.status === 'not-available') {
      const ver = res.currentVersion || currentVersion || '';
      if (statusEl) statusEl.textContent = ver ? `✓ You're up to date (${ver})` : '✓ You\'re up to date';
      return;
    }
    if (statusEl) statusEl.textContent = '⚠ Update check returned no result';
  }

  const api = {
    wireUpdateUI,
    showUpdateChangesModal,
    handleManualUpdateCheckResult,
  };

  Object.assign(global, api);
  global.KhaytUpdateUI = api;
})(window);
