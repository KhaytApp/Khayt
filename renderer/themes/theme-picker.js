/**
 * Visual theme picker — card grid with preview screenshots.
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
    if (theme?.label) return theme.label;
    return tr(theme?.labelKey, id);
  }

  function themeDesc(theme) {
    if (theme?.description) return theme.description;
    return tr(theme?.descKey, '');
  }

  function previewSrc(theme, id) {
    if (theme?.preview) return theme.preview;
    const base = reg()?.isCustomThemeId?.(id) ? `themes/custom/${reg().customIdFromTheme(id)}/preview.png` : `themes/previews/${id}.png`;
    return base;
  }

  /**
   * What a shop gives up, or gains, by choosing this design.
   *
   * The layouts are deliberately different screens, so switching does not only
   * change the look — it can remove a figure. Average margin is on two of the
   * eight. Someone who picked a design because they liked it had no way to learn
   * that until they went looking for a number that was no longer there.
   *
   * Only ever shown against the CURRENT choice, and only when something actually
   * changes: a card that costs nothing says nothing.
   */
  function tradeoffHtml(id, currentId) {
    const caps = global.KhaytThemeCapabilities;
    if (!caps || !currentId || id === currentId) return '';
    const { gained, lost } = caps.differenceBetween(currentId, id);
    const name = (c) => escapeHtml(tr('cap.' + c, (caps.CAPABILITIES[c] || {}).label || c));
    const bits = [];
    if (lost.length) {
      bits.push(`<span class="theme-picker-tradeoff lost">${escapeHtml(tr('theme.design.hides', 'Hides'))} ${lost.map(name).join(', ')}</span>`);
    }
    if (gained.length) {
      bits.push(`<span class="theme-picker-tradeoff gained">${escapeHtml(tr('theme.design.adds', 'Adds'))} ${gained.map(name).join(', ')}</span>`);
    }
    return bits.join('');
  }

  function cardHtml(id, theme, { selected, disabled, soon, currentId }) {
    const label = escapeHtml(themeLabel(theme, id));
    const desc = escapeHtml(themeDesc(theme));
    const src = escapeHtml(previewSrc(theme, id));
    const sel = selected ? ' selected' : '';
    const soonCls = soon ? ' is-soon' : '';
    const dis = disabled ? ' disabled' : '';
    const badge = soon
      ? `<span class="theme-picker-badge">${escapeHtml(tr('theme.design.soon_badge', 'Coming soon'))}</span>`
      : (selected ? `<span class="theme-picker-badge">${escapeHtml(tr('theme.design.selected_badge', 'Selected'))}</span>` : '');

    return `<button type="button" class="theme-picker-card${sel}${soonCls}" data-theme-id="${escapeHtml(id)}"${dis} role="radio" aria-checked="${selected ? 'true' : 'false'}" aria-label="${label}">
      <img class="theme-picker-shot" src="${src}" alt="" loading="lazy" />
      <span class="theme-picker-body">
        <strong>${label}</strong>
        <span>${desc}</span>
        ${tradeoffHtml(id, currentId)}
        ${badge}
      </span>
    </button>`;
  }

  function renderPicker(container, selectedId, { includeSoon = false } = {}) {
    if (!container || !reg()) return;
    const selectable = reg().listSelectableThemes();
    const soon = includeSoon ? reg().listComingSoonThemes() : [];
    const selected = reg().normalizeDesignId(selectedId || 'studio');

    let html = '';
    for (const id of selectable) {
      const theme = reg().getTheme(id);
      html += cardHtml(id, theme, { selected: id === selected, disabled: false, soon: false, currentId: selected });
    }
    for (const id of soon) {
      // Coming-soon themes are enabled:false, and getTheme() normalises that to
      // workbench — so every one of these cards drew Workbench's name and
      // description under a COMING SOON badge. Label from the raw definition.
      const theme = reg().getThemeDefinition(id) || reg().getTheme(id);
      html += cardHtml(id, theme, { selected: false, disabled: true, soon: true, currentId: selected });
    }

    container.innerHTML = html;
    container.setAttribute('role', 'radiogroup');
    container.setAttribute('aria-label', tr('theme.design.label', 'Design'));
    container.querySelectorAll('.theme-picker-shot').forEach((img) => {
      img.addEventListener('error', () => {
        const fb = document.createElement('div');
        fb.className = 'theme-picker-shot-fallback';
        fb.textContent = img.closest('.theme-picker-card')?.querySelector('strong')?.textContent || '';
        img.replaceWith(fb);
      }, { once: true });
    });
  }

  function bindPicker(container, { onSelect, livePreview = false } = {}) {
    if (!container || container.dataset.themePickerBound === '1') return;
    container.addEventListener('click', (e) => {
      const card = e.target.closest('.theme-picker-card[data-theme-id]');
      if (!card || card.disabled) return;
      const id = card.dataset.themeId;
      if (!id) return;

      container.querySelectorAll('.theme-picker-card').forEach((c) => {
        const on = c.dataset.themeId === id;
        c.classList.toggle('selected', on);
        c.setAttribute('aria-checked', on ? 'true' : 'false');
        const badge = c.querySelector('.theme-picker-badge');
        if (badge && !c.classList.contains('is-soon')) {
          badge.textContent = on ? tr('theme.design.selected_badge', 'Selected') : '';
          badge.style.display = on ? '' : 'none';
        }
      });

      const hidden = document.getElementById(container.dataset.syncInput);
      if (hidden) hidden.value = id;

      if (livePreview && typeof settings !== 'undefined') {
        const prev = settings.designTheme;
        settings.designTheme = id;
        const theme = reg()?.getTheme(id);
        if (theme?.defaultAppearance && prev !== id) {
          settings.theme = theme.defaultAppearance;
          if (typeof applyTheme === 'function') applyTheme(theme.defaultAppearance);
          const themeSel = document.getElementById('set_theme');
          if (themeSel) themeSel.value = theme.defaultAppearance;
        }
        if (typeof applyDesignSettings === 'function') applyDesignSettings();
      }

      if (typeof onSelect === 'function') onSelect(id);
    });
    container.dataset.themePickerBound = '1';
  }

  /* ── Installed designs ──────────────────────────────────────────────────
   *
   * A design a shop installed is not the same kind of thing as one Khayt ships:
   * it came from somewhere, it can be removed, and it can turn out to be broken
   * after the fact — the CSS is re-checked on every read, so a file edited on
   * disk stops loading without anything having been uninstalled.
   *
   * All three facts belong on screen. A theme that silently stops working, with
   * a picker that still lists it as available, is the shape of bug that gets
   * reported as "the app forgot my design".
   */
  function installedRowHtml(t) {
    const name = escapeHtml(t.name || t.id);
    const by = t.author ? `<span class="ti-by">${escapeHtml(tr('theme.design.by', 'by'))} ${escapeHtml(t.author)}</span>` : '';
    const state = t.broken
      ? `<span class="ti-broken">${escapeHtml(tr('theme.design.broken', 'will not load — the file changed or is damaged'))}</span>`
      : '';
    return `<div class="theme-installed-row${t.broken ? ' is-broken' : ''}" data-theme-id="${escapeHtml(t.id)}">
      <span class="ti-name"><strong>${name}</strong>${by}${state}</span>
      <button type="button" class="btn small ghost themeRemove" data-theme-id="${escapeHtml(t.id)}">${escapeHtml(tr('theme.design.remove', 'Remove'))}</button>
    </div>`;
  }

  async function renderInstalledSection(host, currentId) {
    const api = global.hubAPI;
    if (!host || !api || typeof api.themesList !== 'function') return;
    let themes = [];
    try { themes = ((await api.themesList()) || {}).themes || []; } catch (e) { themes = []; }

    host.innerHTML = `
      <div class="theme-installed-head">
        <span>${escapeHtml(tr('theme.design.installed', 'Your designs'))}</span>
        <button type="button" class="btn small themeInstall">${escapeHtml(tr('theme.design.install', 'Install a design…'))}</button>
      </div>
      ${themes.length
        ? themes.map(installedRowHtml).join('')
        : `<p class="theme-installed-empty">${escapeHtml(tr('theme.design.none_installed', 'None yet. A design is a single .khayttheme file — install one to add it to the grid above.'))}</p>`}
      <div class="theme-installed-result" role="status" aria-live="polite"></div>`;

    const say = (msg, bad) => {
      const r = host.querySelector('.theme-installed-result');
      if (!r) return;
      r.textContent = msg;
      r.style.color = bad ? 'var(--danger)' : 'var(--success)';
    };

    host.querySelector('.themeInstall')?.addEventListener('click', async () => {
      try {
        // One call: the main process picks, reads and installs. The renderer
        // never gets a path, and Khayt never grows a general "read any file"
        // capability just to support a stylesheet.
        const res = await api.themesInstallFile();
        if (res && res.canceled) return;
        if (!res || !res.ok) {
          // The refusal is the useful part: it says which line of somebody's CSS
          // is the problem, so an author can fix it rather than guess.
          return say((res && res.error) || tr('theme.design.refused', 'That design was refused.'), true);
        }
        say(tr('theme.design.installed_ok', 'Installed. It is in the grid above.'));
        await renderInstalledSection(host, currentId);
        mountSettingsPicker();
      } catch (e) {
        say(String((e && e.message) || e), true);
      }
    });

    host.querySelectorAll('.themeRemove').forEach((btn) => btn.addEventListener('click', async () => {
      const id = btn.dataset.themeId;
      try {
        const res = await api.themesRemove({ id });
        if (!res || !res.ok) return say((res && res.error) || 'Could not remove that design.', true);
        // Removing the design in use would leave the app styled by a theme that
        // no longer exists, so hand it back to the default first.
        if (typeof settings !== 'undefined' && settings.designTheme === `custom:${id}`) {
          settings.designTheme = 'khayt';
          if (typeof saveAll === 'function') saveAll();
        }
        say(tr('theme.design.removed', 'Removed.'));
        await renderInstalledSection(host, currentId);
        mountSettingsPicker();
      } catch (e) { say(String((e && e.message) || e), true); }
    }));
  }

  function mountSettingsPicker() {
    const container = document.getElementById('set_designThemePicker');
    const hidden = document.getElementById('set_designTheme');
    if (!container) return;
    if (hidden) container.dataset.syncInput = 'set_designTheme';
    const design = reg()?.normalizeDesignId(settings?.designTheme || hidden?.value || 'studio') || 'studio';
    renderPicker(container, design, { includeSoon: true });
    bindPicker(container, {
      livePreview: true,
      onSelect(id) {
        if (typeof settings !== 'undefined') settings.designTheme = id;
        const hint = document.getElementById('set_designTheme_hint');
        const theme = reg()?.getTheme(id);
        if (hint && theme?.descKey) hint.textContent = tr(theme.descKey, hint.textContent);
        if (hidden) hidden.value = id;
        if (typeof populateAccentSelect === 'function') populateAccentSelect(id);
        if (typeof saveAll === 'function') saveAll();
        if (typeof toast === 'function') toast(tr('set.saved', 'Saved'), 'success', 2000);
      },
    });

    // The install/remove surface sits under the grid, created on demand so the
    // markup stays where the picker is rather than in index.html.
    let installed = document.getElementById('set_designThemeInstalled');
    if (!installed) {
      installed = document.createElement('div');
      installed.id = 'set_designThemeInstalled';
      installed.className = 'theme-installed';
      container.insertAdjacentElement('afterend', installed);
    }
    renderInstalledSection(installed, design);
  }

  function mountWizardPicker(container, selectedId) {
    if (!container) return;
    renderPicker(container, selectedId || 'studio', { includeSoon: false });
    bindPicker(container, {
      livePreview: true,
      onSelect(id) {
        container.dataset.selectedTheme = id;
      },
    });
    container.dataset.selectedTheme = reg()?.normalizeDesignId(selectedId || 'studio') || 'studio';
  }

  function getWizardSelection(container) {
    return container?.dataset.selectedTheme || 'studio';
  }

  global.KhaytThemePicker = {
    renderPicker,
    bindPicker,
    mountSettingsPicker,
    mountWizardPicker,
    renderInstalledSection,
    installedRowHtml,
    getWizardSelection,
    previewSrc,
  };
})(typeof window !== 'undefined' ? window : globalThis);
