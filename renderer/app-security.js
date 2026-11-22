/**
 * App security — PIN/recovery helpers and destructive-action gates (renderer).
 */
(function (global) {
  const WEAK_PINS = new Set(['0000', '1111', '2222', '3333', '4444', '5555', '6666', '7777', '8888', '9999', '1234', '4321', '1212', '0123']);
  const RECOVERY_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  async function hashSecret(value) {
    if (typeof hashPin === 'function') return hashPin(value);
    const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(String(value)));
    return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
  }

  function randomBlock(size = 4) {
    let out = '';
    const bytes = new Uint8Array(size);
    crypto.getRandomValues(bytes);
    for (let i = 0; i < size; i++) {
      out += RECOVERY_ALPHABET[bytes[i] % RECOVERY_ALPHABET.length];
    }
    return out;
  }

  function timingSafeEqualHex(a, b) {
    const sa = String(a || '');
    const sb = String(b || '');
    if (sa.length !== sb.length) return false;
    let diff = 0;
    for (let i = 0; i < sa.length; i++) diff |= sa.charCodeAt(i) ^ sb.charCodeAt(i);
    return diff === 0;
  }

  function generateRecoveryCode() {
    return `KHAYT-${randomBlock()}-${randomBlock()}-${randomBlock()}`;
  }

  function normalizeRecoveryCode(code) {
    return String(code || '').toUpperCase().replace(/[^A-Z0-9]/g, '').replace(/^KHAYT/, '');
  }

  function formatRecoveryCode(code) {
    const raw = normalizeRecoveryCode(code);
    if (raw.length !== 12) return String(code || '').trim().toUpperCase();
    return `KHAYT-${raw.slice(0, 4)}-${raw.slice(4, 8)}-${raw.slice(8, 12)}`;
  }

  function isValidRecoveryCode(code) {
    return normalizeRecoveryCode(code).length === 12;
  }

  // Verify a plaintext against a stored hash. Salted PBKDF2 can't be checked by
  // re-hashing (random salt), so delegate to the main process which uses the
  // embedded salt; fall back to legacy 64-hex SHA-256 only if the bridge is gone.
  /**
   * @param {function(string):void} [onUpgraded] Called with a replacement hash
   *   when the stored one was the old unsalted SHA-256 and the plaintext was
   *   correct. The caller supplies it because only the caller knows which
   *   record the hash came from — and without one, a shop keeps a hash that a
   *   four-digit PIN can be read straight out of, for ever.
   */
  async function verifyHash(plain, hash, onUpgraded) {
    if (typeof hash !== 'string' || !hash) return false;
    if (window.hubAPI?.verifyPin) {
      try {
        const answer = await window.hubAPI.verifyPin(String(plain), hash);
        // `{ ok, upgraded }` since the handler learned to re-hash. A plain
        // boolean is still accepted: this file also runs against an older main
        // process during a partial update, and refusing a correct PIN because
        // the reply changed shape is the worst possible way to be strict.
        if (typeof answer === 'boolean') return answer;
        if (answer && typeof answer.ok === 'boolean') {
          if (answer.ok && answer.upgraded && typeof onUpgraded === 'function') {
            // Never fail the unlock over the upgrade. The PIN was right; if the
            // book cannot be written this moment, the next correct PIN tries
            // again.
            try { onUpgraded(answer.upgraded); } catch (e) { console.warn('pin upgrade:', e); }
          }
          return answer.ok;
        }
      } catch (_) { /* fall through to legacy */ }
    }
    if (/^[0-9a-f]{64}$/i.test(hash) && typeof sha256Hex === 'function') {
      const entered = await sha256Hex(String(plain));
      return timingSafeEqualHex(entered, hash);
    }
    return false;
  }

  async function verifyRecoveryCode(code, hash, onUpgraded) {
    if (!hash || !isValidRecoveryCode(code)) return false;
    return verifyHash(normalizeRecoveryCode(code), hash, onUpgraded);
  }

  function isValidPin(pin) {
    return /^\d{4,8}$/.test(String(pin || ''));
  }

  function isWeakPin(pin) {
    const p = String(pin || '');
    if (!isValidPin(p)) return true;
    if (WEAK_PINS.has(p)) return true;
    if (/^(\d)\1+$/.test(p)) return true;
    return false;
  }

  function securityIsEnabled() {
    return !!(settings?.securityEnabled && settings?.recoveryCodeHash);
  }

  function getAdminOperator() {
    const admins = (operators || []).filter(o => (o.role || '').toLowerCase().includes('admin'));
    if (admins.length) return admins[0];
    return (operators || []).find(o => o.pinHash) || null;
  }

  function buildRecoveryCodeFile(code) {
    const formatted = formatRecoveryCode(code);
    const date = localDateStr();
    const brand = (typeof document !== 'undefined' && document.documentElement.dataset.app === 'bedready') ? 'Bed Ready' : 'Khayt';
    // The recovery file is what a locked-out shop reads to prove whose it is,
    // and `bizEn` is empty for a shop writing Turkish or German — so it named
    // the business "Khayt". shopField() resolves the shop's own languages.
    const biz = settings?.businessName
      || (typeof shopField === 'function' ? shopField('biz') : '')
      || brand;
    return [
      brand + ' Recovery Code',
      `Business: ${biz}`,
      `Created: ${date}`,
      '',
      `Recovery code: ${formatted}`,
      '',
      t('sec.recovery_file_warn'),
    ].join('\n');
  }

  async function copyRecoveryCode(code) {
    // This is where the IPC-first order was first worked out, for exactly the
    // reason KhaytUtil.copyText now encodes for the whole app. Deferring to the
    // shared helper keeps one copy of that knowledge.
    return await copyText(formatRecoveryCode(code))
      ? { ok: true }
      : { ok: false, error: 'clipboard_unavailable' };
  }

  async function downloadRecoveryCode(code) {
    const content = buildRecoveryCodeFile(code);
    const brandSlug = (typeof document !== 'undefined' && document.documentElement.dataset.app === 'bedready') ? 'bedready' : 'khayt';
    const defaultName = `${brandSlug}-recovery-${localDateStr()}.txt`;
    if (window.hubAPI?.saveTextFile) {
      return window.hubAPI.saveTextFile({ content, defaultName });
    }
    return { ok: false, error: 'save_unavailable' };
  }

  async function verifyAdminPin(pin) {
    const admin = getAdminOperator();
    if (!admin?.pinHash) return false;
    if (isLegacyPin?.(admin.pinHash)) return false; // very-old base64 → re-prompt
    return verifyHash(String(pin || ''), admin.pinHash, (upgraded) => {
      admin.pinHash = upgraded;
      if (typeof saveAll === 'function') saveAll();
    });
  }

  function promptTypeConfirmModal(message, confirmPhrase, { title, danger = true, extraHtml = '' } = {}) {
    return new Promise(resolve => {
      const phrase = String(confirmPhrase || '');
      const overlay = (typeof appendStackedModal === 'function' ? appendStackedModal : null)?.(`
          <div class="modal" role="dialog" aria-modal="true">
            <h3>${escapeHtml(title || t('common.confirm'))}</h3>
            <p>${escapeHtml(message)}</p>
            ${extraHtml}
            <label style="display:block;margin-top:12px;font-size:13px;">${escapeHtml(t('sec.type_to_confirm', { phrase }))}</label>
            <input type="text" id="typeConfirmInput" class="form-control" autocomplete="off" spellcheck="false" style="margin-top:6px;">
            <div class="btn-row" style="margin-top:14px;">
              <button class="btn ghost" data-act="cancel">${escapeHtml(t('common.cancel'))}</button>
              <button class="btn ${danger ? 'danger' : 'primary'}" data-act="ok" disabled>${escapeHtml(t('common.confirm'))}</button>
            </div>
          </div>`);
      if (!overlay) return resolve(false);
      const input = overlay.querySelector('#typeConfirmInput');
      const okBtn = overlay.querySelector('[data-act="ok"]');
      const sync = () => { okBtn.disabled = input.value.trim() !== phrase; };
      input.addEventListener('input', sync);
      setTimeout(() => input.focus(), 40);
      const cleanup = (val) => { overlay.remove(); resolve(val); };
      okBtn.addEventListener('click', () => { if (!okBtn.disabled) cleanup(true); });
      overlay.querySelector('[data-act="cancel"]').addEventListener('click', () => cleanup(false));
      overlay.addEventListener('click', (e) => { if (e.target === overlay) cleanup(false); });
    });
  }

  function pinOrRecoveryModal({ title, message } = {}) {
    return new Promise(resolve => {
      let mode = 'pin';
      const overlay = (typeof appendStackedModal === 'function' ? appendStackedModal : null)?.('');
      if (!overlay) return resolve(false);
      const render = () => {
        overlay.innerHTML = `
            <div class="modal" role="dialog" aria-modal="true" style="max-width:380px;">
              <h3>${escapeHtml(title || t('sec.verify_title'))}</h3>
              <p style="font-size:13px;color:var(--text-muted);">${escapeHtml(message || t('sec.verify_body'))}</p>
              <div class="seg" style="margin-bottom:12px;">
                <button type="button" class="${mode === 'pin' ? 'on' : ''}" data-mode="pin">${escapeHtml(t('sec.use_pin'))}</button>
                <button type="button" class="${mode === 'recovery' ? 'on' : ''}" data-mode="recovery">${escapeHtml(t('sec.use_recovery'))}</button>
              </div>
              <input type="${mode === 'pin' ? 'password' : 'text'}" id="secVerifyInput" class="form-control"
                placeholder="${escapeHtml(mode === 'pin' ? t('sec.pin_ph') : t('sec.recovery_ph'))}"
                autocomplete="off" inputmode="${mode === 'pin' ? 'numeric' : 'text'}">
              <div id="secVerifyError" style="color:var(--danger);font-size:12px;min-height:18px;margin-top:6px;"></div>
              <div class="btn-row" style="margin-top:10px;">
                <button class="btn ghost" data-act="cancel">${escapeHtml(t('common.cancel'))}</button>
                <button class="btn primary" data-act="ok">${escapeHtml(t('common.confirm'))}</button>
              </div>
            </div>`;
        overlay.querySelectorAll('[data-mode]').forEach(btn => {
          btn.addEventListener('click', () => { mode = btn.dataset.mode; render(); });
        });
        const input = overlay.querySelector('#secVerifyInput');
        setTimeout(() => input?.focus(), 30);
        overlay.querySelector('[data-act="cancel"]').addEventListener('click', () => { overlay.remove(); resolve(false); });
        overlay.addEventListener('click', (e) => { if (e.target === overlay) { overlay.remove(); resolve(false); } });
        overlay.querySelector('[data-act="ok"]').addEventListener('click', async () => {
          const val = input.value.trim();
          const err = overlay.querySelector('#secVerifyError');
          let ok = false;
          if (mode === 'pin') ok = await verifyAdminPin(val);
          else ok = await verifyRecoveryCode(val, settings.recoveryCodeHash, (upgraded) => {
            settings.recoveryCodeHash = upgraded;
            if (typeof saveAll === 'function') saveAll();
          });
          if (ok) { overlay.remove(); resolve(true); return; }
          if (err) err.textContent = mode === 'pin' ? t('sec.pin_invalid') : t('sec.recovery_invalid');
        });
      };
      render();
    });
  }

  async function verifyDestructiveGate({ phrase, title, message, requireSecurity = true } = {}) {
    const typed = await promptTypeConfirmModal(
      message || t('sec.destructive_warn'),
      phrase,
      { title: title || t('common.confirm'), danger: true },
    );
    if (!typed) return false;
    if (requireSecurity && securityIsEnabled()) {
      return pinOrRecoveryModal({ title: t('sec.verify_title'), message: t('sec.verify_body') });
    }
    return true;
  }

  async function setupAdminSecurity({ pin, recoveryCodePlain }) {
    const pinHash = await hashSecret(pin);
    const recoveryHash = await hashSecret(normalizeRecoveryCode(recoveryCodePlain));
    const adminId = uid('OP');
    operators = [{
      id: adminId,
      name: t('sec.default_admin_name'),
      role: t('op.role_admin'),
      // The access level itself, not read off the title: lib/rbac.js
      // roleFromLegacy knows "Admin"/"Administrator" but not the Arabic,
      // Japanese, Turkish or Chinese title this was given, and read the
      // shop's own owner as an operator the moment the lock went on.
      roleKey: 'owner',
      active: true,
      hourlyRate: 0,
      pinHash,
    }];
    settings.activeOperatorId = adminId;
    settings.operatorLockEnabled = true;
    settings.securityEnabled = true;
    settings.recoveryCodeHash = recoveryHash;
    settings.recoveryCodeCreatedAt = localDateStr();
  }

  const api = {
    hashSecret,
    generateRecoveryCode,
    normalizeRecoveryCode,
    formatRecoveryCode,
    isValidRecoveryCode,
    verifyRecoveryCode,
    isValidPin,
    isWeakPin,
    securityIsEnabled,
    getAdminOperator,
    buildRecoveryCodeFile,
    copyRecoveryCode,
    downloadRecoveryCode,
    verifyAdminPin,
    promptTypeConfirmModal,
    pinOrRecoveryModal,
    verifyDestructiveGate,
    setupAdminSecurity,
  };

  Object.assign(global, api);
  global.KhaytAppSecurity = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
