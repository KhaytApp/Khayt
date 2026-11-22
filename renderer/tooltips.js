/**
 * Hover descriptions that appear when you hover.
 *
 * Icon-only buttons carry a `title`, which is the correct thing to write in the
 * markup and the wrong thing to rely on at runtime: the browser decides when to
 * show it, and Chromium waits roughly a second. Reported as "the icons either
 * don't load the description or take a long time to load, it's not instant" —
 * which is exactly right, and not something a `title` can be configured out of.
 * There is no CSS or attribute for the delay; it belongs to the browser.
 *
 * So this replaces it. One element, delegated listeners, and a delay this app
 * chooses.
 *
 * ── WHY THE `title` IS MOVED RATHER THAN COPIED ────────────────────────────
 *
 * Leaving it in place shows BOTH tooltips — the fast one and then the native one
 * on top of it a second later. Moving it into `data-khayt-tip` suppresses the
 * native tooltip, and the accessible name is preserved deliberately: an element
 * with no `aria-label` gets one from the title it just lost, because a screen
 * reader falls back to `title` and would otherwise be handed a nameless button.
 * That is the whole reason the markup used `title` in the first place, and it
 * must survive this.
 *
 * ── WHAT IT DELIBERATELY DOES NOT TOUCH ────────────────────────────────────
 *
 * The tour draws its own anchored bubbles (renderer/tour.js), and form controls
 * with a native `title` used as validation text behave differently. Anything
 * inside the tour overlay is skipped rather than fought with.
 */
(function (global) {
  'use strict';

  /* Long enough not to flicker across a toolbar, short enough to feel like an
   * answer rather than a wait. The native delay this replaces is ~1000ms. */
  const SHOW_DELAY_MS = 120;
  const EDGE_GAP = 8;

  let tipEl = null;
  let timer = null;
  let current = null;

  function ensureEl() {
    if (tipEl && tipEl.isConnected) return tipEl;
    tipEl = document.createElement('div');
    tipEl.className = 'khayt-tip';
    tipEl.setAttribute('role', 'tooltip');
    // Presentational only: the accessible name lives on the element itself, so a
    // screen reader must not read this a second time.
    tipEl.setAttribute('aria-hidden', 'true');
    document.body.appendChild(tipEl);
    return tipEl;
  }

  /** Pull `title` out of an element once, keeping what it announced. */
  function adopt(el) {
    const title = el.getAttribute('title');
    if (title == null) return el.dataset.khaytTip || '';
    const text = String(title).trim();
    el.removeAttribute('title');
    if (!text) return el.dataset.khaytTip || '';
    el.dataset.khaytTip = text;
    // A screen reader falls back to `title` when there is no label. Taking the
    // title away without this would silently un-name every icon button in the
    // app — the exact failure test/button-accessible-name.test.js exists to
    // prevent, reintroduced at runtime where that check cannot see it.
    if (!el.getAttribute('aria-label') && !el.getAttribute('aria-labelledby')) {
      el.setAttribute('aria-label', text);
    }
    return text;
  }

  function place(el) {
    const tip = ensureEl();
    const r = el.getBoundingClientRect();
    const t = tip.getBoundingClientRect();
    // Above by default; below when there is no room, which is the case for
    // anything in the top bar.
    let top = r.top - t.height - EDGE_GAP;
    if (top < EDGE_GAP) top = r.bottom + EDGE_GAP;
    let left = r.left + (r.width - t.width) / 2;
    // Clamp inside the viewport rather than letting it hang off the edge — the
    // rail buttons sit hard against the left, and RTL puts others against the right.
    left = Math.max(EDGE_GAP, Math.min(left, window.innerWidth - t.width - EDGE_GAP));
    tip.style.top = `${Math.round(top)}px`;
    tip.style.left = `${Math.round(left)}px`;
  }

  function show(el, text) {
    if (!text) return;
    const tip = ensureEl();
    tip.textContent = text;
    tip.classList.add('is-on');
    current = el;
    place(el);
  }

  function hide() {
    if (timer) { clearTimeout(timer); timer = null; }
    current = null;
    if (tipEl) tipEl.classList.remove('is-on');
  }

  /** The element under the pointer that actually has something to say. */
  function targetFrom(node) {
    if (!node || typeof node.closest !== 'function') return null;
    const el = node.closest('[title], [data-khayt-tip]');
    if (!el) return null;
    // The tour owns its own bubbles; two tooltip systems over one element is
    // worse than either alone.
    if (el.closest('.khayt-tour, .tour-overlay, [data-tour-overlay]')) return null;
    return el;
  }

  function onEnter(e) {
    const el = targetFrom(e.target);
    if (!el || el === current) return;
    const text = adopt(el);
    if (!text) return;
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => show(el, text), SHOW_DELAY_MS);
  }

  function onLeave(e) {
    const el = targetFrom(e.target);
    if (el && el === current && e.relatedTarget && el.contains(e.relatedTarget)) return;
    hide();
  }

  function attach(doc) {
    const d = doc || document;
    // Capture, because the hover may start on a child (`<span>🔧</span>`) and
    // mouseover does not bubble usefully from every shadowed control.
    d.addEventListener('mouseover', onEnter, true);
    d.addEventListener('mouseout', onLeave, true);
    // Keyboard users get the same description, which the native tooltip never
    // gave them: `title` does not show on focus.
    d.addEventListener('focusin', onEnter, true);
    d.addEventListener('focusout', hide, true);
    // Anything that moves the page underneath a shown tip invalidates its
    // position, and a tip left behind over the wrong control is a wrong answer.
    d.addEventListener('scroll', hide, true);
    d.addEventListener('click', hide, true);
    window.addEventListener('resize', hide);
    window.addEventListener('blur', hide);
    return true;
  }

  const api = { attach, adopt, hide, SHOW_DELAY_MS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytTooltips = api;

  if (typeof document !== 'undefined') {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => attach(document));
    else attach(document);
  }
})(typeof globalThis !== 'undefined' ? globalThis : window);
