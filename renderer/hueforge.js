'use strict';
/*
 * HueForge · U1 — Bed Ready's filament-painting studio (Cyanotype Draft).
 *
 * Drop an image → the app auto-picks a filament palette from what you own, builds the
 * layered "filament painting" (a relief whose per-pixel height, swapped through the
 * stack, reproduces the picture via light transmission), and shows exactly how it will
 * print on a Snapmaker U1. You can retune every filament (colour / TD / band thickness),
 * reorder the stack, and see the U1 verdict (≤4 colours = fully automatic on the 4
 * SnapSwap heads; more = mid-print reloads).
 *
 * This module is the UI. All colour + relief maths is in lib/hueforge.js (KhaytHueForge)
 * over lib/color-mix.js (KhaytColor). Reads the live `inventory` global for palette
 * suggestions. Bed Ready only (bedready.html ships this tab).
 *
 * v1 = design + live preview + print plan. The zero-slicer U1 3MF export lands next.
 */
(function (global) {
  const KC = () => global.KhaytColor;
  const HF = () => global.KhaytHueForge;
  const FLAT = () => global.KhaytHueForgeFlat;
  const CAL = () => global.KhaytHueForgeCalibrate;
  const CAL_PHOTO_MAX = 1600; // longest side (px) a card photo is read at — enough for 8 mm cells
  const isFlat = () => S && S.mode === 'flat';
  const U1_ID = 'snapmaker-u1';
  const WORK_MAX = 640; // longest side (px) of the working image; the solver then samples to
  //                       ~nozzle resolution (see planPainting cellMm). 180 was below nozzle
  //                       width → soft + fine detail broke into speckle; feed full detail.

  let S = null; // session state
  let _rafPending = false;

  function defaults() {
    return { mode: 'relief', img: null, imgUrl: '', imgName: '', filaments: [], layerH: 0.08, baseLayers: 5, maxColors: 4, widthMm: 120, heightMm: 2.4, dither: false, vivid: 9, smooth: 0, stack: null, solve: null, plan: null, paint: null, flat: null };
  }
  const LAYER_PRESETS = [[0.04, 'ultra'], [0.08, 'recommended'], [0.12, 'faster'], [0.16, 'fast']];

  function u1Profile() { const P = global.KhaytPrinterProfiles; return P ? P.getProfile(U1_ID) : null; }
  function esc(s) { return (typeof escapeHtml === 'function') ? escapeHtml(String(s == null ? '' : s)) : String(s == null ? '' : s); }
  function css(hex, fb) { return (typeof safeCssColor === 'function') ? safeCssColor(hex, fb || '#888') : (hex || fb || '#888'); }
  function ico(name, size) { return (global.BedReadyIcons) ? global.BedReadyIcons.get(name, size || 15) : ''; }

  function ownedColored() {
    const inv = Array.isArray(global.inventory) ? global.inventory : [];
    const kc = KC();
    return kc ? inv.filter((i) => i && i.color && kc.hexToRgb(i.color) && (i.weight == null || i.weight > 0)) : [];
  }

  // ---- image intake -------------------------------------------------------

  function loadImageFile(file) {
    if (!file || !/^image\//.test(file.type)) return;
    const reader = new FileReader();
    reader.onload = () => {
      const img = new Image();
      img.onload = () => {
        const scale = Math.min(1, WORK_MAX / Math.max(img.width, img.height));
        const w = Math.max(1, Math.round(img.width * scale));
        const h = Math.max(1, Math.round(img.height * scale));
        const cv = document.createElement('canvas');
        cv.width = w; cv.height = h;
        const ctx = cv.getContext('2d');
        ctx.drawImage(img, 0, 0, w, h);
        S.img = ctx.getImageData(0, 0, w, h);
        S.imgUrl = reader.result;
        S.imgName = file.name || 'image';
        autoPalette();
        render();
      };
      img.src = reader.result;
    };
    reader.readAsDataURL(file);
  }

  function autoPalette() {
    const hf = HF();
    if (!hf || !S.img) return;
    S.filaments = hf.suggestFilaments(S.img, ownedColored(), S.maxColors);
    // opaque foundation (~0.4 mm) so the bed never bleeds through the bottom colour.
    // A fixed depth rather than the relief path's TD×1.3: planPainting composites the whole
    // stack itself, so the foundation only has to stop the bed showing — it is not the first
    // term of a transmission model any more.
    S.baseLayers = clampNum(Math.round(0.4 / S.layerH), 2, 20, 5);
    // No recompute() here — render() does it now, for every path that changes the stack
    // rather than only the ones that remembered to.
  }

  // ---- compute ------------------------------------------------------------

  function recompute() {
    const hf = HF();
    if (!hf || !S.filaments.length || !S.img) { S.stack = S.solve = S.plan = S.paint = S.flat = null; return; }
    if (isFlat()) { recomputeFlat(); return; }
    S.flat = null;
    // Optimised per-layer painting: learn a filament sequence (reuse allowed) that
    // reproduces the image via the transmission model — the U1's free tool-changes make
    // the many swaps automatic. Falls back to nothing if no valid filaments.
    const paint = hf.planPainting(S.img, S.filaments, {
      layerH: S.layerH, heightMm: S.heightMm, widthMm: S.widthMm,
      baseLayers: S.baseLayers, dither: S.dither === true,
      // vividness → front-lit TD scale (higher vivid = more opaque = more saturated pop)
      tdScale: Math.max(0.1, 1.1 - (S.vivid || 9) * 0.1),
      smooth: S.smooth || 0,
    });
    S.paint = paint;
    S.solve = paint ? paint.solve : null;
    if (!paint) { S.stack = S.plan = null; return; }
    // Compat shim: present the optimised plan through the shapes the elevation/verdict/plan
    // UI already reads (S.stack.bands + S.plan). Each contiguous run is a "band"; a reused
    // filament yields several bands on the same head. On the U1 (≤4 loaded) it's always
    // fully automatic — every swap is a free tool-change, no manual reloads.
    const lh = paint.layerH;
    const bands = paint.bands.map((b) => {
      const startLayer = Math.round(b.z0 / lh) + 1;
      const endLayer = Math.round(b.z1 / lh);
      const fil = S.filaments[b.head];
      const td = fil ? (fil.td || hf.defaultTd(b.hex)) : hf.defaultTd(b.hex);
      return { hex: b.hex, td, head: b.head, startLayer, endLayer, layers: Math.max(1, endLayer - startLayer + 1) };
    });
    const distinct = new Set(paint.seq).size;
    S.stack = { bands, totalLayers: paint.totalLayers, layerH: lh, palette: paint.palette };
    S.plan = {
      automatic: distinct <= hf.U1_HEADS,
      colorCount: distinct, heads: hf.U1_HEADS, swaps: paint.swaps,
      slots: bands.map((b) => ({ slot: b.head, band: b })),
      reloads: [],
    };
  }

  /**
   * Flat mode: quantise to <=4 solid colours and cut the plate into a base slab plus one cap
   * PART per colour. No transmission model, no relief — the U1's tool changes cost nothing,
   * so each region is simply printed in its own filament.
   *
   * The relief's derived values (stack/plan/paint) stay null here on purpose: they describe a
   * Z-band stack that a flat plate does not have, and leaving stale ones behind is how the
   * elevation ends up drawing a plan for a mode the maker has left.
   */
  function recomputeFlat() {
    const fl = FLAT();
    S.stack = S.plan = S.paint = S.solve = null;
    if (!fl) { S.flat = null; return; }
    S.flat = fl.planFlat(S.img, {
      colors: S.maxColors,
      widthMm: S.widthMm,
      heightMm: S.heightMm,
      filaments: S.filaments.map((f) => f.hex),
    });
  }

  function scheduleRepaint() {
    if (_rafPending) return;
    _rafPending = true;
    requestAnimationFrame(() => { _rafPending = false; recompute(); paint(); });
  }

  // ---- render -------------------------------------------------------------

  /**
   * Repaint the panel from the current filament list.
   *
   * The derived values — stack, solve, plan — are recomputed HERE rather than by
   * each handler that edits the stack. They were not, and every pane that reads
   * them drew the previous stack: reorder the list and the elevation kept the old
   * order, delete a filament and it stayed in the plan, add a fifth and the
   * one-click U1 export stayed enabled for a stack that no longer fits four heads.
   *
   * None of that stopped at the screen. `export3mf` reads the same three values,
   * so the 3MF written to disk carried the pre-edit stack — the wrong colours, in
   * the wrong order, with no sign anything was off until the print came out.
   *
   * Recomputing on the way to paint costs a solve per edit, which `scheduleRepaint`
   * already pays on every keystroke in a TD or layer field. Paying it here too is
   * what makes a stale plan unreachable instead of merely fixed in three places.
   */
  function render() {
    const host = document.getElementById('hueforge-tab');
    if (!host) return;
    if (!S) S = defaults();
    recompute();
    host.innerHTML = shellHtml();
    wire(host);
    paint();
  }

  function shellHtml() {
    return [
      '<div class="hf">',
      '<div class="hf-head">',
      '<div><h2 class="hf-title">HueForge <span class="hf-title-sep">·</span> U1 <span class="hf-title-sep">·</span> <span style="font-size:11px;opacity:.6;font-weight:600;letter-spacing:.02em">build 2026-07-15j · selective-sharp</span></h2>',
      '<p class="hf-sub">Turn a picture into a filament painting, built for the Snapmaker U1’s four SnapSwap heads.</p></div>',
      S.img ? '<button type="button" class="btn ghost sm" id="hfReset">Start over</button>' : '',
      '</div>',
      S.img ? bodyHtml() : dropHtml(),
      '<input type="file" id="hfFile" accept="image/*" hidden />',
      '</div>',
    ].join('');
  }

  function dropHtml() {
    return [
      '<div class="hf-drop" id="hfDrop" tabindex="0" role="button" aria-label="Add an image">',
      '<div class="hf-drop-mark" aria-hidden="true">' + ico('camera', 30) + '</div>',
      '<div class="hf-drop-t">Drop an image, or click to browse</div>',
      '<div class="hf-drop-h">JPG or PNG. Bed Ready picks the filaments and builds the relief — everything stays on your machine.</div>',
      '</div>',
    ].join('');
  }

  function bodyHtml() {
    return [
      '<div class="hf-body">',
      '<section class="hf-col hf-left">',
      sourceHtml(),
      paletteHtml(),
      isFlat() ? '' : calibrateHtml(),
      settingsHtml(),
      '</section>',
      '<section class="hf-col hf-right">',
      previewHtml(),
      elevationHtml(),
      verdictHtml(),
      exportHtml(),
      '</section>',
      '</div>',
    ].join('');
  }

  function sourceHtml() {
    return [
      '<div class="hf-card">',
      '<div class="hf-card-h">SOURCE</div>',
      '<div class="hf-src">',
      '<img class="hf-src-img" src="' + esc(S.imgUrl) + '" alt="source" />',
      '<div class="hf-src-meta"><div class="hf-src-name">' + esc(S.imgName) + '</div>',
      '<div class="hf-src-dim">' + (S.img ? S.img.width + '×' + S.img.height + ' px sampled' : '') + '</div>',
      '<button type="button" class="btn ghost xs" id="hfChange">Change image</button></div>',
      '</div></div>',
    ].join('');
  }

  function paletteHtml() {
    const owned = ownedColored().length;
    const rows = S.filaments.map((f, i) => filRow(f, i, S.filaments.length)).join('');
    return [
      '<div class="hf-card">',
      '<div class="hf-card-h">FILAMENT STACK <span class="hf-card-hx">bottom → top</span></div>',
      '<div class="hf-auto">',
      '<button type="button" class="btn sm" id="hfAuto">' + wrapIco('colour') + 'Auto-pick from image</button>',
      '<button type="button" class="btn ghost sm" id="hfTune" title="Optimise band thicknesses to best match the image">' + wrapIco('target') + 'Auto-tune</button>',
      '<label class="hf-inline">colours <select class="input xs" id="hfMaxColors">'
        + [3, 4, 5, 6].map((n) => '<option value="' + n + '"' + (n === S.maxColors ? ' selected' : '') + '>' + n + '</option>').join('')
        + '</select></label>',
      '</div>',
      owned ? '' : '<div class="hf-note">No colour filaments in your inventory yet — suggestions use the image’s own colours. Add spools in Inventory to match to what you own.</div>',
      '<div class="hf-stack" id="hfStack">' + (rows || '<div class="hf-empty">No filaments — auto-pick or add one.</div>') + '</div>',
      '<button type="button" class="btn ghost xs" id="hfAdd">' + wrapIco('plus') + 'Add filament</button>',
      '</div>',
    ].join('');
  }

  function filRow(f, i, total) {
    const near = (f.name && f.deltaE != null)
      ? '<span class="hf-fil-near" title="closest filament you own">≈ ' + esc(f.name) + ' ΔE ' + f.deltaE.toFixed(1) + '</span>'
      : '';
    return [
      '<div class="hf-fil" data-idx="' + i + '">',
      '<div class="hf-fil-ord">',
      '<button type="button" class="hf-ord-btn" data-act="up" ' + (i === total - 1 ? 'disabled' : '') + ' aria-label="move up" title="move up">⌃</button>',
      '<span class="hf-fil-slot">' + (i + 1) + '</span>',
      '<button type="button" class="hf-ord-btn" data-act="down" ' + (i === 0 ? 'disabled' : '') + ' aria-label="move down" title="move down">⌄</button>',
      '</div>',
      '<label class="hf-sw" style="background:' + css(f.hex) + '"><input type="color" data-fld="hex" value="' + esc(normHex(f.hex)) + '" aria-label="colour" /></label>',
      '<div class="hf-fil-body">',
      '<div class="hf-fil-hex">' + esc(String(f.hex).toUpperCase()) + '</div>',
      f.measured ? '<span class="hf-fil-near" title="colour and TD measured from a calibration card">measured</span>' : near,
      '</div>',
      '<label class="hf-num" title="Transmission distance (mm) — lower = opaque, higher = translucent">TD<input type="number" data-fld="td" min="0.3" max="20" step="0.1" value="' + esc(f.td) + '" /></label>',
      '<label class="hf-num" title="Band thickness in layers">ly<input type="number" data-fld="layers" min="1" max="80" step="1" value="' + esc(f.layers) + '" /></label>',
      '<button type="button" class="hf-fil-x" data-act="del" aria-label="remove">' + ico('cross', 14) + '</button>',
      '</div>',
    ].join('');
  }

  /**
   * Measure the stack's real colours and TDs from a printed card (lib/hueforge-calibrate.js).
   * The card is printed from the stack AS IT IS NOW and remembered (S.calCard), because a
   * photo can only be read against the layout it was printed from — reorder the stack after
   * printing and the rows would be read as the wrong filaments.
   */
  function calibrateHtml() {
    const n = S.filaments.length;
    const can = n >= 2 && n <= 4 && !!CAL();
    const measured = S.filaments.filter((f) => f.measured).length;
    return [
      '<div class="hf-card">',
      '<div class="hf-card-h">CALIBRATE FILAMENTS</div>',
      '<div class="hf-note" style="margin-top:0">Print a small card with the filaments in your stack, photograph it flat in even daylight, and Bed Ready measures each filament’s real colour and TD from it. Measured values replace the guesses the painting uses.</div>',
      '<div class="hf-auto" style="margin-top:10px">',
      '<button type="button" class="btn sm" id="hfCalCard"' + (can ? '' : ' disabled title="Needs 2 to 4 filaments in the stack"') + '>' + wrapIco('cube') + 'Print calibration card</button>',
      '<button type="button" class="btn ghost sm" id="hfCalRead"' + (S.calCard ? '' : ' disabled title="Print the card first"') + '>' + wrapIco('camera') + 'Read photo of card</button>',
      '</div>',
      measured ? '<div class="hf-note">' + measured + ' of ' + n + ' filament' + (n === 1 ? '' : 's') + ' measured from a card.</div>' : '',
      '<input type="file" id="hfCalFile" accept="image/*" hidden />',
      '</div>',
    ].join('');
  }

  function exportCalCard() {
    const cal = CAL();
    const api = (typeof window !== 'undefined' && window.hubAPI);
    if (!cal || !api || !api.hfExportCard3mf) { toast(t('common.feature_missing')); return; }
    const hexes = S.filaments.map((f) => String(f.hex).toUpperCase());
    const plan = cal.planCard(hexes, { layerH: S.layerH });
    if (!plan) { toast(t('hf.cal_two_filaments')); return; }
    api.hfExportCard3mf({ filaments: hexes, layerH: S.layerH, name: 'calibration-card' }).then((r) => {
      if (r && r.ok) {
        S.calCard = { filaments: hexes, layerH: S.layerH };
        render();
        toast(t('hf.cal_card_saved', { last: hexes.length - 1 }));
      } else if (!(r && r.canceled)) toast(t('common.export_failed') + (r && r.error ? ': ' + r.error : ''));
    }).catch(() => toast(t('common.export_failed')));
  }

  function loadCalPhoto(file) {
    if (!file || !/^image\//.test(file.type) || !S.calCard) return;
    const reader = new FileReader();
    reader.onload = () => {
      const img = new Image();
      img.onload = () => {
        const scale = Math.min(1, CAL_PHOTO_MAX / Math.max(img.width, img.height));
        const cv = document.createElement('canvas');
        cv.width = Math.max(1, Math.round(img.width * scale));
        cv.height = Math.max(1, Math.round(img.height * scale));
        cv.getContext('2d').drawImage(img, 0, 0, cv.width, cv.height);
        openCornerPicker(cv);
      };
      img.src = reader.result;
    };
    reader.readAsDataURL(file);
  }

  /** Overlay: the maker clicks the card's four corners, light square first, clockwise. */
  function openCornerPicker(cv) {
    const cal = CAL();
    const plan = cal.planCard(S.calCard.filaments, { layerH: S.calCard.layerH });
    const ov = document.createElement('div');
    ov.className = 'hf-cal-ov';
    ov.setAttribute('role', 'dialog');
    ov.setAttribute('aria-modal', 'true');
    ov.setAttribute('aria-label', 'Read the calibration card');
    ov.innerHTML = '<div class="hf-cal-box"><div class="hf-cal-h" id="hfCalHint"></div>'
      + '<div class="hf-cal-stage"></div><div class="hf-cal-res" id="hfCalRes"></div>'
      + '<div class="hf-auto hf-cal-act"><button type="button" class="btn ghost sm" data-cal="undo">Undo corner</button>'
      + '<button type="button" class="btn ghost sm" data-cal="close">Cancel</button>'
      + '<button type="button" class="btn primary sm" data-cal="apply" disabled>Use measured values</button></div></div>';
    document.body.appendChild(ov);
    const stage = ov.querySelector('.hf-cal-stage');
    const view = document.createElement('canvas');
    view.width = cv.width; view.height = cv.height;
    stage.appendChild(view);
    const ctx = view.getContext('2d');
    const imgData = cv.getContext('2d').getImageData(0, 0, cv.width, cv.height);
    const NAMES = ['the light-square corner (top-left)', 'the top-right corner', 'the bottom-right corner', 'the bottom-left corner'];
    const pts = [];
    let result = null;

    const draw = () => {
      ctx.drawImage(cv, 0, 0);
      const r = Math.max(4, cv.width / 200);
      ctx.lineWidth = Math.max(2, cv.width / 500);
      ctx.strokeStyle = '#00E0FF'; ctx.fillStyle = '#00E0FF';
      ctx.beginPath();
      pts.forEach((p, i) => { if (i) ctx.lineTo(p[0], p[1]); else ctx.moveTo(p[0], p[1]); });
      if (pts.length === 4) ctx.closePath();
      ctx.stroke();
      pts.forEach((p) => { ctx.beginPath(); ctx.arc(p[0], p[1], r, 0, Math.PI * 2); ctx.fill(); });
      ov.querySelector('#hfCalHint').textContent = pts.length < 4
        ? 'Click ' + NAMES[pts.length] + ' of the card.'
        : (result ? 'Measured. Check the values, then use them.' : 'Those corners could not be read. Undo and try again.');
    };
    const measure = () => {
      const out = cal.measureCard(imgData, pts, plan);
      result = out;
      const box = ov.querySelector('#hfCalRes');
      const apply = ov.querySelector('[data-cal="apply"]');
      if (!out) { box.innerHTML = ''; apply.disabled = true; draw(); return; }
      const WARN = {
        'too-opaque': 'so opaque the thinnest step hides the backing; TD is an upper bound',
        'too-translucent': 'so translucent the thickest step still shows the backing; TD is a lower bound',
        'low-contrast-backings': 'its backings are too alike to read well; add a much lighter or darker filament',
        'one-backing': 'read over one backing only; add a third filament for a better reading',
        'few-steps': 'only one step was usable',
        'poor-fit': 'the card does not fit the model well; check the corners and the lighting',
      };
      box.innerHTML = '<table class="hf-cal-t"><thead><tr><th>Head</th><th>Stated</th><th>Measured</th><th>TD</th><th>Fit ΔE</th></tr></thead><tbody>'
        + out.results.map((r) => r.error
          ? '<tr><td>T' + r.head + '</td><td><span class="hf-cal-sw" style="background:' + css(r.statedHex) + '"></span>' + esc(r.statedHex) + '</td><td colspan="3">Could not read this row</td></tr>'
          : '<tr><td>T' + r.head + '</td>'
            + '<td><span class="hf-cal-sw" style="background:' + css(r.statedHex) + '"></span>' + esc(r.statedHex) + '</td>'
            + '<td><span class="hf-cal-sw" style="background:' + css(r.hex) + '"></span>' + esc(r.hex) + '</td>'
            + '<td>' + esc(r.td) + '</td><td>' + esc(r.residual) + '</td></tr>'
            + (r.warnings.length ? '<tr class="hf-cal-w"><td></td><td colspan="4">' + r.warnings.map((w) => esc(WARN[w] || w)).join('; ') + '</td></tr>' : ''))
          .join('') + '</tbody></table>';
      apply.disabled = !out.results.some((r) => !r.error);
      draw();
    };
    view.addEventListener('click', (e) => {
      if (pts.length >= 4) return;
      const b = view.getBoundingClientRect();
      pts.push([(e.clientX - b.left) * view.width / b.width, (e.clientY - b.top) * view.height / b.height]);
      if (pts.length === 4) measure(); else draw();
    });
    const close = () => { ov.remove(); document.removeEventListener('keydown', onKey); };
    const onKey = (e) => { if (e.key === 'Escape') close(); };
    document.addEventListener('keydown', onKey);
    ov.addEventListener('click', (e) => {
      const act = e.target.closest('[data-cal]'); if (!act) return;
      const a = act.dataset.cal;
      if (a === 'close') close();
      else if (a === 'undo') { pts.pop(); result = null; ov.querySelector('#hfCalRes').innerHTML = ''; ov.querySelector('[data-cal="apply"]').disabled = true; draw(); }
      else if (a === 'apply' && result) { applyCal(result.results); close(); }
    });
    draw();
  }

  /**
   * Write the measurements onto the stack. A row is matched to the filament it was PRINTED
   * as (its stated hex), not to whatever now sits at that index — the stack may have been
   * reordered since the card was printed.
   */
  function applyCal(results) {
    let n = 0;
    for (const r of results) {
      if (r.error) continue;
      const f = S.filaments.find((x) => !x._calDone && String(x.hex).toUpperCase() === r.statedHex);
      if (!f) continue;
      f.hex = r.hex; f.td = r.td; f.measured = true; f.name = null; f.deltaE = null; f._calDone = true;
      n++;
    }
    for (const f of S.filaments) delete f._calDone;
    S.calCard = null;   // the card describes the old hexes now; print again to re-measure
    render();
    toast(n ? t('hf.cal_measured', { n }) : t('hf.cal_no_match'));
  }

  function settingsHtml() {
    const opts = LAYER_PRESETS.slice();
    if (!opts.some((p) => Math.abs(p[0] - S.layerH) < 1e-6)) opts.push([S.layerH, 'custom']);
    const lopt = opts.map((p) => '<option value="' + p[0] + '"' + (Math.abs(p[0] - S.layerH) < 1e-6 ? ' selected' : '') + '>'
      + p[0].toFixed(2) + ' mm' + (p[1] ? ' · ' + p[1] : '') + '</option>').join('');
    const flat = isFlat();
    const modeSel = '<label class="hf-num wide" title="Relief paints by HEIGHT through translucent filament. Flat paints by REGION — solid colour areas, each on its own head. Flat needs no TD calibration and prints faster; relief blends colours the palette does not contain.">mode'
      + '<select class="input" id="hfMode">'
      + '<option value="relief"' + (flat ? '' : ' selected') + '>Relief · light through filament</option>'
      + '<option value="flat"' + (flat ? ' selected' : '') + '>Flat · solid colour regions</option>'
      + '</select></label>';
    return [
      '<div class="hf-card">',
      '<div class="hf-card-h">PRINT SETTINGS</div>',
      '<div class="hf-set">',
      modeSel,
      '<label class="hf-num wide" title="Printed width on the bed (mm)">width (mm)<input type="number" id="hfWidth" min="40" max="270" step="1" value="' + esc(S.widthMm) + '" /></label>',
      '<label class="hf-num wide" title="Layer height">layer height<select class="input" id="hfLayerH">' + lopt + '</select></label>',
      flat ? '' : '<label class="hf-num wide" title="Solid base layers before the first colour">base layers<input type="number" id="hfBase" min="1" max="20" step="1" value="' + esc(S.baseLayers) + '" /></label>',
      '<label class="hf-num wide" title="Total relief height. More height = more colour layers = richer tones (and longer print).">height (mm)<input type="number" id="hfHeight" min="0.8" max="6" step="0.1" value="' + esc(S.heightMm) + '" /></label>',
      flat ? '' : '<label class="hf-num wide" title="Colour vividness (front-lit correction). Higher = more saturated, punchier colour; lower = softer, more blended. 9 is a good default for reflective prints.">vividness<input type="number" id="hfVivid" min="1" max="10" step="1" value="' + esc(S.vivid) + '" /></label>',
      flat ? '' : '<label class="hf-num wide" title="The relief is already smoothed to keep flat areas clean. 0 = default; raise it (1–3) only if a busy photo still looks noisy — higher trades fine detail for a smoother surface.">smoothing<input type="number" id="hfSmooth" min="0" max="3" step="1" value="' + esc(S.smooth) + '" /></label>',
      '</div></div>',
    ].join('');
  }

  function previewHtml() {
    return [
      '<div class="hf-card">',
      '<div class="hf-card-h">HOW IT WILL PRINT <span class="hf-card-hx" id="hfMatch">achievable colour</span></div>',
      '<div class="hf-preview"><canvas id="hfCanvas" class="hf-canvas"></canvas>',
      '<div class="hf-preview-empty" id="hfPreviewEmpty" hidden>Add filaments to preview.</div></div>',
      '</div>',
    ].join('');
  }

  function elevationHtml() {
    return '<div class="hf-card"><div class="hf-card-h">SWAP ELEVATION</div><div class="hf-elev" id="hfElev"></div></div>';
  }

  function verdictHtml() {
    return '<div class="hf-card hf-verdict-card"><div id="hfVerdict"></div></div>';
  }

  /**
   * Flat mode is automatic by construction: <=4 colours, each on its own always-loaded head,
   * every change of colour a free tool change. There is nothing to reload and no swap height
   * to report — which is the entire argument for the mode.
   */
  function paintFlatVerdict(host) {
    if (!S.flat) { host.innerHTML = ''; return; }
    const f = S.flat, prof = u1Profile();
    const bedX = prof && prof.bed ? prof.bed.x : 270;
    const bedY = prof && prof.bed ? prof.bed.y : 270;
    const over = f.sizeMm.x > bedX || f.sizeMm.y > bedY;
    const n = f.palette.length;
    host.innerHTML = [
      '<div class="hf-vd-top"><span class="hf-vd-badge ok">' + wrapIco('check') + 'FULLY AUTOMATIC</span>',
      '<span class="hf-vd-count">' + n + ' colours · ' + (HF() ? HF().U1_HEADS : 4) + ' heads</span></div>',
      '<div class="hf-vd-line">A flat plate: each colour is its own region on its own head, so every colour change '
        + 'is a free tool change. No relief, no light mixing, nothing to calibrate — what the preview shows is what prints.</div>',
      '<div class="hf-vd-facts"><span>' + Math.round(f.sizeMm.x) + '×' + Math.round(f.sizeMm.y) + '×' + f.sizeMm.z.toFixed(2) + ' mm</span>',
      '<span>' + f.parts.length + ' parts</span>',
      (over ? '<span class="hf-over">exceeds the ' + bedX + '×' + bedY + ' mm bed — reduce width</span>' : ''),
      '</div>',
    ].join('');
  }

  function exportHtml() {
    if (isFlat()) {
      const can = !!(S.flat && S.flat.parts.length);
      return [
        '<div class="hf-card">',
        '<div class="hf-card-h">EXPORT</div>',
        '<div class="hf-export">',
        '<button type="button" class="btn primary sm" id="hf3mf"' + (can ? '' : ' disabled title="Add an image and filaments first"') + '>' + wrapIco('cube') + 'Export U1 3MF</button>',
        '<button type="button" class="btn ghost sm" id="hfStl">' + wrapIco('doc') + 'Plate STL</button>',
        '</div>',
        '<div class="hf-note">The flat 3MF opens in Snapmaker Orca ready to slice — every colour region is its own part, '
          + 'pre-assigned to a head. A plain STL loses the colour split, so it is only useful as a shape.</div>',
        '</div>',
      ].join('');
    }
    const auto = S.plan && S.plan.automatic;
    const can3mf = auto && S.solve;
    return [
      '<div class="hf-card">',
      '<div class="hf-card-h">EXPORT</div>',
      '<div class="hf-export">',
      '<button type="button" class="btn primary sm" id="hf3mf"' + (can3mf ? '' : ' disabled title="Needs ≤4 colours (fits the U1 heads)"') + '>' + wrapIco('cube') + 'Export U1 3MF</button>',
      '<button type="button" class="btn ghost sm" id="hfStl">' + wrapIco('doc') + 'Relief STL</button>',
      '<button type="button" class="btn ghost sm" id="hfCopy">' + wrapIco('clipboard') + 'Copy plan</button>',
      '</div>',
      '<div class="hf-note">' + (can3mf
        ? 'The U1 3MF opens in Snapmaker Orca ready to slice — the four filaments are pre-mapped to the heads and the colour swaps are baked in by height. Just load the shown colours and print.'
        : 'Reduce to ≤4 colours for the one-click U1 3MF. The relief STL always works — slice it and load the plan’s filaments yourself.') + '</div>',
      '</div>',
    ].join('');
  }

  function wrapIco(name) { const s = ico(name, 15); return s ? '<span class="br-ico">' + s + '</span>' : ''; }

  // ---- paint dynamic bits -------------------------------------------------

  function paint() {
    paintCanvas();
    paintElevation();
    paintVerdict();
  }

  function paintCanvas() {
    const cv = document.getElementById('hfCanvas');
    const empty = document.getElementById('hfPreviewEmpty');
    const match = document.getElementById('hfMatch');
    if (!cv) return;
    // Flat mode's preview IS the print: solid regions, no transmission, so what the
    // quantiser produced is exactly what comes off the bed.
    const src = isFlat() ? S.flat : S.solve;
    if (!src || !S.img) { cv.hidden = true; if (empty) empty.hidden = false; if (match) match.textContent = ''; return; }
    cv.hidden = false; if (empty) empty.hidden = true;
    cv.width = src.width; cv.height = src.height;
    const ctx = cv.getContext('2d');
    const id = ctx.createImageData(src.width, src.height);
    id.data.set(src.preview);
    ctx.putImageData(id, 0, 0);
    if (isFlat()) {
      if (match) {
        const n = S.flat.palette.length;
        match.textContent = n + ' solid colour' + (n === 1 ? '' : 's') + ' — exactly as shown';
        match.className = 'hf-card-hx hf-match exact';
      }
      return;
    }
    if (match) {
      const de = S.solve.meanDeltaE || 0;
      const q = de < 2 ? 'exact' : de < 4 ? 'close' : de < 8 ? 'ok' : 'far';
      match.textContent = 'match ΔE ' + de.toFixed(1) + ' avg';
      match.className = 'hf-card-hx hf-match ' + q;
    }
  }

  function paintElevation() {
    const host = document.getElementById('hfElev');
    if (!host) return;
    if (isFlat()) { paintFlatParts(host); return; }
    if (!S.stack || !S.stack.bands.length) { host.innerHTML = '<div class="hf-empty">—</div>'; return; }
    const bands = S.stack.bands, total = S.stack.totalLayers, plan = S.plan;
    // column-reverse: bottom band drawn at the bottom
    host.innerHTML = bands.map((b, i) => {
      const pct = Math.max(6, (b.layers / total) * 100);
      const slot = plan ? (plan.slots[i] ? plan.slots[i].slot + 1 : i + 1) : i + 1;
      const reload = plan && plan.reloads.some((r) => r.band === b);
      const dark = KC() && KC().hexToRgb(b.hex) ? HF().luminance(b.hex) < 0.55 : false;
      return '<div class="hf-band" style="flex:' + pct.toFixed(2) + ' 1 0;background:' + css(b.hex) + ';color:' + (dark ? '#fff' : '#111') + '">'
        + '<span class="hf-band-slot" title="U1 head">T' + (slot - 1) + (reload ? ' ↻' : '') + '</span>'
        + '<span class="hf-band-l">L' + b.startLayer + '–' + b.endLayer + '</span>'
        + '<span class="hf-band-td">TD ' + b.td + '</span>'
        + '</div>';
    }).join('');
  }

  /** Flat mode has parts, not bands — one row per colour region and the head that prints it. */
  function paintFlatParts(host) {
    if (!S.flat || !S.flat.parts.length) { host.innerHTML = '<div class="hf-empty">—</div>'; return; }
    const hf = HF();
    host.innerHTML = S.flat.parts.map((p, i) => {
      const dark = hf ? hf.luminance(p.hex) < 0.55 : false;
      return '<div class="hf-band" style="flex:1 1 0;background:' + css(p.hex) + ';color:' + (dark ? '#fff' : '#111') + '">'
        + '<span class="hf-band-slot" title="U1 head">T' + (p.head | 0) + '</span>'
        + '<span class="hf-band-l">' + (i === 0 ? 'base slab' : 'colour region') + '</span>'
        + '<span class="hf-band-td">' + esc(String(p.hex).toUpperCase()) + '</span>'
        + '</div>';
    }).join('');
  }

  function paintVerdict() {
    const host = document.getElementById('hfVerdict');
    if (!host) return;
    if (isFlat()) { paintFlatVerdict(host); return; }
    if (!S.plan) { host.innerHTML = ''; return; }
    const p = S.plan, prof = u1Profile();
    const heightMm = S.stack ? (S.stack.totalLayers * S.stack.layerH).toFixed(2) : '0';
    const depthMm = S.img ? (S.widthMm * S.img.height / S.img.width) : 0;
    const size = S.img ? (Math.round(S.widthMm) + '×' + Math.round(depthMm) + '×' + heightMm + ' mm') : '';
    const bedX = prof && prof.bed ? prof.bed.x : 270;
    const overBed = S.img && (S.widthMm > bedX || depthMm > (prof && prof.bed ? prof.bed.y : 270));
    const ok = p.automatic;
    const badge = ok
      ? '<span class="hf-vd-badge ok">' + wrapIco('check') + 'FULLY AUTOMATIC</span>'
      : '<span class="hf-vd-badge warn">' + wrapIco('alert') + p.reloads.length + ' RELOAD' + (p.reloads.length === 1 ? '' : 'S') + ' NEEDED</span>';
    const line2 = ok
      ? p.colorCount + ' filaments on the four SnapSwap heads, re-used across ' + ((p.swaps || 0) + 1) + ' colour bands — every swap is an automatic, near-zero-purge tool-change. Nothing to set up in the slicer.'
      : p.colorCount + ' colours over ' + p.heads + ' heads: after a head finishes, swap its spool for the next colour when the U1 pauses at the marked layer (↻ in the elevation).';
    const reloadList = (!ok && p.reloads.length)
      ? '<ul class="hf-vd-reloads">' + p.reloads.map((r) =>
        '<li><span class="hf-sw sm" style="background:' + css(r.band.hex) + '"></span>swap head T' + r.slot + ' at layer ' + r.atLayer + '</li>').join('') + '</ul>'
      : '';
    host.innerHTML = [
      '<div class="hf-vd-top">' + badge + '<span class="hf-vd-count">' + p.colorCount + ' colours · ' + p.heads + ' heads</span></div>',
      '<div class="hf-vd-line">' + line2 + '</div>',
      reloadList,
      '<div class="hf-vd-facts"><span>' + size + '</span><span>' + (S.stack ? S.stack.totalLayers : 0) + ' layers</span>'
        + (overBed ? '<span class="hf-over">exceeds ' + bedX + ' mm bed — reduce width</span>' : '') + '</div>',
    ].join('');
  }

  // ---- wiring -------------------------------------------------------------

  function wire(host) {
    const file = host.querySelector('#hfFile');
    const drop = host.querySelector('#hfDrop');
    if (drop) {
      drop.addEventListener('click', () => file && file.click());
      drop.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); file && file.click(); } });
      drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('over'); });
      drop.addEventListener('dragleave', () => drop.classList.remove('over'));
      drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('over'); if (e.dataTransfer.files[0]) loadImageFile(e.dataTransfer.files[0]); });
    }
    if (file) file.addEventListener('change', (e) => { if (e.target.files[0]) loadImageFile(e.target.files[0]); e.target.value = ''; });

    const on = (sel, ev, fn) => { const el = host.querySelector(sel); if (el) el.addEventListener(ev, fn); };
    on('#hfReset', 'click', () => { S = defaults(); render(); });
    on('#hfChange', 'click', () => file && file.click());
    on('#hfAuto', 'click', () => { autoPalette(); render(); });
    on('#hfTune', 'click', runTune);
    on('#hfAdd', 'click', () => { addFilament(); render(); });
    on('#hfMaxColors', 'change', (e) => { S.maxColors = +e.target.value || 4; });
    // Switching mode changes which plan exists at all, so re-render rather than repaint:
    // the settings, the parts pane and the export card are all different shapes.
    on('#hfMode', 'change', (e) => { S.mode = e.target.value === 'flat' ? 'flat' : 'relief'; render(); });
    on('#hfLayerH', 'change', (e) => { S.layerH = clampNum(e.target.value, 0.04, 0.28, 0.12); scheduleRepaint(); });
    on('#hfWidth', 'input', (e) => { S.widthMm = clampNum(e.target.value, 40, 270, 120); scheduleRepaint(); });
    on('#hfBase', 'input', (e) => { S.baseLayers = Math.round(clampNum(e.target.value, 1, 20, 5)); scheduleRepaint(); });
    on('#hfHeight', 'input', (e) => { S.heightMm = clampNum(e.target.value, 0.8, 6, 2.4); scheduleRepaint(); });
    on('#hfVivid', 'input', (e) => { S.vivid = Math.round(clampNum(e.target.value, 1, 10, 9)); scheduleRepaint(); });
    on('#hfSmooth', 'input', (e) => { S.smooth = Math.round(clampNum(e.target.value, 0, 3, 0)); scheduleRepaint(); });
    on('#hfCopy', 'click', copyPlan);
    on('#hfStl', 'click', exportStl);
    on('#hf3mf', 'click', export3mf);
    on('#hfCalCard', 'click', exportCalCard);
    const calFile = host.querySelector('#hfCalFile');
    on('#hfCalRead', 'click', () => calFile && calFile.click());
    if (calFile) calFile.addEventListener('change', (e) => { if (e.target.files[0]) loadCalPhoto(e.target.files[0]); e.target.value = ''; });

    const stack = host.querySelector('#hfStack');
    if (stack) {
      stack.addEventListener('input', onStackInput);
      stack.addEventListener('click', onStackClick);
    }
  }

  function onStackInput(e) {
    const row = e.target.closest('.hf-fil'); if (!row) return;
    const i = +row.dataset.idx, fld = e.target.dataset.fld, f = S.filaments[i];
    if (!f || !fld) return;
    if (fld === 'hex') {
      f.hex = e.target.value; f.name = null; f.deltaE = null; f.measured = false;
      const sw = row.querySelector('.hf-sw'); if (sw) sw.style.background = css(f.hex);
      const hx = row.querySelector('.hf-fil-hex'); if (hx) hx.textContent = String(f.hex).toUpperCase();
      const near = row.querySelector('.hf-fil-near'); if (near) near.remove();
    } else if (fld === 'td') {
      f.td = clampNum(e.target.value, 0.3, 20, 2); f.measured = false;
    } else if (fld === 'layers') {
      f.layers = Math.round(clampNum(e.target.value, 1, 80, 12));
    }
    scheduleRepaint();
  }

  function onStackClick(e) {
    const btn = e.target.closest('[data-act]'); if (!btn) return;
    const row = e.target.closest('.hf-fil'); if (!row) return;
    const i = +row.dataset.idx, act = btn.dataset.act;
    if (act === 'del') S.filaments.splice(i, 1);
    else if (act === 'up' && i < S.filaments.length - 1) swap(i, i + 1);   // "up" in the stack = higher index (drawn above)
    else if (act === 'down' && i > 0) swap(i, i - 1);
    render();
  }

  function swap(a, b) { const t = S.filaments[a]; S.filaments[a] = S.filaments[b]; S.filaments[b] = t; }

  function runTune() {
    const hf = HF();
    if (!hf || !S.img || !S.filaments.length) return;
    const btn = document.getElementById('hfTune');
    if (btn) { btn.disabled = true; btn.textContent = 'Tuning…'; }
    // let the disabled state paint before the (synchronous) optimise runs
    requestAnimationFrame(() => {
      const res = hf.autoTune(S.img, S.filaments, { layerH: S.layerH, baseLayers: S.baseLayers });
      S.filaments = S.filaments.map((f, i) => Object.assign({}, f, { layers: res.filaments[i] ? res.filaments[i].layers : f.layers }));
      S.baseLayers = res.baseLayers;
      render();
      // report the value actually shown (full-res solve), not the coarse tuning score
      const de = S.solve ? S.solve.meanDeltaE : res.meanDeltaE;
      toast('Tuned — match ΔE ' + de.toFixed(1));
    });
  }

  function addFilament() {
    const hf = HF();
    const hex = '#8899AA';
    S.filaments.push({ hex, td: hf ? hf.defaultTd(hex) : 3, layers: 12, name: null, deltaE: null });
  }

  function copyPlan() {
    if (!S.stack || !S.plan) return;
    const lh = S.stack.layerH, mm = (k) => (k * lh).toFixed(2);
    const depthMm = S.img ? Math.round(S.widthMm * S.img.height / S.img.width) : 0;
    const lines = [];
    lines.push('HueForge → Snapmaker U1  ·  ' + (S.imgName || 'painting'));
    lines.push('Size ' + Math.round(S.widthMm) + '×' + depthMm + '×' + mm(S.stack.totalLayers) + ' mm · '
      + 'layer ' + lh + ' mm · ' + S.stack.totalLayers + ' layers · 100% infill');
    lines.push('');
    S.stack.bands.forEach((b, i) => {
      const slot = S.plan.slots[i] ? S.plan.slots[i].slot : i % S.plan.heads;
      const reload = S.plan.reloads.some((r) => r.band === b);
      lines.push('Head T' + slot + '  ' + String(b.hex).toUpperCase() + '  TD ' + b.td
        + '  ·  layers ' + b.startLayer + '–' + b.endLayer + ' (' + mm(b.startLayer - 1) + '–' + mm(b.endLayer) + ' mm)'
        + (reload ? '  ← RELOAD this head at ' + mm(b.startLayer - 1) + ' mm' : ''));
    });
    lines.push('');
    // "these 4 colours" was hard-coded next to a head range counted from the real
    // stack, so a three-colour plan read "load these 4 colours into heads T0–T2".
    const n = S.plan.colorCount;
    lines.push(S.plan.automatic
      ? 'Fully automatic on the U1 — load these ' + n + ' colour' + (n === 1 ? '' : 's')
        + ' into head' + (n === 1 ? ' T0' : 's T0–T' + (n - 1)) + '; swaps happen mid-print, no manual steps.'
      : (S.plan.reloads.length + ' mid-print reload(s) needed — swap the marked head when the U1 pauses at the listed height.'));
    const text = lines.join('\n');
    copyText(text).then((ok) => toast(ok ? 'Print plan copied' : 'Copy failed'));
  }

  function export3mf() {
    if (isFlat()) { exportFlat3mf(); return; }
    if (!S.paint || !S.solve) { toast(t('hf.need_image_filaments')); return; }
    const api = (typeof window !== 'undefined' && window.hubAPI);
    if (!api || !api.hfExport3mf) { toast(t('common.feature_missing')); return; }
    const p = S.paint;
    const btn = document.getElementById('hf3mf');
    if (btn) { btn.disabled = true; btn.textContent = 'Building…'; }
    api.hfExport3mf({
      heights: Array.from(p.solve.heights),
      width: p.solve.width, height: p.solve.height,
      layerH: p.layerH, widthMm: S.widthMm,
      bands: p.bands,                              // many bands, filaments reused across heads
      filaments: p.filaments.map((f) => f.hex),    // 4 slot colours, indexed by head
      name: (S.imgName || 'hueforge').replace(/\.[^.]+$/, ''),
      // Embed the achievable-colour preview as the plate thumbnail so the model shows a
      // picture in Snapmaker Orca and the OS file preview (not a blank tile).
      thumbPng: solvePreviewPng(512),
      thumbSmallPng: solvePreviewPng(128),
    }).then((r) => {
      render();
      if (r && r.ok) toast('U1 3MF saved · open in Snapmaker Orca');
      else if (r && r.canceled) { /* silent */ }
      else toast(t('common.export_failed') + (r && r.error ? ': ' + r.error : ''));
    }).catch((e) => { render(); toast(t('common.export_failed')); });
  }

  /**
   * Send the label field, not the geometry. The parts are rebuilt in the main process from
   * labels + palette, which is a fraction of the bytes a triangle soup would be — the same
   * trade the relief export makes by sending a heightfield.
   */
  function exportFlat3mf() {
    const f = S.flat;
    if (!f || !f.parts.length) { toast(t('hf.need_image_filaments')); return; }
    const api = (typeof window !== 'undefined' && window.hubAPI);
    if (!api || !api.hfExportFlat3mf) { toast(t('common.feature_missing')); return; }
    const btn = document.getElementById('hf3mf');
    if (btn) { btn.disabled = true; btn.textContent = 'Building…'; }
    api.hfExportFlat3mf({
      labels: Array.from(f.labels),
      palette: f.palette.map((p) => ({ hex: p.hex, r: p.r, g: p.g, b: p.b })),
      width: f.width, height: f.height,
      widthMm: S.widthMm, heightMm: S.heightMm,
      layerH: S.layerH,
      filaments: f.filaments,
      baseHead: f.baseHead,
      name: (S.imgName || 'hueforge-flat').replace(/\.[^.]+$/, ''),
      thumbPng: solvePreviewPng(512),
      thumbSmallPng: solvePreviewPng(128),
    }).then((r) => {
      render();
      if (r && r.ok) toast('Flat U1 3MF saved · open in Snapmaker Orca');
      else if (r && r.canceled) { /* silent */ }
      else toast(t('common.export_failed') + (r && r.error ? ': ' + r.error : ''));
    }).catch(() => { render(); toast(t('common.export_failed')); });
  }

  function exportStl() {
    const hf = HF();
    if (!hf) { toast(t('common.export_empty')); return; }
    // Flat mode has no heightfield to turn into a surface — it already IS meshes. Merging
    // the parts loses the colour split, which is why the export card calls it a plate: it
    // carries the shape and nothing about which head prints what.
    let mesh;
    if (isFlat()) {
      if (!S.flat || !S.flat.parts.length) { toast(t('common.export_empty')); return; }
      const tris = [];
      for (const part of S.flat.parts) for (const t of part.triangles) tris.push(t);
      mesh = { triangles: tris, triangleCount: tris.length, sizeMm: S.flat.sizeMm };
    } else {
      if (!S.solve || !S.stack) { toast(t('common.export_empty')); return; }
      mesh = hf.heightfieldToMesh(S.solve, { layerH: S.stack.layerH, widthMm: S.widthMm });
    }
    if (!mesh.triangleCount) { toast(t('hf.empty_model')); return; }
    const bytes = hf.meshToStlBinary(mesh.triangles);
    const blob = new Blob([bytes], { type: 'model/stl' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = (S.imgName || 'painting').replace(/\.[^.]+$/, '') + '-U1.stl';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
    toast('STL exported · ' + Math.round(mesh.sizeMm.x) + '×' + Math.round(mesh.sizeMm.y) + '×' + mesh.sizeMm.z.toFixed(1) + ' mm');
  }

  // ---- utils --------------------------------------------------------------

  /** The solved achievable-colour preview as base64 PNG (no data: prefix), scaled to fit
   *  `maxSide`. Used as the exported 3MF's plate thumbnail. Returns null if nothing solved. */
  function solvePreviewPng(maxSide) {
    const pv = isFlat() ? S.flat : S.solve;   // whichever preview this mode produced
    if (!pv || !pv.preview) return null;
    const w = pv.width, h = pv.height;
    if (!w || !h) return null;
    try {
      const src = document.createElement('canvas');
      src.width = w; src.height = h;
      const sctx = src.getContext('2d');
      const id = sctx.createImageData(w, h);
      id.data.set(pv.preview);
      sctx.putImageData(id, 0, 0);
      const scale = Math.min(1, (maxSide || 512) / Math.max(w, h));
      const dw = Math.max(1, Math.round(w * scale)), dh = Math.max(1, Math.round(h * scale));
      let out = src;
      if (scale < 1) {
        out = document.createElement('canvas');
        out.width = dw; out.height = dh;
        const octx = out.getContext('2d');
        octx.imageSmoothingEnabled = true; octx.imageSmoothingQuality = 'high';
        octx.drawImage(src, 0, 0, dw, dh);
      }
      const url = out.toDataURL('image/png');
      const comma = url.indexOf(',');
      return comma >= 0 ? url.slice(comma + 1) : null;
    } catch (_) { return null; }
  }

  function normHex(hex) {
    const kc = KC(); const rgb = kc && kc.hexToRgb(hex);
    return rgb ? kc.rgbToHex(rgb.r, rgb.g, rgb.b) : '#888888';
  }
  function clampNum(v, lo, hi, dflt) { let n = parseFloat(v); if (!isFinite(n)) n = dflt; return n < lo ? lo : n > hi ? hi : n; }
  function toast(msg) { if (typeof showToast === 'function') showToast(msg); else if (typeof global.toast === 'function') global.toast(msg); }

  function renderHueForge() { render(); }
  Object.assign(global, { renderHueForge });
})(typeof window !== 'undefined' ? window : this);
