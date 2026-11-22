#!/usr/bin/env node
/* Verify the converter's 3D source preview end-to-end. Generates a real cube as both
 * STL and 3MF in the OS temp dir (which the converter's read guard allows), then:
 *  - calls hub.convertMesh({path}) for each and checks the flat mesh comes back,
 *  - opens the full openConverter modal on the 3MF and checks the preview canvas
 *    mounts + rasterizes (the "know what you're converting" panel). */
import path from 'path';
import fs from 'fs';
import os from 'os';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';
import { _electron as electron } from 'playwright-core';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const require = createRequire(import.meta.url);
const mfw = require(path.join(root, 'lib/mf-write.js'));

function assert(label, cond) { if (!cond) throw new Error(`ASSERT FAILED: ${label}`); console.log(`  ✓ ${label}`); }

// A 20mm cube as triangle soup [[x,y,z]×3].
function cubeTris(s = 20) {
  const v = (x, y, z) => [x, y, z];
  const q = (a, b, c, d) => [[a, b, c], [a, c, d]];
  let t = [];
  t = t.concat(q(v(0, 0, 0), v(s, 0, 0), v(s, s, 0), v(0, s, 0)));
  t = t.concat(q(v(0, 0, s), v(0, s, s), v(s, s, s), v(s, 0, s)));
  t = t.concat(q(v(0, 0, 0), v(0, 0, s), v(s, 0, s), v(s, 0, 0)));
  t = t.concat(q(v(0, s, 0), v(s, s, 0), v(s, s, s), v(0, s, s)));
  t = t.concat(q(v(0, 0, 0), v(0, s, 0), v(0, s, s), v(0, 0, s)));
  t = t.concat(q(v(s, 0, 0), v(s, 0, s), v(s, s, s), v(s, s, 0)));
  return t;
}

async function main() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'br-conv-'));
  const tris = cubeTris(20);
  const stlPath = path.join(dir, 'cube.stl');
  const mfPath = path.join(dir, 'cube.3mf');
  fs.writeFileSync(stlPath, mfw.trianglesToStl(tris));
  fs.writeFileSync(mfPath, mfw.meshTo3mf(tris));
  assert('generated cube.stl + cube.3mf fixtures', fs.existsSync(stlPath) && fs.existsSync(mfPath) && fs.statSync(mfPath).size > 100);

  const app = await electron.launch({
    args: ['.', `--user-data-dir=${fs.mkdtempSync(path.join(os.tmpdir(), 'br-conv-ud-'))}`], cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', KHAYT_FLAVOR: 'bedready' }, timeout: 120_000,
  });
  const w = await app.firstWindow();
  const errs = [];
  w.on('pageerror', (e) => errs.push(String(e && e.message || e)));
  await w.waitForSelector('.khayt-app', { timeout: 60_000 });
  await w.waitForFunction(() => typeof window.openConverter === 'function'
    && typeof window.mountMeshViewer === 'function' && !!window.hubAPI?.convertMesh, { timeout: 60_000 });

  // 1) convertMesh IPC for both formats.
  for (const [label, p] of [['STL', stlPath], ['3MF', mfPath]]) {
    const m = await w.evaluate((p) => window.hubAPI.convertMesh({ path: p }), p);
    assert(`convertMesh(${label}) → ok mesh (${m && m.count} tri)`, m && m.ok && m.count === 12);
    assert(`convertMesh(${label}) bbox ≈ 20mm`, m && Math.round(m.bbox.x) === 20 && Math.round(m.bbox.z) === 20);
    assert(`convertMesh(${label}) volume ≈ 8000 mm³ (20³ cube)`, m && Math.abs(m.volumeMm3 - 8000) < 50);
    const shades = await w.evaluate((mesh) => {
      const c = document.createElement('canvas'); c.width = c.height = 200; document.body.appendChild(c);
      window.mountMeshViewer(c, { verts: mesh.verts, count: mesh.count });
      const d = c.getContext('2d').getImageData(0, 0, 200, 200).data;
      const s = new Set(); for (let i = 0; i < d.length; i += 4 * 53) s.add(d[i] + ',' + d[i + 1] + ',' + d[i + 2]);
      c.remove(); return s.size;
    }, m);
    assert(`convertMesh(${label}) rasterizes (${shades} shades)`, shades >= 3);
  }

  // 1b) "full spectrum" colour ramp — a multicolour model shades its declared colours
  // as a height gradient (red bottom → blue → green top), not one flat colour. Rendered
  // directly on a black background so the three hue bands are cleanly separable.
  const hues = await w.evaluate(() => {
    // A tall stack of thin slabs — many triangles distributed across the height, like a
    // real mesh, so the ramp is sampled top-to-bottom (a single box only has 2 tris/face).
    const box = (() => {
      const s = 20, v = (x, y, z) => [x, y, z], q = (a, b, c, d) => [[a, b, c], [a, c, d]]; let t = [];
      for (let k = 0; k < 24; k++) {
        const z0 = k * 4, z1 = z0 + 3.6;
        t = t.concat(q(v(0, 0, z0), v(s, 0, z0), v(s, s, z0), v(0, s, z0)));
        t = t.concat(q(v(0, 0, z1), v(0, s, z1), v(s, s, z1), v(s, 0, z1)));
        t = t.concat(q(v(0, 0, z0), v(0, 0, z1), v(s, 0, z1), v(s, 0, z0)));
        t = t.concat(q(v(0, s, z0), v(s, s, z0), v(s, s, z1), v(0, s, z1)));
        t = t.concat(q(v(0, 0, z0), v(0, s, z0), v(0, s, z1), v(0, 0, z1)));
        t = t.concat(q(v(s, 0, z0), v(s, 0, z1), v(s, s, z1), v(s, s, z0)));
      }
      return t;
    })();
    const r = window.KhaytStlThumb.renderStlThumbnail(box, { size: 240, yaw: Math.atan2(-1, 1), pitch: 0.55, background: '#000000',
      colorRamp: [[255, 45, 45], [45, 107, 255], [45, 255, 136]], canvasFactory: (s) => { const c = document.createElement('canvas'); c.width = c.height = s; return c; } });
    const d = r.canvas.getContext('2d').getImageData(0, 0, 240, 240).data;
    let red = 0, blue = 0, green = 0;
    for (let i = 0; i < d.length; i += 4) {
      const R = d[i], G = d[i + 1], B = d[i + 2];
      if (R + G + B < 45) continue; // black background
      if (R > G + 20 && R > B + 20) red++;
      else if (B > R + 20 && B > G) blue++;
      else if (G > R + 20 && G > B + 20) green++;
    }
    return { red, blue, green };
  });
  assert(`spectrum ramp shows red+blue+green bands (r=${hues.red} b=${hues.blue} g=${hues.green})`, hues.red > 30 && hues.blue > 30 && hues.green > 30);

  // 1c) always-load fallback: a 3MF whose geometry can't be parsed but which has an
  // embedded plate thumbnail → convertMesh returns {ok:false, thumb}, and the preview
  // shows that 2D image instead of vanishing.
  const PNG1x1 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
  const noGeoMf = path.join(dir, 'nogeo.3mf');
  fs.writeFileSync(noGeoMf, require(path.join(root, 'lib/zip-write.js')).writeZip([
    { name: '[Content_Types].xml', data: '<?xml version="1.0"?><Types/>' },
    { name: '3D/3dmodel.model', data: '<?xml version="1.0"?><model unit="millimeter"><resources></resources><build></build></model>' },
    { name: 'Metadata/plate_1.png', data: Buffer.from(PNG1x1, 'base64') },
  ]));
  const nm = await w.evaluate((p) => window.hubAPI.convertMesh({ path: p }), noGeoMf);
  assert('no-geometry 3MF → convertMesh returns a thumbnail fallback', nm && nm.ok === false && typeof nm.thumb === 'string' && nm.thumb.startsWith('data:image/'));
  const fbImg = await w.evaluate((mesh) => {
    const panel = document.createElement('div'); panel.id = 'tPanel';
    const cv = document.createElement('canvas'); cv.className = 'conv-preview-canvas'; cv.width = cv.height = 100;
    const hint = document.createElement('div'); hint.className = 'conv-preview-hint';
    panel.appendChild(cv); panel.appendChild(hint); document.body.appendChild(panel);
    window.KhaytConverter._renderPreviewInto(panel, cv, mesh, []);
    const img = panel.querySelector('img.conv-preview-img');
    const r = { hasImg: !!img, src: img && img.src.slice(0, 15), canvasHidden: cv.style.display === 'none', hint: hint.textContent };
    panel.remove(); return r;
  }, nm);
  assert('fallback renders a 2D <img> (canvas hidden, hint updated)', fbImg.hasImg && /^data:image/.test(fbImg.src) && fbImg.canvasHidden && /preview/i.test(fbImg.hint));

  // 1d) build-plate: the grid/outline appears only when a bed is given. Colour-keyed —
  // render the model RED so the grayish-blue bed grid is countable (blue-dominant pixels).
  const bedCmp = await w.evaluate(() => {
    const mk = () => { const c = document.createElement('canvas'); c.width = c.height = 300; return c; };
    const cube = (() => { const s = 20, v = (x, y, z) => [x, y, z], q = (a, b, c, d) => [[a, b, c], [a, c, d]]; let t = [];
      t = t.concat(q(v(0, 0, 0), v(s, 0, 0), v(s, s, 0), v(0, s, 0))); t = t.concat(q(v(0, 0, s), v(0, s, s), v(s, s, s), v(s, 0, s)));
      t = t.concat(q(v(0, 0, 0), v(0, 0, s), v(s, 0, s), v(s, 0, 0))); t = t.concat(q(v(0, s, 0), v(s, s, 0), v(s, s, s), v(0, s, s)));
      t = t.concat(q(v(0, 0, 0), v(0, s, 0), v(0, s, s), v(0, 0, s))); t = t.concat(q(v(s, 0, 0), v(s, 0, s), v(s, s, s), v(s, s, 0))); return t; })();
    const bluish = (c) => { const d = c.getContext('2d').getImageData(0, 0, 300, 300).data; let n = 0; for (let i = 0; i < d.length; i += 4) if (d[i + 2] > d[i] + 15 && d[i] + d[i + 1] + d[i + 2] > 40) n++; return n; };
    const opt = (bed) => ({ size: 300, yaw: Math.atan2(-1, 1), pitch: 0.6, background: '#000000', color: [230, 55, 55], bed, canvasFactory: mk });
    return {
      noBed: bluish(window.KhaytStlThumb.renderStlThumbnail(cube, opt(null)).canvas),
      withBed: bluish(window.KhaytStlThumb.renderStlThumbnail(cube, opt({ x: 120, y: 120 })).canvas),
    };
  });
  assert(`build-plate grid renders only with a bed (${bedCmp.noBed} → ${bedCmp.withBed})`, bedCmp.noBed < 30 && bedCmp.withBed > 200);

  // 1e) TRUE multicolour: a painted 3MF (per-facet paint_color + a filament palette) →
  // convertMesh returns per-triangle colours that render the real painted regions.
  const paintedMf = path.join(dir, 'painted.3mf');
  const V = [[0,0,0],[20,0,0],[20,20,0],[0,20,0],[0,0,20],[20,0,20],[20,20,20],[0,20,20]];
  const F = [[0,1,2],[0,2,3],[4,5,6,'4'],[4,6,7,'4'],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]; // top 2 painted
  const model = `<?xml version="1.0"?><model unit="millimeter"><resources><object id="1" type="model"><mesh>`
    + `<vertices>${V.map(([x,y,z]) => `<vertex x="${x}" y="${y}" z="${z}"/>`).join('')}</vertices>`
    + `<triangles>${F.map((f) => `<triangle v1="${f[0]}" v2="${f[1]}" v3="${f[2]}"${f[3] ? ` paint_color="${f[3]}"` : ''}/>`).join('')}</triangles>`
    + `</mesh></object></resources><build><item objectid="1"/></build></model>`;
  fs.writeFileSync(paintedMf, require(path.join(root, 'lib/zip-write.js')).writeZip([
    { name: '[Content_Types].xml', data: '<?xml version="1.0"?><Types/>' },
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/project_settings.config', data: JSON.stringify({ filament_colour: ['#E23030', '#3060E0'] }) },
  ]));
  const pm = await w.evaluate(async (p) => {
    const mesh = await window.hubAPI.convertMesh({ path: p });
    if (!mesh || !mesh.ok || !mesh.triColors) return { ok: false };
    const c = document.createElement('canvas'); c.width = c.height = 240;
    window.mountMeshViewer(c, { verts: mesh.verts, count: mesh.count, triColors: mesh.triColors });
    const W = c.width; // mountMeshViewer resizes the backing store for supersampling
    const d = c.getContext('2d').getImageData(0, 0, W, W).data;
    let red = 0, blue = 0;
    for (let i = 0; i < d.length; i += 4) { const R = d[i], G = d[i + 1], B = d[i + 2]; if (R + G + B < 40) continue; if (R > B + 25) red++; else if (B > R + 25) blue++; }
    c.remove();
    return { ok: true, len: mesh.triColors.length, count: mesh.count, red, blue };
  }, paintedMf);
  assert('painted 3MF → per-triangle colours present', pm.ok && pm.len === pm.count * 3);
  assert(`painted regions render two distinct colours (red=${pm.red} blue=${pm.blue})`, pm.red > 100 && pm.blue > 100);

  // 2) full converter modal on the 3MF — preview canvas mounts + hint flips to "Drag to rotate".
  await w.evaluate(() => window.switchTab('converter-tab'));
  await w.waitForTimeout(200);
  await w.evaluate((p) => window.openConverter({ path: p, name: 'cube.3mf' }), mfPath);
  await w.waitForSelector('#convPreviewCanvas', { timeout: 8000 });
  await w.waitForFunction(() => {
    const h = document.querySelector('#convPreview .conv-preview-hint');
    return h && /rotate|درو|Drag|glisser|回転|döndür|Ziehen|rotar|旋转/i.test(h.textContent);
  }, { timeout: 8000 });
  assert('converter modal shows a live source preview', true);

  await w.screenshot({ path: path.join(root, 'scratch-converter-preview.png') });
  console.log('  screenshot → scratch-converter-preview.png');
  assert('no renderer errors', errs.length === 0);
  if (errs.length) console.log(errs);
  await app.close();
  console.log('\nOK — converter preview verified.');
}
main().catch((e) => { console.error(e); process.exit(1); });
