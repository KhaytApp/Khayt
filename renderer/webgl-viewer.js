'use strict';
/*
 * WebGL model viewer (Bed Ready) — a real GPU renderer with a depth buffer, so dense,
 * multi-part and thin-featured models render solid and correctly occluded (no painter's-
 * algorithm see-through, no spikes, no aggressive decimation). This is the preferred path;
 * renderer/model-viewer.js falls back to the software rasterizer when WebGL2 is unavailable.
 *
 * Raw WebGL2 (no three.js): flat-shaded per-vertex colours, camera-space lighting via
 * screen-space derivatives, orbit / dolly / pan, live recolour and per-plate filtering.
 * Exposes the SAME control interface as the software viewer so callers don't branch.
 */
(function (global) {
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const hexToRgb = (h) => {
    const m = /^#?([0-9a-f]{6})$/i.exec(String(h || '').trim());
    return m ? [parseInt(m[1].slice(0, 2), 16), parseInt(m[1].slice(2, 4), 16), parseInt(m[1].slice(4, 6), 16)] : null;
  };

  // Named camera angles (yaw, pitch) — matched to the software viewer's presets.
  const VIEWS = {
    iso: { yaw: -Math.PI / 4, pitch: 0.6 },
    front: { yaw: 0, pitch: 0.06 },
    side: { yaw: Math.PI / 2, pitch: 0.06 },
    top: { yaw: 0, pitch: Math.PI / 2 - 0.01 },
  };

  /* ---- column-major 4×4 matrix helpers ---- */
  const ident = () => { const o = new Float32Array(16); o[0] = o[5] = o[10] = o[15] = 1; return o; };
  const mul = (a, b) => {
    const o = new Float32Array(16);
    for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) { let s = 0; for (let k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k]; o[c * 4 + r] = s; }
    return o;
  };
  const trans = (x, y, z) => { const o = ident(); o[12] = x; o[13] = y; o[14] = z; return o; };
  const rotX = (a) => { const c = Math.cos(a), s = Math.sin(a), o = ident(); o[5] = c; o[6] = s; o[9] = -s; o[10] = c; return o; };
  const rotY = (a) => { const c = Math.cos(a), s = Math.sin(a), o = ident(); o[0] = c; o[2] = -s; o[8] = s; o[10] = c; return o; };
  const persp = (fovy, asp, n, f) => { const t = 1 / Math.tan(fovy / 2); const o = new Float32Array(16); o[0] = t / asp; o[5] = t; o[10] = (f + n) / (n - f); o[11] = -1; o[14] = (2 * f * n) / (n - f); return o; };

  const VS = `#version 300 es
  layout(location=0) in vec3 aPos;
  layout(location=1) in vec3 aColor;
  uniform mat4 uMV; uniform mat4 uProj;
  out vec3 vColor; out vec3 vView;
  void main(){ vec4 mv = uMV * vec4(aPos,1.0); vView = mv.xyz; vColor = aColor; gl_Position = uProj * mv; }`;
  const FS = `#version 300 es
  precision highp float;
  in vec3 vColor; in vec3 vView; out vec4 frag;
  void main(){
    vec3 n = normalize(cross(dFdx(vView), dFdy(vView)));
    if (n.z < 0.0) n = -n;              // face the camera (flat-shaded, so treat both sides as lit)
    vec3 V = vec3(0.0,0.0,1.0);         // view direction (camera space)
    vec3 key = normalize(vec3(0.35,0.55,0.75));
    vec3 fillL = normalize(vec3(-0.5,0.1,0.4));
    // Soft hemispheric ambient: sky slightly cool, ground slightly warm — gives volume without shadows.
    vec3 sky = vec3(0.62,0.66,0.72), ground = vec3(0.42,0.40,0.38);
    vec3 amb = mix(ground, sky, 0.5 + 0.5*n.y);
    float kd = max(0.0, dot(n, key));
    float fd = max(0.0, dot(n, fillL));
    // Wrapped diffuse softens the terminator so detailed meshes don't read as noisy.
    kd = kd*0.7 + 0.3;
    vec3 lit = vColor * (amb*0.55 + kd*0.85 + fd*0.18);
    // Gentle rim/fresnel to lift silhouettes off the background.
    float rim = pow(1.0 - max(0.0, dot(n, V)), 3.0) * 0.25;
    lit += rim * vec3(0.9,0.93,1.0);
    // Soft filmic-ish tone + gamma for a less flat, more "studio" look.
    lit = lit / (lit + vec3(0.9)) * 1.9;
    lit = pow(clamp(lit, 0.0, 1.0), vec3(0.9));
    frag = vec4(lit, 1.0);
  }`;
  // Bed grid: plain position-only lines.
  const LVS = `#version 300 es
  layout(location=0) in vec3 aPos; uniform mat4 uMV; uniform mat4 uProj;
  void main(){ gl_Position = uProj * uMV * vec4(aPos,1.0); }`;
  const LFS = `#version 300 es
  precision highp float; uniform vec4 uColor; out vec4 frag; void main(){ frag = uColor; }`;

  function compile(gl, type, src) {
    const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) { try { console.warn('[webgl] shader', gl.getShaderInfoLog(s)); } catch (_) {} gl.deleteShader(s); return null; }
    return s;
  }
  function program(gl, vs, fs) {
    const v = compile(gl, gl.VERTEX_SHADER, vs), f = compile(gl, gl.FRAGMENT_SHADER, fs);
    if (!v || !f) return null;
    const p = gl.createProgram(); gl.attachShader(p, v); gl.attachShader(p, f); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) { try { console.warn('[webgl] link', gl.getProgramInfoLog(p)); } catch (_) {} return null; }
    return p;
  }

  function mountWebglViewer(canvas, opts) {
    const o = opts || {};
    const verts = o.verts, count = o.count | 0;
    if (!verts || !count) return null;
    let gl;
    try { gl = canvas.getContext('webgl2', { antialias: true, alpha: true, premultipliedAlpha: false, preserveDrawingBuffer: true }); } catch (_) { gl = null; }
    if (!gl) return null;
    const prog = program(gl, VS, FS), lprog = program(gl, LVS, LFS);
    if (!prog) return null;

    // Backing-store size: display size × DPR (≤2) for crisp edges; CSS keeps on-screen size.
    const dpr = Math.min(2, (global.devicePixelRatio || 1));
    const base = canvas.clientWidth || canvas.width || 340;
    canvas.width = canvas.height = Math.round(base * dpr);

    // Colour helpers.
    const palRgb = () => (curPalette || []).map((h) => hexToRgb(h) || [180, 180, 185]);
    const triColors = (o.triColors && o.triColors.length) ? o.triColors : null;
    const hasCode = !!(o.triCode && o.triCode.length === count);
    let curPalette = Array.isArray(o.palette) ? o.palette.slice() : null;
    const triObj = o.triObj || null;
    let activeObjs = null; // null = all
    let bed = o.bed || null;

    // Camera framing — recomputed from whatever's visible (so a filtered plate frames itself,
    // not the whole multi-plate layout).
    const FOV = 0.62; // ~35°
    let cx = 0, cy = 0, cz = 0, radius = 1, dist0 = 1;
    function frame(idx) {
      const n = idx ? idx.length : count;
      let x0 = Infinity, y0 = Infinity, z0 = Infinity, x1 = -Infinity, y1 = -Infinity, z1 = -Infinity;
      for (let j = 0; j < n; j++) {
        const s = (idx ? idx[j] : j) * 9;
        for (let v = 0; v < 3; v++) {
          const x = verts[s + v * 3], y = verts[s + v * 3 + 1], z = verts[s + v * 3 + 2];
          if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; if (z < z0) z0 = z; if (z > z1) z1 = z;
        }
      }
      if (!Number.isFinite(x0)) return;
      cx = (x0 + x1) / 2; cy = (y0 + y1) / 2; cz = (z0 + z1) / 2;
      radius = Math.max(1e-3, 0.5 * Math.hypot(x1 - x0, y1 - y0, z1 - z0));
      dist0 = radius / Math.tan(FOV / 2) * 1.15;
    }

    // GL state.
    gl.enable(gl.DEPTH_TEST);
    gl.clearColor(0.549, 0.576, 0.639, 1); // #8c93a3 studio grey, matches software stage
    const uMV = gl.getUniformLocation(prog, 'uMV'), uProj = gl.getUniformLocation(prog, 'uProj');
    // Separate VAOs for the mesh and the bed grid — they both use attribute location 0, so sharing
    // one VAO let the bed's tiny buffer clobber the mesh's binding ("buffer not big enough").
    const vao = gl.createVertexArray();
    const bedVao = gl.createVertexArray();
    const posBuf = gl.createBuffer(), colBuf = gl.createBuffer();
    let drawN = 0;

    // Camera-space colour for a global triangle index (0..1 rgb).
    function triCol(gi) {
      if (hasCode && curPalette) { const pr = palRgb(); const c = pr[o.triCode[gi]] || pr[0] || [180, 180, 185]; return [c[0] / 255, c[1] / 255, c[2] / 255]; }
      if (triColors) return [triColors[gi * 3] / 255, triColors[gi * 3 + 1] / 255, triColors[gi * 3 + 2] / 255];
      return [0.72, 0.75, 0.8];
    }
    function activeIdx() {
      if (activeObjs === null) return null;
      const idx = []; for (let i = 0; i < count; i++) if (activeObjs.has(triObj ? triObj[i] : 0)) idx.push(i);
      return idx.length ? idx : null;
    }
    function upload() {
      gl.bindVertexArray(vao);
      const idx = activeIdx();
      frame(idx);
      const n = idx ? idx.length : count;
      const pos = new Float32Array(n * 9), col = new Float32Array(n * 9);
      for (let j = 0; j < n; j++) {
        const gi = idx ? idx[j] : j, s = gi * 9, d = j * 9;
        for (let k = 0; k < 9; k++) pos[d + k] = verts[s + k];
        const c = triCol(gi);
        for (let v = 0; v < 3; v++) { col[d + v * 3] = c[0]; col[d + v * 3 + 1] = c[1]; col[d + v * 3 + 2] = c[2]; }
      }
      gl.bindBuffer(gl.ARRAY_BUFFER, posBuf); gl.bufferData(gl.ARRAY_BUFFER, pos, gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 0, 0);
      gl.bindBuffer(gl.ARRAY_BUFFER, colBuf); gl.bufferData(gl.ARRAY_BUFFER, col, gl.STATIC_DRAW);
      gl.enableVertexAttribArray(1); gl.vertexAttribPointer(1, 3, gl.FLOAT, false, 0, 0);
      drawN = n * 3;
    }
    function recolorOnly() {
      const idx = activeIdx(); const n = idx ? idx.length : count;
      const col = new Float32Array(n * 9);
      for (let j = 0; j < n; j++) { const gi = idx ? idx[j] : j, c = triCol(gi); for (let v = 0; v < 3; v++) { col[j * 9 + v * 3] = c[0]; col[j * 9 + v * 3 + 1] = c[1]; col[j * 9 + v * 3 + 2] = c[2]; } }
      gl.bindBuffer(gl.ARRAY_BUFFER, colBuf); gl.bufferData(gl.ARRAY_BUFFER, col, gl.STATIC_DRAW);
    }

    // Bed grid geometry (lines), rebuilt when the bed changes.
    let bedBuf = null, bedN = 0, bedFits = true;
    function buildBed() {
      if (bedBuf) { gl.deleteBuffer(bedBuf); bedBuf = null; bedN = 0; }
      if (!bed || !bed.x || !bed.y) return;
      const bx = bed.x, by = bed.y, step = bx <= 150 ? 10 : bx <= 320 ? 25 : 50;
      const segs = [];
      for (let gx = 0; gx <= bx + 1e-6; gx += step) segs.push(gx, 0, 0, gx, by, 0);
      for (let gy = 0; gy <= by + 1e-6; gy += step) segs.push(0, gy, 0, bx, gy, 0);
      bedFits = bed.fits !== false;
      gl.bindVertexArray(bedVao);
      bedBuf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, bedBuf); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(segs), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 0, 0);
      bedN = segs.length / 3;
    }

    // Camera state.
    let yaw = VIEWS.iso.yaw, pitch = VIEWS.iso.pitch, zoom = 1, panX = 0, panY = 0;
    let spinning = false, raf = 0, mode = null, lastX = 0, lastY = 0, dead = false;

    function viewMatrix() {
      const dist = dist0 / zoom;
      let m = mul(trans(panX * radius, panY * radius, -dist), rotX(pitch));
      m = mul(m, rotY(yaw));
      // model uses +Z up; tilt so Z is up on screen (rotate -90° about X once baked into center move)
      m = mul(m, trans(-cx, -cy, -cz));
      return m;
    }
    function draw() {
      if (dead) return;
      const w = canvas.width, h = canvas.height;
      gl.viewport(0, 0, w, h);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      const view = viewMatrix();
      const proj = persp(FOV, w / h, Math.max(0.01, dist0 * 0.01), dist0 * 20 + radius * 8);
      // Bed first (under the model), then mesh.
      if (bedN && lprog) {
        gl.useProgram(lprog);
        gl.bindVertexArray(bedVao);
        gl.uniformMatrix4fv(gl.getUniformLocation(lprog, 'uMV'), false, view);
        gl.uniformMatrix4fv(gl.getUniformLocation(lprog, 'uProj'), false, proj);
        gl.uniform4f(gl.getUniformLocation(lprog, 'uColor'), bedFits ? 0.35 : 0.8, bedFits ? 0.55 : 0.3, bedFits ? 0.7 : 0.3, 0.55);
        gl.drawArrays(gl.LINES, 0, bedN);
      }
      gl.useProgram(prog);
      gl.bindVertexArray(vao);
      gl.uniformMatrix4fv(uMV, false, view);
      gl.uniformMatrix4fv(uProj, false, proj);
      gl.drawArrays(gl.TRIANGLES, 0, drawN);
    }

    function stopSpin() { spinning = false; if (raf) cancelAnimationFrame(raf); raf = 0; }
    function tick() { yaw += 0.012; draw(); raf = requestAnimationFrame(tick); }

    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    canvas.addEventListener('pointerdown', (e) => { mode = (e.button === 2 || e.button === 1 || e.shiftKey) ? 'pan' : 'rot'; lastX = e.clientX; lastY = e.clientY; try { canvas.setPointerCapture(e.pointerId); } catch (_) {} stopSpin(); });
    canvas.addEventListener('pointermove', (e) => {
      if (!mode) return;
      const w = canvas.getBoundingClientRect().width || base;
      const dx = e.clientX - lastX, dy = e.clientY - lastY;
      if (mode === 'pan') { panX += dx / w * 1.6 / zoom; panY -= dy / w * 1.6 / zoom; }
      else { yaw += dx * 0.01; pitch = clamp(pitch + dy * 0.01, -Math.PI / 2 + 0.02, Math.PI / 2 - 0.02); }
      lastX = e.clientX; lastY = e.clientY; draw();
    });
    const end = () => { mode = null; };
    canvas.addEventListener('pointerup', end);
    canvas.addEventListener('pointercancel', end);
    canvas.addEventListener('wheel', (e) => { e.preventDefault(); zoom = clamp(zoom * (e.deltaY < 0 ? 1.12 : 0.89), 0.2, 20); stopSpin(); draw(); }, { passive: false });

    // Keyboard orbit/zoom so the preview is operable without a pointer (accessibility). Arrows orbit,
    // +/- zoom, Home resets. Only act on keys we own so Tab/Esc still bubble out of the modal.
    canvas.tabIndex = 0;
    canvas.setAttribute('role', 'img');
    if (!canvas.getAttribute('aria-label')) canvas.setAttribute('aria-label', '3D model preview — arrow keys orbit, plus/minus zoom');
    canvas.addEventListener('keydown', (e) => {
      const k = e.key;
      let hit = true;
      if (k === 'ArrowLeft') yaw -= 0.14;
      else if (k === 'ArrowRight') yaw += 0.14;
      else if (k === 'ArrowUp') pitch = clamp(pitch - 0.12, -Math.PI / 2 + 0.02, Math.PI / 2 - 0.02);
      else if (k === 'ArrowDown') pitch = clamp(pitch + 0.12, -Math.PI / 2 + 0.02, Math.PI / 2 - 0.02);
      else if (k === '+' || k === '=') zoom = clamp(zoom * 1.12, 0.2, 20);
      else if (k === '-' || k === '_') zoom = clamp(zoom * 0.89, 0.2, 20);
      else if (k === 'Home') { yaw = VIEWS.iso.yaw; pitch = VIEWS.iso.pitch; zoom = 1; panX = 0; panY = 0; }
      else hit = false;
      if (hit) { e.preventDefault(); stopSpin(); draw(); }
    });

    const mo = new MutationObserver(() => { if (!document.body.contains(canvas)) { destroy(); } });
    mo.observe(document.getElementById('modalMount') || document.body, { childList: true, subtree: true });

    function destroy() {
      if (dead) return; dead = true; stopSpin(); try { mo.disconnect(); } catch (_) {}
      try { const ext = gl.getExtension('WEBGL_lose_context'); if (ext) ext.loseContext(); } catch (_) {}
    }

    upload(); buildBed(); draw();

    return {
      reset() { stopSpin(); yaw = VIEWS.iso.yaw; pitch = VIEWS.iso.pitch; zoom = 1; panX = 0; panY = 0; draw(); },
      setView(name) { const v = VIEWS[name] || VIEWS.iso; stopSpin(); yaw = v.yaw; pitch = v.pitch; panX = 0; panY = 0; draw(); },
      setBed(b) { bed = b || null; buildBed(); draw(); },
      recolor(next) { if (Array.isArray(next)) curPalette = next.slice(); recolorOnly(); draw(); },
      hasLiveColor() { return hasCode && !!curPalette; },
      palette() { return curPalette ? curPalette.slice() : null; },
      setPlate(objs) { stopSpin(); activeObjs = (objs && objs.length) ? new Set(objs) : null; zoom = 1; panX = 0; panY = 0; upload(); draw(); },
      zoomBy(f) { zoom = clamp(zoom * f, 0.2, 20); draw(); },
      toggleWire() { return false; }, // depth-buffered solid; wireframe not offered on the GPU path
      toggleSpin() { if (spinning) { stopSpin(); draw(); } else { spinning = true; tick(); } return spinning; },
      spinning: () => spinning,
      destroy,
      _webgl: true,
    };
  }

  global.mountWebglViewer = mountWebglViewer;
})(typeof globalThis !== 'undefined' ? globalThis : window);
