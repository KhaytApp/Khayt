#!/usr/bin/env node
/* Boots Bed Ready and exercises the interactive 3D model viewer end-to-end through the
 * real mesh pipeline: generate an STL (calibration temp tower) → parse it with KhaytStl
 * → flatten to the same {verts,count} shape the main process returns → openModelViewer.
 * Verifies the canvas actually rasterizes a mesh, that rotating changes the image, and
 * that auto-spin runs, then screenshots it. */
import path from 'path';
import fs from 'fs';
import os from 'os';
import { fileURLToPath } from 'url';
import { _electron as electron } from 'playwright-core';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'br-mv-'));

function assert(label, cond) { if (!cond) throw new Error(`ASSERT FAILED: ${label}`); console.log(`  ✓ ${label}`); }

async function main() {
  const app = await electron.launch({
    args: ['.', `--user-data-dir=${userData}`],
    cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', KHAYT_FLAVOR: 'bedready' },
    timeout: 120_000,
  });
  const w = await app.firstWindow();
  const errs = [];
  w.on('pageerror', (e) => errs.push(String(e && e.message || e)));
  await w.waitForSelector('.khayt-app', { timeout: 60_000 });
  await w.waitForFunction(() => typeof window.openModelViewer === 'function'
    && !!window.KhaytStl && !!window.KhaytStlThumb && !!window.KhaytCalibration, { timeout: 60_000 });

  // Build a real mesh through the parser, mirroring hub:printlib-mesh's flat buffer.
  const meshInfo = await w.evaluate(() => {
    const stl = window.KhaytCalibration._buildModel('tower', 'PLA');
    const enc = new TextEncoder().encode(stl);
    const g = window.KhaytStl.parseStl(enc.buffer, { keepTriangles: true });
    const tris = g.triangles;
    const verts = new Float32Array(tris.length * 9);
    let k = 0, bx0 = 1e9, by0 = 1e9, bz0 = 1e9, bx1 = -1e9, by1 = -1e9, bz1 = -1e9;
    for (const t of tris) for (const p of t) {
      verts[k++] = p[0]; verts[k++] = p[1]; verts[k++] = p[2];
      bx0 = Math.min(bx0, p[0]); bx1 = Math.max(bx1, p[0]);
      by0 = Math.min(by0, p[1]); by1 = Math.max(by1, p[1]);
      bz0 = Math.min(bz0, p[2]); bz1 = Math.max(bz1, p[2]);
    }
    window.__mesh = { verts, count: tris.length, bbox: { x: bx1 - bx0, y: by1 - by0, z: bz1 - bz0 }, name: 'temp-tower.stl' };
    return { count: tris.length, bbox: window.__mesh.bbox };
  });
  assert('parsed a non-trivial mesh', meshInfo.count >= 100);
  assert('bbox is sane (mm)', meshInfo.bbox.x > 5 && meshInfo.bbox.z > 5);

  await w.evaluate(() => window.openModelViewer(window.__mesh));
  await w.waitForSelector('#mvCanvas', { timeout: 8000 });
  await w.waitForTimeout(400);

  // The canvas must contain more than the flat background (mesh actually drawn).
  const sample = async () => w.evaluate(() => {
    const c = document.querySelector('#mvCanvas');
    const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
    let colors = new Set(), sum = 0;
    for (let i = 0; i < d.length; i += 4 * 97) { colors.add(d[i] + ',' + d[i + 1] + ',' + d[i + 2]); sum += d[i] + d[i + 1] + d[i + 2]; }
    return { distinct: colors.size, sum };
  });
  const s1 = await sample();
  assert(`mesh rasterized (${s1.distinct} distinct shades)`, s1.distinct >= 5);

  const shot = path.join(root, 'scratch-model-viewer.png');
  await w.screenshot({ path: shot });
  console.log('  screenshot →', shot);

  // Rotating (drag) must change the rendered image.
  await w.evaluate(() => {
    const c = document.querySelector('#mvCanvas');
    const r = c.getBoundingClientRect();
    const at = (x, y, type) => c.dispatchEvent(new PointerEvent(type, { clientX: x, clientY: y, bubbles: true, pointerId: 1 }));
    at(r.left + r.width / 2, r.top + r.height / 2, 'pointerdown');
    at(r.left + r.width / 2 + 90, r.top + r.height / 2 + 20, 'pointermove');
    at(r.left + r.width / 2 + 90, r.top + r.height / 2 + 20, 'pointerup');
  });
  await w.waitForTimeout(250);
  const s2 = await sample();
  assert('rotate changed the image', s2.sum !== s1.sum);

  // Auto-spin toggles and advances the frame.
  await w.evaluate(() => document.querySelector('#mvSpin').click());
  await w.waitForTimeout(300);
  assert('auto-spin button engaged', await w.evaluate(() => document.querySelector('#mvSpin').classList.contains('on')));
  const s3 = await sample();
  await w.evaluate(() => document.querySelector('#mvSpin').click()); // stop
  assert('auto-spin advanced the frame', s3.sum !== s2.sum);

  await w.evaluate(() => document.querySelector('#mvSpin').classList.contains('on') && document.querySelector('#mvSpin').click());
  await w.waitForTimeout(150);

  // Preset angle buttons change the view.
  assert('has preset view buttons', await w.evaluate(() => document.querySelectorAll('.mv-view').length === 4));
  const sBefore = await sample();
  await w.evaluate(() => document.querySelector('.mv-view[data-view="top"]').click());
  await w.waitForTimeout(200);
  assert('preset "Top" changed the view', (await sample()).sum !== sBefore.sum);

  // Scroll wheel zooms (changes the rendered image).
  const sZoom0 = await sample();
  await w.evaluate(() => {
    const c = document.querySelector('#mvCanvas'); const r = c.getBoundingClientRect();
    c.dispatchEvent(new WheelEvent('wheel', { deltaY: -240, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, bubbles: true, cancelable: true }));
  });
  await w.waitForTimeout(250);
  assert('scroll wheel zoomed', (await sample()).sum !== sZoom0.sum);

  // Reset returns to the iso home view.
  await w.evaluate(() => document.querySelector('#mvReset').click());
  await w.waitForTimeout(200);
  assert('supersampled backing store (2×)', await w.evaluate(() => document.querySelector('#mvCanvas').width >= 900));

  // Wireframe overlay toggles the rendering.
  const sWire0 = await sample();
  await w.evaluate(() => document.querySelector('#mvWire').click());
  await w.waitForTimeout(200);
  assert('wireframe toggle engaged', await w.evaluate(() => document.querySelector('#mvWire').classList.contains('on')));
  assert('wireframe changed the image', (await sample()).sum !== sWire0.sum);

  assert('no renderer errors', errs.length === 0);
  if (errs.length) console.log(errs);
  await app.close();
  console.log('\nOK — 3D model viewer verified.');
}
main().catch((e) => { console.error(e); process.exit(1); });
