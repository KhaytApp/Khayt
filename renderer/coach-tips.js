/**
 * Coach tips — contextual inline hints on key inputs. Any element tagged
 * `data-tip="<i18n-key>"` gets a small ⓘ help button injected after it; clicking
 * toggles a short localized explanation. Opt-out via settings.coachTips=false.
 * Idempotent + re-runnable (safe to call after dynamic content renders).
 */
(function (global) {
  'use strict';
  const tr = (k) => (typeof t === 'function' ? t(k) : k);

  function enabled() {
    try { return !(global.settings && global.settings.coachTips === false); } catch (e) { return true; }
  }

  function applyCoachTips(root) {
    if (typeof document === 'undefined') return;
    root = root || document;
    const on = enabled();
    root.querySelectorAll('[data-tip]').forEach((el) => {
      // Reuse an existing button if we've processed this element before.
      let btn = el.nextElementSibling && el.nextElementSibling.classList && el.nextElementSibling.classList.contains('coach-tip')
        ? el.nextElementSibling : null;
      if (!on) { if (btn) btn.remove(); return; }
      const key = el.getAttribute('data-tip');
      const text = tr(key);
      if (!btn) {
        btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'coach-tip';
        btn.innerHTML = 'ⓘ';
        const bubble = document.createElement('span');
        bubble.className = 'coach-tip-text';
        btn.appendChild(bubble);
        btn.addEventListener('click', (e) => {
          e.preventDefault(); e.stopPropagation();
          const open = btn.classList.contains('open');
          document.querySelectorAll('.coach-tip.open').forEach((b) => b.classList.remove('open'));
          if (!open) btn.classList.add('open');
        });
        el.insertAdjacentElement('afterend', btn);
      }
      btn.setAttribute('aria-label', text);
      btn.title = text;
      const bub = btn.querySelector('.coach-tip-text');
      if (bub) bub.textContent = text;
    });
  }

  // Dismiss any open tip when clicking elsewhere.
  if (typeof document !== 'undefined') {
    document.addEventListener('click', (e) => {
      if (!e.target.closest || !e.target.closest('.coach-tip')) {
        document.querySelectorAll('.coach-tip.open').forEach((b) => b.classList.remove('open'));
      }
    });
    document.addEventListener('languagechange', () => applyCoachTips(document));
  }

  global.applyCoachTips = applyCoachTips;
  global.KhaytCoachTips = { applyCoachTips };
  if (typeof module !== 'undefined' && module.exports) module.exports = { applyCoachTips };
})(typeof globalThis !== 'undefined' ? globalThis : window);
