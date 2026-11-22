'use strict';
/*
 * Interactive 3D model viewer — orbit a print file's mesh right in the app, no WebGL /
 * three.js. It reuses the existing software rasterizer (lib/stl-thumbnail.js, extended with
 * yaw/pitch) and the mesh the main process already knows how to parse for STL and 3MF (a
 * flat Float32Array). Drag to rotate, toggle auto-spin.
 *
 * Loaded by BOTH index.html (Khayt) and bedready.html — the "3D" print-file action + the
 * converter preview are shared-core, active in every flavour. `mountMeshViewer` wires a bare
 * <canvas> so it can live in its own modal (openModelViewer) or inline in another panel
 * (the converter's "what am I converting?").
 */
(function (global) {
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

  // Rebuild the [[x,y,z]×3] triangle soup the rasterizer wants from the flat buffer.
  function trisFromVerts(verts, count) {
    const tris = new Array(count);
    for (let i = 0, k = 0; i < count; i++) {
      tris[i] = [
        [verts[k], verts[k + 1], verts[k + 2]],
        [verts[k + 3], verts[k + 4], verts[k + 5]],
        [verts[k + 6], verts[k + 7], verts[k + 8]],
      ];
      k += 9;
    }
    return tris;
  }

  function fmtMm(n) { return fmtCount(Math.round(n * 10) / 10); }

  /**
   * Attach a drag-to-rotate / auto-spin software renderer to an existing <canvas>.
   * @returns {{ reset:fn, toggleSpin:fn, spinning:()=>boolean, destroy:fn }}
   */
  const hexToRgb = (h) => {
    const m = /^#?([0-9a-f]{6})$/i.exec(String(h || '').trim());
    return m ? [parseInt(m[1].slice(0, 2), 16), parseInt(m[1].slice(2, 4), 16), parseInt(m[1].slice(4, 6), 16)] : null;
  };

  // Named camera angles (yaw, pitch). "iso" matches the classic 3/4 thumbnail view.
  const VIEWS = {
    iso:   { yaw: Math.atan2(-1, 1), pitch: 0.6 },
    front: { yaw: -Math.PI / 2, pitch: 0.05 },
    side:  { yaw: 0, pitch: 0.05 },
    top:   { yaw: -Math.PI / 2, pitch: 1.4 },
  };

  // Prefer the GPU (depth-buffered, solid, no decimation artifacts); fall back to the software
  // rasterizer only when WebGL2 is unavailable. Both expose the identical control interface.
  function mountMeshViewer(canvas, opts) {
    if (typeof mountWebglViewer === 'function') {
      try { const v = mountWebglViewer(canvas, opts); if (v) return v; } catch (e) { try { console.warn('[viewer] WebGL failed, using software renderer:', e && e.message); } catch (_) {} }
    }
    return mountSoftwareViewer(canvas, opts);
  }

  function mountSoftwareViewer(canvas, { verts, count, colors, bed, triColors, triObj, triCode, palette }) {
    const allTris = trisFromVerts(verts, count);
    let plate = bed || null;
    const bakedTcol = (triColors && triColors.length) ? triColors : null;
    const hasCode = !!(triCode && triCode.length === count);
    let curPalette = Array.isArray(palette) ? palette.slice() : null;
    let activeObjs = null;           // null = every plate/object; else a Set of object indices
    let tris = allTris;              // triangle soup currently drawn
    let tcol = bakedTcol;            // per-triangle colours currently drawn (or null → height ramp)

    // 2× supersampling: back the canvas at twice its display size for crisp, anti-aliased
    // edges — CSS keeps the on-screen size, the browser downsamples.
    const SS = 2;
    const base = canvas.width || 460;
    canvas.width = canvas.height = base * SS;
    const S = canvas.width;
    const factory = () => canvas;
    let yaw = VIEWS.iso.yaw, pitch = VIEWS.iso.pitch, zoom = 1, panX = 0, panY = 0, wire = false;
    let spinning = false, raf = 0, mode = null, lastX = 0, lastY = 0, dead = false;

    const cssVar = (n, fb) => (getComputedStyle(document.documentElement).getPropertyValue(n).trim() || fb);
    // A medium studio grey (not the theme surface) so BOTH a white-filament model and a black one
    // read against the background via Lambert shading — a near-white stage makes white models vanish.
    const bg = '#8c93a3';
    const col = hexToRgb(cssVar('--accent', '')) || [120, 144, 168];
    const ramp = Array.isArray(colors) ? colors.map(hexToRgb).filter(Boolean) : [];
    const palRgb = () => (curPalette || []).map((h) => hexToRgb(h) || [180, 180, 185]);

    // Which global triangle indices are visible (null sentinel = all — draw allTris directly).
    function activeIndexList() {
      if (activeObjs === null) return null;
      const idx = [];
      for (let i = 0; i < count; i++) if (activeObjs.has(triObj ? triObj[i] : 0)) idx.push(i);
      return idx;
    }
    // Per-triangle colours for a visible-index list (null = all). Live from triCode+palette when
    // the file was painted; otherwise the baked colouring the main process sent.
    function computeTcol(idx) {
      const n = idx ? idx.length : count;
      if (hasCode && curPalette) {
        const pal = palRgb(), baseC = pal[0] || [180, 180, 185];
        const out = new Uint8Array(n * 3);
        for (let j = 0; j < n; j++) { const gi = idx ? idx[j] : j; const code = triCode[gi]; const c = code === 0xffff ? baseC : (pal[code] || baseC); out[j * 3] = c[0]; out[j * 3 + 1] = c[1]; out[j * 3 + 2] = c[2]; }
        return out;
      }
      if (bakedTcol) {
        if (!idx) return bakedTcol;
        const out = new Uint8Array(n * 3);
        for (let j = 0; j < n; j++) { const gi = idx[j]; out[j * 3] = bakedTcol[gi * 3]; out[j * 3 + 1] = bakedTcol[gi * 3 + 1]; out[j * 3 + 2] = bakedTcol[gi * 3 + 2]; }
        return out;
      }
      return null;
    }
    function rebuild() {
      const idx = activeIndexList();
      tris = idx ? idx.map((i) => allTris[i]) : allTris;
      tcol = computeTcol(idx);
      draw(false);
    }

    const draw = (fast) => {
      if (dead) return;
      KhaytStlThumb.renderStlThumbnail(tris, {
        size: S, yaw, pitch, zoom, panX, panY, canvasFactory: factory,
        background: bg, color: col, colorRamp: ramp.length ? ramp : null, triColors: tcol,
        wireframe: wire && !fast, wireWidth: SS,
        bed: plate ? { x: plate.x, y: plate.y } : null, bedFits: plate ? plate.fits !== false : undefined,
        // Draw the full preview mesh when settled (it's already capped upstream), a lighter
        // sample only while dragging for responsiveness.
        maxTriangles: fast ? 60000 : 300000,
      });
    };
    // Initial colouring: live if painted, else baked.
    tcol = computeTcol(null);

    function stopSpin() { spinning = false; if (raf) cancelAnimationFrame(raf); raf = 0; }
    function tick() { yaw += 0.012; draw(true); raf = requestAnimationFrame(tick); }

    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    canvas.addEventListener('pointerdown', (e) => {
      mode = (e.button === 2 || e.button === 1 || e.shiftKey) ? 'pan' : 'rotate';
      lastX = e.clientX; lastY = e.clientY; try { canvas.setPointerCapture(e.pointerId); } catch (_) {} stopSpin();
    });
    canvas.addEventListener('pointermove', (e) => {
      if (!mode) return;
      const w = canvas.getBoundingClientRect().width || base;
      const dx = e.clientX - lastX, dy = e.clientY - lastY;
      if (mode === 'pan') { panX += dx / w; panY -= dy / w; }
      else { yaw -= dx * 0.01; pitch = clamp(pitch + dy * 0.01, -1.4, 1.4); }
      lastX = e.clientX; lastY = e.clientY;
      draw(true);
    });
    const endDrag = () => { if (mode) { mode = null; draw(false); } };
    canvas.addEventListener('pointerup', endDrag);
    canvas.addEventListener('pointercancel', endDrag);
    canvas.addEventListener('wheel', (e) => {
      e.preventDefault();
      zoom = clamp(zoom * (e.deltaY < 0 ? 1.12 : 0.89), 0.3, 8);
      stopSpin(); draw(true);
      clearTimeout(canvas._wz); canvas._wz = setTimeout(() => draw(false), 140);
    }, { passive: false });

    // Stop the animation loop when the canvas leaves the DOM (modal torn down).
    const mo = new MutationObserver(() => { if (!document.body.contains(canvas)) { dead = true; stopSpin(); mo.disconnect(); } });
    mo.observe(document.getElementById('modalMount') || document.body, { childList: true, subtree: true });

    draw(false);
    return {
      reset() { stopSpin(); yaw = VIEWS.iso.yaw; pitch = VIEWS.iso.pitch; zoom = 1; panX = 0; panY = 0; draw(false); },
      setView(name) { const v = VIEWS[name] || VIEWS.iso; stopSpin(); yaw = v.yaw; pitch = v.pitch; draw(false); },
      setBed(b) { plate = b || null; draw(false); },
      // Live-recolour the model from a new filament palette (index 0 = base, 1.. = paint slots).
      recolor(newPalette) { if (Array.isArray(newPalette)) curPalette = newPalette.slice(); rebuild(); },
      hasLiveColor() { return hasCode && !!curPalette; },
      palette() { return curPalette ? curPalette.slice() : null; },
      // Show only a build plate's objects (array of object indices), or null for all plates.
      setPlate(objs) { stopSpin(); activeObjs = (objs && objs.length) ? new Set(objs) : null; zoom = 1; panX = 0; panY = 0; rebuild(); },
      zoomBy(f) { zoom = clamp(zoom * f, 0.3, 8); draw(false); },
      toggleWire() { wire = !wire; draw(false); return wire; },
      toggleSpin() { if (spinning) { stopSpin(); draw(false); } else { spinning = true; tick(); } return spinning; },
      spinning: () => spinning,
      destroy() { dead = true; stopSpin(); mo.disconnect(); },
    };
  }

  function openModelViewer({ verts, count, bbox, name, colors, volumeMm3, triColors, triObj, triCode, palette, plates }) {
    if (!verts || !count) { toast('No mesh to show.', 'error'); return; }
    const S = 460;
    const dims = bbox ? `${fmtMm(bbox.x)} × ${fmtMm(bbox.y)} × ${fmtMm(bbox.z)} mm` : '';
    const cm3 = volumeMm3 ? volumeMm3 / 1000 : 0;
    const volStr = cm3 ? ` · ${cm3 < 10 ? cm3.toFixed(2) : cm3.toFixed(1)} cm³ · ~${Math.max(1, Math.round(cm3 * 1.24))} g` : '';
    const viewBtn = (k, lbl) => `<button type="button" class="btn ghost small mv-view" data-view="${k}">${escapeHtml(lbl)}</button>`;
    const multiPlate = Array.isArray(plates) && plates.length > 1;
    const plateSel = multiPlate
      ? `<label class="mv-plate"><span>${escapeHtml(t('conv.plate') || 'Plate')}</span><select id="mvPlate">${plates.map((p, i) => `<option value="${i}"${i === 0 ? ' selected' : ''}>${escapeHtml(p.name || ('Plate ' + (i + 1)))}</option>`).join('')}<option value="-1">${escapeHtml(t('conv.all_plates') || 'All plates')}</option></select></label>`
      : '';
    const body = `
      <div class="mv-wrap">
        <div class="mv-stage">
          <canvas id="mvCanvas" width="${S}" height="${S}" class="mv-canvas" aria-label="3D preview"></canvas>
          <div class="mv-hint">${escapeHtml(t('plib.view3d_hint2') || 'Drag rotate · scroll zoom · shift-drag pan')}</div>
        </div>
        <div class="mv-views">
          ${viewBtn('iso', t('view3d.iso') || 'Iso')}${viewBtn('front', t('view3d.front') || 'Front')}${viewBtn('top', t('view3d.top') || 'Top')}${viewBtn('side', t('view3d.side') || 'Side')}
          ${plateSel}
        </div>
        <div id="mvColors" class="mv-colors"></div>
        <div class="mv-bar">
          <span class="mv-meta">${escapeHtml(name || '')}${dims ? ` · <b>${escapeHtml(dims)}</b>` : ''}${escapeHtml(volStr)} · ${fmtCount(count)} △</span>
          <span class="mv-btns">
            <button type="button" class="btn ghost small" id="mvWire">${escapeHtml(t('view3d.wireframe') || 'Wireframe')}</button>
            <button type="button" class="btn ghost small" id="mvSpin">${escapeHtml(t('plib.view3d_spin') || 'Auto-spin')}</button>
            <button type="button" class="btn ghost small" id="mvReset">${escapeHtml(t('plib.view3d_reset') || 'Reset')}</button>
          </span>
        </div>
      </div>`;

    openFormModal({
      title: ((typeof document !== 'undefined' && document.documentElement.dataset.app === 'bedready') ? '' : '🧊 ') + (t('plib.view3d') || 'View in 3D'),
      bodyHtml: body,
      noSave: true,
      onMount(modal) {
        const ctl = mountMeshViewer(modal.querySelector('#mvCanvas'), { verts, count, colors, triColors, triObj, triCode, palette });
        const spinBtn = modal.querySelector('#mvSpin');
        spinBtn.addEventListener('click', () => spinBtn.classList.toggle('on', ctl.toggleSpin()));
        const wireBtn = modal.querySelector('#mvWire');
        wireBtn.addEventListener('click', () => wireBtn.classList.toggle('on', ctl.toggleWire()));
        modal.querySelector('#mvReset').addEventListener('click', () => { ctl.reset(); spinBtn.classList.remove('on'); });
        modal.querySelectorAll('.mv-view').forEach((b) => b.addEventListener('click', () => { ctl.setView(b.dataset.view); spinBtn.classList.remove('on'); }));
        const plateEl = modal.querySelector('#mvPlate');
        if (plateEl) {
          plateEl.addEventListener('change', () => { const i = parseInt(plateEl.value, 10); ctl.setPlate(i >= 0 && plates[i] ? plates[i].objs : null); });
          if (plates && plates[0]) ctl.setPlate(plates[0].objs); // start on plate 1, like a slicer
        }
        // Live colour swatches — edit a filament colour and the model recolours instantly.
        const pal = ctl.hasLiveColor && ctl.hasLiveColor() ? ctl.palette() : null;
        const colBox = modal.querySelector('#mvColors');
        if (pal && pal.length && colBox) {
          colBox.innerHTML = pal.map((hex, i) => `<input type="color" class="mv-col" data-i="${i}" value="${safeCssColor(hex, '#cccccc')}" title="${escapeHtml((t('conv.filament') || 'Filament') + ' ' + (i + 1))}">`).join('');
          const cols = colBox.querySelectorAll('.mv-col');
          cols.forEach((inp) => inp.addEventListener('input', () => { const next = ctl.palette() || []; cols.forEach((c) => { next[+c.dataset.i] = c.value; }); ctl.recolor(next); }));
        }
      },
    });
  }

  const api = { openModelViewer, mountMeshViewer };
  Object.assign(global, api);
  global.KhaytModelViewer = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
