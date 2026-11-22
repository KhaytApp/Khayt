/**
 * Design themes (visual identity) + accent presets.
 * Appearance (dark/light/system) is separate — see applyTheme() in shell.js.
 */
(function (global) {
  const reg = () => global.KhaytThemeRegistry;

  function tr(key, fallback) {
    if (typeof t === 'function') {
      const v = t(key);
      if (v && v !== key) return v;
    }
    return fallback;
  }

  function themeLabel(theme, id) {
    if (theme.label) return theme.label;
    return tr(theme.labelKey, id);
  }

  function applyAccent(accentId, accentSet) {
    const root = document.documentElement;
    const design = reg()?.normalizeDesignId(root.dataset.design || 'khayt') || 'khayt';
    const set = accentSet || reg()?.accentsForTheme(design) || {};
    const preset = set[accentId] || set[reg()?.defaultAccentForTheme(design)];
    if (!preset) return;
    root.style.setProperty('--accent-h', String(preset.h));
    root.style.setProperty('--accent-s', preset.s);
    root.style.setProperty('--accent-l', preset.l);
    root.dataset.accent = accentId;
  }

  function syncSidebarSubtitle(designId) {
    const sub = document.querySelector('.sidebar-subtitle');
    if (!sub) return;

    /* The shop's own name, where the theme's name used to be.
     *
     * This read `خيط · COMMAND` — the ACTIVE THEME, announced in the brand
     * lockup every time anyone glanced at the sidebar. Reported as "why is the
     * top bar for left bar saying khayt command", which is the right question:
     * the theme is something you picked once in Settings, and Settings is where
     * its name belongs. Whose shop this is, is worth the space.
     *
     * shopField() resolves the shop's own content languages, so a shop writing
     * Turkish sees its Turkish name rather than a blank. A shop that has not
     * filled anything in yet falls through to the product wordmark, which is
     * what was there before and is never wrong.
     */
    const biz = (typeof shopField === 'function' ? shopField('biz') : '').trim();
    /* The default business name is the PRODUCT'S name.
     *
     * renderer/app-state.js seeds `bizEn` with 'Khayt' (or 'Bed Ready') so that
     * an invoice printed before anyone visits Settings is not headed by a blank.
     * That makes "has a business name" and "has entered a business name" two
     * different questions, and only the second one should replace the wordmark:
     * a shop that has never been near Settings would otherwise see KHAYT where
     * خيط · STUDIO used to be, which is not its name and is a worse lockup.
     *
     * Found by running the app rather than by reading it — the unit tests all
     * passed, and the fresh profile showed "KHAYT".
     */
    const seeded = ['khayt', 'خيط', 'bed ready', 'بيد ريدي'];
    if (biz && !seeded.includes(biz.toLowerCase())) {
      // NOT uppercased. The old subtitle was a wordmark and shouted by design;
      // a shop's name is a proper noun it chose, and "iPhone Repairs" is not
      // improved by becoming IPHONE REPAIRS.
      sub.textContent = biz;
      return;
    }

    // Bed Ready is its own product — never stamp the Khayt (خيط) wordmark here.
    if (document.documentElement.dataset.app === 'bedready') { sub.textContent = 'MAKER STUDIO'; return; }
    const theme = reg()?.getTheme(designId);
    // Name the DESIGN, not the shell it borrows. Blueprint runs on the
    // Workbench shell and Nocturne on Command, so keying this off theme.shell
    // would have both of them announcing someone else's name in the sidebar.
    const id = reg()?.normalizeDesignId(designId);
    if (theme?.custom) sub.textContent = `خيط · ${(theme.label || designId).toUpperCase()}`;
    else if (id) sub.textContent = `خيط · ${String(id).toUpperCase()}`;
    else sub.textContent = 'خيط · WORKBENCH';
  }

  function unloadCustomThemeStyles() {
    document.querySelectorAll('[data-khayt-theme-pack="custom"]').forEach((el) => el.remove());
  }

  function loadCustomThemeStyles(theme) {
    unloadCustomThemeStyles();
    if (!theme?.custom) return;
    if (!theme.stylesheets?.length && !theme.inlineCss?.length) return;
    theme.stylesheets.forEach((href) => {
      // Defense in depth: only load .css bundled under the custom-theme folder (no traversal).
      if (typeof href !== 'string' || href.includes('..') || !href.startsWith('themes/custom/') || !href.endsWith('.css')) return;
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = href;
      link.dataset.khaytThemePack = 'custom';
      document.head.appendChild(link);
    });

    // A theme installed in userData arrives as text rather than as a URL: it
    // lives outside the app's origin, and the CSP that stops a <link> reaching
    // the network stops it reaching the disk too.
    //
    // `textContent`, never innerHTML. The difference is the whole safety of this
    // line — assigning to textContent cannot end the <style> element, so a
    // stylesheet carrying `</style><script>` stays a string that does nothing.
    // lib/theme-package.js refuses that construct on install and again on read,
    // and this is the third place it cannot work.
    (theme.inlineCss || []).forEach((sheet) => {
      if (!sheet || typeof sheet.text !== 'string') return;
      const el = document.createElement('style');
      el.dataset.khaytThemePack = 'custom';
      el.dataset.khaytThemeFile = String(sheet.name || '');
      el.textContent = sheet.text;
      document.head.appendChild(el);
    });
  }

  /**
   * Bed Ready is a separate product, not a Khayt design. It used to be pinned to
   * the `studio` theme and reached the registry like any other; since 3.3 it owns
   * its own UI layer (renderer/bedready/) and is identified by the html marker
   * alone, so nothing about it depends on Khayt's theme list.
   */
  function isBedReady() {
    return typeof document !== 'undefined' && document.documentElement.dataset.app === 'bedready';
  }

  function applyBodyClasses(designId) {
    const theme = reg()?.getTheme(designId);
    const shell = theme?.shell || 'workbench';
    // One class, set by product rather than by theme. It was two (khayt-studio +
    // khayt-handoff) that could never disagree once studio was the last handoff shell.
    document.body.classList.toggle('bedready-ui', isBedReady());
    document.body.classList.toggle('khayt-workbench', !isBedReady() && shell === 'workbench');
    document.body.classList.toggle('khayt-command', !isBedReady() && shell === 'command');
    document.body.classList.toggle('khayt-vivid', !isBedReady() && shell === 'vivid');
    document.body.classList.toggle('khayt-meridian', !isBedReady() && shell === 'meridian');
    document.body.classList.toggle('khayt-foreman', !isBedReady() && shell === 'foreman');
    document.body.classList.toggle('khayt-flow', !isBedReady() && shell === 'flow');
    document.body.classList.toggle('khayt-shell-default', !isBedReady() && shell === 'default');

    document.querySelectorAll('[data-khayt-body-class]').forEach((el) => {
      el.classList.remove(el.dataset.khaytBodyClass);
      delete el.dataset.khaytBodyClass;
    });
    if (theme?.bodyClass && !['bedready-ui', 'khayt-workbench', 'khayt-command', 'khayt-vivid', 'khayt-meridian', 'khayt-foreman', 'khayt-flow'].includes(theme.bodyClass)) {
      document.body.classList.add(theme.bodyClass);
      document.body.dataset.khaytBodyClass = theme.bodyClass;
    }
  }

  function applyDesignTheme(designId) {
    const id = reg()?.normalizeDesignId(designId) || 'khayt';
    const theme = reg()?.getTheme(id);
    const root = document.documentElement;
    const wasWorkbench = document.body.classList.contains('khayt-workbench');
    const wasCommand = document.body.classList.contains('khayt-command');
    const wasVivid = document.body.classList.contains('khayt-vivid');
    const wasMeridian = document.body.classList.contains('khayt-meridian');
    const wasForeman = document.body.classList.contains('khayt-foreman');
    const wasFlow = document.body.classList.contains('khayt-flow');
    const nextShell = theme?.shell || 'workbench';

    if (['workbench', 'command', 'vivid', 'foreman'].includes(nextShell)) {
      document.getElementById('appSidebar')?.classList.remove('collapsed');
    }

    root.dataset.design = id;
    loadCustomThemeStyles(theme);
    applyBodyClasses(id);
    syncSidebarSubtitle(id);
    if (typeof settings !== 'undefined') {
      const accent = reg()?.normalizeAccent(id, settings.accent) || 'cyan';
      if (settings.accent !== accent) settings.accent = accent;
      applyAccent(accent, reg()?.accentsForTheme(id));
    }
    if (wasWorkbench) global.KhaytWorkbenchShell?.teardownWorkbenchShell?.();
    if (wasCommand) global.KhaytCommandShell?.teardownCommandShell?.();
    if (wasVivid) global.KhaytVividShell?.teardownVividShell?.();
    if (wasMeridian) global.KhaytMeridianShell?.teardownMeridianShell?.();
    if (wasForeman) global.KhaytForemanShell?.teardownForemanShell?.();
    if (wasFlow) global.KhaytFlowShell?.teardownFlowShell?.();
    if (nextShell === 'workbench') global.KhaytWorkbenchShell?.applyWorkbenchShell?.();
    if (nextShell === 'command') global.KhaytCommandShell?.applyCommandShell?.();
    if (nextShell === 'vivid') global.KhaytVividShell?.applyVividShell?.();
    if (nextShell === 'meridian') global.KhaytMeridianShell?.applyMeridianShell?.();
    if (nextShell === 'foreman') global.KhaytForemanShell?.applyForemanShell?.();
    if (nextShell === 'flow') global.KhaytFlowShell?.applyFlowShell?.();
    if (isBedReady()) {
      global.KhaytBedReadyUI?.init?.();
      if (typeof renderDashboard === 'function') renderDashboard();
      if (typeof renderKanban === 'function') renderKanban();
      if (typeof renderClients === 'function') renderClients();
      if (typeof renderInventory === 'function') renderInventory();
    } else if (['workbench', 'command', 'vivid', 'meridian', 'foreman', 'flow'].includes(nextShell)) {
      if (typeof renderDashboard === 'function') renderDashboard();
    }
  }

  function applyDesignSettings() {
    // Bed Ready ships ONE bespoke look (renderer/bedready/ + bedready-theme.css)
    // and no design picker. It no longer borrows a Khayt theme id to get there —
    // applyBodyClasses keys off the html marker — so there is nothing to pin.
    const design = reg()?.normalizeDesignId(settings?.designTheme || 'khayt') || 'khayt';
    const accent = reg()?.normalizeAccent(design, settings?.accent) || 'cyan';
    if (settings && settings.accent !== accent) settings.accent = accent;
    applyDesignTheme(design);
    applyAccent(accent, reg()?.accentsForTheme(design));
    applyLowStockColor(settings?.lowStockColor);
    syncDesignSettingsUi();
  }

/**
   * Recolour "low stock" without touching every other warning.
   *
   * Requested in issue #364 item 2. --low-stock exists precisely so this is
   * possible: --warning also colours overdue jobs, spool age and a dozen other
   * things, so setting that would have recoloured all of them.
   *
   * Applied AFTER applyDesignTheme, which rewrites the token block — setting it
   * before would be silently overwritten by the theme. An empty or unusable
   * value clears the override and lets the theme default stand, so a shop can
   * always get back to stock behaviour.
   */
  function applyLowStockColor(color) {
    const root = document.documentElement;
    const safe = (typeof safeCssColor === "function") ? safeCssColor(color, "") : String(color || "");
    if (safe) root.style.setProperty("--low-stock", safe);
    else root.style.removeProperty("--low-stock");
  }

  /**
   * The colour low stock takes when the shop has NOT chosen one.
   *
   * Read from --warning, not from a literal: --low-stock aliases it (see
   * styles.css) and every theme darkens it for light appearance, so a
   * hardcoded #f5a623 would make the settings swatch show bright amber while
   * the inventory tab renders the theme's dark one — a picker that lies about
   * the colour in force.
   *
   * Deliberately NOT read from --low-stock itself: once the shop sets an
   * override that token carries their choice, and the picker's notion of "the
   * default" would become their own colour — after which Reset could never get
   * back. --warning is never overridden by this feature, so it stays truthful.
   */
  function themeLowStockColor() {
    const v = getComputedStyle(document.documentElement).getPropertyValue('--warning').trim();
    return (typeof safeCssColor === 'function') ? safeCssColor(v, '#f5a623') : (v || '#f5a623');
  }

  function syncDesignSettingsUi() {
    const designEl = document.getElementById('set_designTheme');
    const accentEl = document.getElementById('set_accent');
    const accentWrap = document.getElementById('set_accent_wrap');
    const comingSoonEl = document.getElementById('set_designTheme_coming_soon');
    const design = reg()?.normalizeDesignId(settings?.designTheme || 'khayt') || 'khayt';
    if (designEl) designEl.value = design;
    if (document.getElementById('set_designThemePicker')) {
      global.KhaytThemePicker?.mountSettingsPicker?.();
    }
    populateAccentSelect(design);
    const accent = reg()?.normalizeAccent(design, settings?.accent);
    if (accentEl) accentEl.value = accent;
    if (accentWrap) accentWrap.style.display = '';
    if (comingSoonEl && reg()?.listComingSoonThemes) {
      const soon = reg().listComingSoonThemes();
      comingSoonEl.textContent = soon.length
        ? tr('theme.design.coming_soon', 'More themes coming soon:') + ' ' + soon.map((id) => tr(reg().getTheme(id).labelKey, id)).join(', ')
        : '';
    }
    // The low-stock swatch shows the theme's colour when the shop has not
    // chosen one, so a theme change has to repaint it — otherwise switching
    // theme with Settings open leaves it advertising the previous theme's
    // amber. Only when unset: a shop's own colour must survive a theme change.
    const lsc = document.getElementById('set_lowStockColor');
    if (lsc && !settings?.lowStockColor) lsc.value = themeLowStockColor();
  }

  function populateDesignSelects() {
    if (!reg()) return;
    global.KhaytThemePicker?.mountSettingsPicker?.();
    populateAccentSelect(reg().normalizeDesignId(settings?.designTheme || 'khayt'));
  }

  function populateAccentSelect(designId) {
    const accentEl = document.getElementById('set_accent');
    if (!accentEl || !reg()) return;
    const design = reg().normalizeDesignId(designId);
    const set = reg().accentsForTheme(design);
    accentEl.innerHTML = Object.entries(set).map(([id, a]) =>
      `<option value="${id}">${escapeHtml(tr(a.labelKey, a.label || id))}</option>`,
    ).join('');
  }

  const api = {
    applyAccent,
    applyDesignTheme,
    applyDesignSettings,
    themeLowStockColor,
    syncDesignSettingsUi,
    populateDesignSelects,
    populateAccentSelect,
    normalizeDesign: (id) => reg()?.normalizeDesignId(id) || 'khayt',
    accentsForDesign: (id) => reg()?.accentsForTheme(id) || {},
    syncSidebarSubtitle,
    DESIGNS: reg()?.BUILTIN_THEMES,
  };

  Object.assign(global, api);
  global.KhaytThemes = api;
})(typeof window !== 'undefined' ? window : globalThis);
