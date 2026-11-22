'use strict';
/*
 * Colour Studio (3.1) — the Colour Mixer the maker asked for (BedReady-style), personal
 * core so it's available in every mode incl. enthusiast. Two panels:
 *
 *   • Matcher   — pick a target colour → the closest-matching filaments IN STOCK,
 *                 ranked by perceptual distance (ΔE / CIEDE2000).
 *   • Blend     — mix two filaments/hexes and build an N-step gradient (ombré / swap
 *                 plans), each step annotated with its nearest in-stock filament.
 *
 * The multicolour print planner (assign a file's colours → filaments → cost) is
 * contextual — launched from a print-file library card (see renderer/color-planner.js).
 *
 * All colour maths lives in lib/color-mix.js (global KhaytColor). No DOM there; no network
 * here. Reads the live `inventory` collection (bare global) at render time.
 */
(function (global) {
  const KC = () => global.KhaytColor;

  // Inventory filaments that carry a usable hex colour (name-only colours are skipped).
  function coloredFilaments() {
    const list = Array.isArray(inventory) ? inventory : [];
    const kc = KC();
    return kc ? list.filter((it) => it && kc.hexToRgb(it.color)) : [];
  }

  function filamentLabel(it) {
    return [it.material, it.colourVariant].filter(Boolean).join(' — ')
      || (t('cmix.filament') || 'Filament');
  }

  function swatch(hex, size) {
    const s = size || 16;
    return `<span class="cs-swatch" style="background:${safeCssColor(hex, '#888')};width:${s}px;height:${s}px;"></span>`;
  }

  function filamentOptions() {
    return coloredFilaments()
      .map((it) => `<option value="${escapeHtml(it.color)}">${escapeHtml(filamentLabel(it))}</option>`)
      .join('');
  }

  function qualityClass(de) {
    return de < 2 ? 'exact' : de < 5 ? 'close' : de < 12 ? 'ok' : 'far';
  }

  // Bundled reference swatches (Bed Ready only; absent in Khayt) as extra match candidates, so the
  // matcher answers "closest known filament" even with an empty inventory. Cached; matched via the `hex` key.
  let _catalog = null;
  function catalogCands() {
    if (_catalog) return _catalog;
    const src = Array.isArray(global.BedReadyFilamentSwatches) ? global.BedReadyFilamentSwatches : [];
    const kc = KC();
    _catalog = kc ? src.filter((s) => s && kc.hexToRgb(s.hex)) : [];
    return _catalog;
  }
  const catalogLabel = (s) => [s.brand, s.name].filter(Boolean).join(' ') || (s.name || 'Filament');
  const groupLbl = (txt) => `<div class="cs-group-lbl" style="font-size:11px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;color:var(--text-muted,#869390);margin:12px 0 6px;">${escapeHtml(txt)}</div>`;

  function invRow(r) {
    const low = (typeof isLowStock === 'function' && isLowStock(r));
    return `<div class="cs-row" data-hex="${escapeHtml(r.color)}" title="${escapeHtml(t('cmix.copy') || 'Copy hex')}">
      ${swatch(r.color, 26)}
      <div class="cs-row-main">
        <div class="cs-row-name">${escapeHtml(filamentLabel(r))}</div>
        <div class="cs-row-sub">${escapeHtml(String(r.color).toUpperCase())} · ${Math.round(+r.weight || 0)} g${low ? ` · <span class="cs-low">${escapeHtml(t('cmix.low') || 'Low')}</span>` : ''}</div>
      </div>
      <span class="cs-de cs-de-${qualityClass(r.deltaE)}" title="ΔE (CIEDE2000)">ΔE ${r.deltaE.toFixed(1)}</span>
    </div>`;
  }
  function catRow(r) {
    return `<div class="cs-row" data-hex="${escapeHtml(r.hex)}" title="${escapeHtml(t('cmix.copy') || 'Copy hex')}">
      ${swatch(r.hex, 26)}
      <div class="cs-row-main">
        <div class="cs-row-name">${escapeHtml(catalogLabel(r))}</div>
        <div class="cs-row-sub">${escapeHtml(String(r.hex).toUpperCase())}${r.material ? ' · ' + escapeHtml(r.material) : ''}</div>
      </div>
      <span class="cs-de cs-de-${qualityClass(r.deltaE)}" title="ΔE (CIEDE2000)">ΔE ${r.deltaE.toFixed(1)}</span>
    </div>`;
  }

  // ---- state (persists across re-renders within a session) ----
  // Seed the demo gradient with the app's own accent pair so the first open
  // reinforces the brand: Bed Ready → teal→orange, Khayt → its red→blue.
  const _isBedReady = (typeof document !== 'undefined' && document.documentElement.dataset.app === 'bedready');
  let _target = _isBedReady ? '#19A99F' : '#3AA0FF';
  let _blendA = _isBedReady ? '#19A99F' : '#E23B3B';
  let _blendB = _isBedReady ? '#FF6A3D' : '#2C63E8';
  let _steps = 5;

  function shellHtml() {
    const opts = filamentOptions();
    const fromSel = (id) => opts
      ? `<select id="${id}" class="cs-from"><option value="">${escapeHtml(t('cmix.from_filament') || 'From filament…')}</option>${opts}</select>`
      : '';
    return `
      <div class="cs-head">
        <h2 class="cs-title">${_isBedReady ? '' : '🎨 '}${escapeHtml(t('cmix.title') || 'Colour studio')}</h2>
        <p class="cs-sub">${escapeHtml(t('cmix.subtitle') || 'Match a colour to filament you already own, or blend two spools into a gradient.')}</p>
      </div>
      <div class="cs-grid">
        <section class="cs-card">
          <h3 class="cs-card-title">${escapeHtml(t('cmix.matcher.title') || 'Closest filament in stock')}</h3>
          <p class="cs-card-hint">${escapeHtml(t('cmix.matcher.hint') || 'Pick a target colour — filaments are ranked by how close they look (ΔE).')}</p>
          <div class="cs-pickrow">
            <input type="color" id="csTargetColor" class="cs-color" value="${escapeHtml(_target)}" aria-label="${escapeHtml(t('cmix.target') || 'Target colour')}">
            <input type="text" id="csTargetHex" class="cs-hex-input" value="${escapeHtml(_target.toUpperCase())}" spellcheck="false" maxlength="7" aria-label="${escapeHtml(t('cmix.target') || 'Target colour')}">
            ${fromSel('csTargetFrom')}
          </div>
          <div id="csMatchResults" class="cs-results"></div>
        </section>

        <section class="cs-card">
          <h3 class="cs-card-title">${escapeHtml(t('cmix.blend.title') || 'Blend & gradient')}</h3>
          <p class="cs-card-hint">${escapeHtml(t('cmix.blend.hint') || 'Mix two colours (gamma-correct) and build an N-step gradient for ombré or colour-swap plans.')}</p>
          <div class="cs-pickrow">
            <input type="color" id="csBlendAColor" class="cs-color" value="${escapeHtml(_blendA)}" aria-label="A">
            <input type="text" id="csBlendAHex" class="cs-hex-input" value="${escapeHtml(_blendA.toUpperCase())}" spellcheck="false" maxlength="7" aria-label="A">
            ${fromSel('csBlendAFrom')}
          </div>
          <div class="cs-pickrow">
            <input type="color" id="csBlendBColor" class="cs-color" value="${escapeHtml(_blendB)}" aria-label="B">
            <input type="text" id="csBlendBHex" class="cs-hex-input" value="${escapeHtml(_blendB.toUpperCase())}" spellcheck="false" maxlength="7" aria-label="B">
            ${fromSel('csBlendBFrom')}
          </div>
          <div class="cs-midrow">
            <label class="cs-steps-lbl">${escapeHtml(t('cmix.steps') || 'Steps')}
              <input type="range" id="csSteps" min="2" max="10" step="1" value="${_steps}">
              <span id="csStepsN" class="cs-steps-n">${_steps}</span>
            </label>
            <div class="cs-mid"><span class="cs-mid-lbl">${escapeHtml(t('cmix.midpoint') || '50/50')}</span><span id="csBlendMid"></span></div>
          </div>
          <div id="csGradient" class="cs-gradient"></div>
        </section>
      </div>
      ${plannerCardHtml()}`;
  }

  // Files in the library with more than one colour can be planned into a costed part.
  function plannableFiles() {
    return (Array.isArray(printFiles) ? printFiles : [])
      .filter((r) => Array.isArray(r.colors) && r.colors.filter((c) => c && c.hex).length > 1);
  }

  function plannerCardHtml() {
    const files = plannableFiles();
    if (!files.length) return '';
    const rows = files.slice(0, 24).map((r) => {
      const dots = r.colors.filter((c) => c && c.hex).slice(0, 8)
        .map((c) => `<span class="pf-dot" style="background:${safeCssColor(c.hex)}" title="${escapeHtml(c.label || c.hex)}"></span>`).join('');
      return `<div class="cs-plan-row">
        <div class="cs-plan-dots">${dots}</div>
        <div class="cs-plan-name">${escapeHtml(r.name || r.originalName || 'Untitled')}</div>
        <button class="btn small ghost" data-plan-id="${escapeHtml(r.id)}">🎨 ${escapeHtml(t('plan.title') || 'Plan colours')}</button>
      </div>`;
    }).join('');
    return `<section class="cs-card cs-plan-card">
      <h3 class="cs-card-title">${escapeHtml(t('plan.files_title') || 'Multicolour files')}</h3>
      <p class="cs-card-hint">${escapeHtml(t('plan.files_hint') || 'Assign filaments to each colour and push the job to the cost calculator.')}</p>
      ${rows}
    </section>`;
  }

  // ── ΔE colorimeter plot (Cyanotype Draft signature, Bed Ready only) ──────────
  // Plots the target colour and your candidate filaments on the CIE a*b* chroma
  // plane, dramatising the app's real ΔE math. Uses theme CSS vars so it tracks
  // light/dark. Lightness (L*) is not shown here — the CIEDE2000 ΔE in the list
  // is the true distance; this is the hue/chroma view.
  function abPlot(kc, targetHex, pts) {
    const tl = kc.hexToLab && kc.hexToLab(targetHex);
    if (!tl) return '';
    const D = 72, S = 220, M = 30, half = (S - 2 * M) / 2, c = S / 2;
    const clamp = (v) => Math.max(-1, Math.min(1, v / D));
    const px = (lab) => c + clamp(lab.a) * half;
    const py = (lab) => c - clamp(lab.b) * half; // +b* (yellow) points up
    const tx = px(tl).toFixed(1), ty = py(tl).toFixed(1);
    const ringR = ((8 / D) * half).toFixed(1); // ~ close-match zone (indicative)
    const dots = pts.map((p) => {
      const l = kc.hexToLab(p.hex); if (!l) return '';
      const x = px(l).toFixed(1), y = py(l).toFixed(1);
      const best = p === pts[0];
      return `<circle cx="${x}" cy="${y}" r="${best ? 5 : 4}" fill="${safeCssColor(p.hex)}" stroke="var(--surface)" stroke-width="1.2"/>` +
        (best ? `<circle cx="${x}" cy="${y}" r="7.5" fill="none" stroke="var(--accent)" stroke-width="1.2"/>` : '');
    }).join('');
    const g = (a, b) => `${px({ a, b }).toFixed(1)} ${py({ a, b }).toFixed(1)}`;
    return `<svg viewBox="0 0 ${S} ${S}" class="cs-abplot-svg" role="img" aria-label="CIE a* b* chroma plot: target colour and nearest filaments">
      <rect x="${M}" y="${M}" width="${2 * half}" height="${2 * half}" fill="none" stroke="var(--border-2)"/>
      <g stroke="var(--grid)" stroke-width="1">
        <line x1="${M}" y1="${c - half / 2}" x2="${S - M}" y2="${c - half / 2}"/>
        <line x1="${M}" y1="${c + half / 2}" x2="${S - M}" y2="${c + half / 2}"/>
        <line x1="${c - half / 2}" y1="${M}" x2="${c - half / 2}" y2="${S - M}"/>
        <line x1="${c + half / 2}" y1="${M}" x2="${c + half / 2}" y2="${S - M}"/>
      </g>
      <line x1="${M}" y1="${c}" x2="${S - M}" y2="${c}" stroke="var(--l1)" stroke-width="1.4" opacity="0.5"/>
      <line x1="${c}" y1="${M}" x2="${c}" y2="${S - M}" stroke="var(--l5)" stroke-width="1.4" opacity="0.5"/>
      <text x="${S - M + 3}" y="${c + 3}" class="cs-abplot-ax">+a*</text>
      <text x="${c}" y="${M - 6}" text-anchor="middle" class="cs-abplot-ax">+b*</text>
      <circle cx="${tx}" cy="${ty}" r="${ringR}" fill="none" stroke="var(--accent)" stroke-width="1.1" stroke-dasharray="3 3"/>
      ${dots}
      <circle cx="${tx}" cy="${ty}" r="4" fill="var(--accent)"/>
      <path d="M${tx} ${ty - 9}v-4M${tx} ${(+ty) + 9}v4M${tx - 9} ${ty}h-4M${(+tx) + 9} ${ty}h4" stroke="var(--accent)" stroke-width="1.2"/>
    </svg>`;
  }

  function abPlotHtml(kc, pts) {
    if (!_isBedReady || !pts.length) return '';
    const best = pts[0];
    const near = best ? `<span class="cs-abplot-best"><b style="color:var(--accent)">✦</b> ${escapeHtml(best.label)} · <span class="cs-de cs-de-${qualityClass(best.deltaE)}">ΔE ${best.deltaE.toFixed(1)}</span></span>` : '';
    return `<div class="cs-abplot">
      <div class="cs-abplot-head">${escapeHtml(t('cmix.plot_title') || 'ΔE map · a*b* chroma plane')}${near}</div>
      ${abPlot(kc, _target, pts)}
      <p class="cs-abplot-cap">${escapeHtml(t('cmix.plot_cap') || 'Crosshair = target; dots = your filaments; ringed dot = closest. Dashed ring ≈ close-match zone. L* not shown — the CIEDE2000 ΔE below is the true distance.')}</p>
    </div>`;
  }

  function updateMatcher() {
    const box = document.getElementById('csMatchResults');
    const kc = KC();
    if (!box || !kc) return;
    const inv = coloredFilaments();
    const cat = catalogCands();
    if (!inv.length && !cat.length) {
      box.innerHTML = `<p class="cs-empty">${escapeHtml(t('cmix.no_filaments') || 'No filaments with a hex colour yet — set a colour on a filament in Inventory.')}</p>`;
      return;
    }
    let html = '';
    const plotPts = [];
    if (inv.length) {
      const ranked = kc.nearest(_target, inv, { limit: cat.length ? 8 : 12 });
      ranked.forEach((r) => plotPts.push({ hex: r.color, deltaE: r.deltaE, label: filamentLabel(r) }));
      if (cat.length) html += groupLbl(t('cmix.from_stock') || 'In your inventory');
      html += ranked.map(invRow).join('');
    }
    if (cat.length) {
      const ranked = kc.nearest(_target, cat, { key: 'hex', limit: inv.length ? 6 : 12 });
      ranked.forEach((r) => plotPts.push({ hex: r.hex, deltaE: r.deltaE, label: catalogLabel(r) }));
      html += groupLbl(t('cmix.from_catalog') || 'Closest known filaments');
      html += ranked.map(catRow).join('');
      if (!inv.length) html += `<p class="cs-hint-sm" style="font-size:12px;color:var(--text-muted,#869390);margin:8px 0 0;">${escapeHtml(t('cmix.catalog_hint') || 'Add a colour to a filament in Inventory to match against your own stock and get exact grams.')}</p>`;
    }
    plotPts.sort((a, b) => a.deltaE - b.deltaE);
    box.innerHTML = abPlotHtml(kc, plotPts.slice(0, 8)) + html;
  }

  function updateBlend() {
    const kc = KC();
    const strip = document.getElementById('csGradient');
    const mid = document.getElementById('csBlendMid');
    if (!strip || !kc) return;
    const cands = coloredFilaments();
    const cat = cands.length ? null : catalogCands(); // fall back to the reference library when stock is empty
    const bl = kc.blend(_blendA, _blendB, 0.5);
    if (mid) mid.innerHTML = bl ? `${swatch(bl, 22)}<span class="cs-hex" data-hex="${bl}" title="${escapeHtml(t('cmix.copy') || 'Copy hex')}">${bl}</span>` : '';
    const g = kc.gradient(_blendA, _blendB, _steps);
    strip.innerHTML = g.map((hex) => {
      const near = cands.length ? kc.nearest(hex, cands, { limit: 1 })[0]
        : (cat && cat.length ? kc.nearest(hex, cat, { key: 'hex', limit: 1 })[0] : null);
      const nearTxt = near ? `${cands.length ? filamentLabel(near) : catalogLabel(near)} · ΔE ${near.deltaE.toFixed(1)}` : '';
      return `<div class="cs-step" data-hex="${escapeHtml(hex)}" title="${escapeHtml((t('cmix.copy') || 'Copy hex') + (nearTxt ? ' · ' + nearTxt : ''))}">
        <span class="cs-step-sw" style="background:${safeCssColor(hex)}"></span>
        <span class="cs-step-hex">${escapeHtml(hex)}</span>
        <span class="cs-step-near">${escapeHtml(nearTxt)}</span>
      </div>`;
    }).join('');
  }

  // Two-way sync between a <input type=color> and a hex text field; updates on change.
  function bindPair(colorId, hexId, fromId, set, after) {
    const kc = KC();
    const c = document.getElementById(colorId);
    const h = document.getElementById(hexId);
    const f = fromId && document.getElementById(fromId);
    if (c) c.oninput = () => { set(c.value); if (h) h.value = c.value.toUpperCase(); after(); };
    if (h) h.oninput = () => {
      const rgb = kc && kc.hexToRgb(h.value);
      if (!rgb) return; // wait for a valid hex; don't fight the user mid-type
      const hex = kc.rgbToHex(rgb.r, rgb.g, rgb.b);
      set(hex); if (c) c.value = hex; after();
    };
    if (f) f.onchange = () => {
      if (!f.value) return;
      // Inventory colours may be #abc or #rrggbbaa; normalise to a 6-digit hex so
      // the native <input type="color"> swatch actually updates.
      const rgb = kc && kc.hexToRgb(f.value);
      const hex = rgb ? kc.rgbToHex(rgb.r, rgb.g, rgb.b) : f.value;
      set(hex); if (c) c.value = hex; if (h) h.value = hex.toUpperCase();
      f.selectedIndex = 0; after();
    };
  }

  function renderColorStudio() {
    const host = document.getElementById('colorstudio-tab');
    if (!host) return;
    host.innerHTML = shellHtml();

    bindPair('csTargetColor', 'csTargetHex', 'csTargetFrom', (v) => { _target = v; }, updateMatcher);
    bindPair('csBlendAColor', 'csBlendAHex', 'csBlendAFrom', (v) => { _blendA = v; }, updateBlend);
    bindPair('csBlendBColor', 'csBlendBHex', 'csBlendBFrom', (v) => { _blendB = v; }, updateBlend);

    const steps = document.getElementById('csSteps');
    const stepsN = document.getElementById('csStepsN');
    if (steps) steps.oninput = () => { _steps = +steps.value; if (stepsN) stepsN.textContent = _steps; updateBlend(); };

    // Click any swatch/step/row to copy its hex, or a "Plan colours" button to launch the planner.
    host.onclick = (e) => {
      const planBtn = e.target.closest('[data-plan-id]');
      if (planBtn) {
        const rec = (Array.isArray(printFiles) ? printFiles : []).find((r) => r.id === planBtn.getAttribute('data-plan-id'));
        if (rec && typeof openColorPlanner === 'function') openColorPlanner(rec);
        return;
      }
      const el = e.target.closest('[data-hex]');
      if (!el) return;
      const hex = el.getAttribute('data-hex');
      if (!hex) return;
      copyText(hex.toUpperCase()).then((ok) => {
        if (ok) toast((t('cmix.copied') || 'Copied') + ' ' + hex.toUpperCase(), 'success', 1600);
        else toast(t('common.copy_failed') || 'Copy failed', 'warning');
      });
    };

    updateMatcher();
    updateBlend();
  }

  const pub = { renderColorStudio };
  Object.assign(global, pub);
  global.KhaytColorStudio = pub;
  if (typeof module !== 'undefined' && module.exports) module.exports = pub;
})(typeof globalThis !== 'undefined' ? globalThis : this);
