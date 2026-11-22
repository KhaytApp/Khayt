#!/usr/bin/env node
/**
 * E2E: the converter's work happens somewhere other than the thread drawing the app.
 *
 * Everything else about this change is covered by node tests, because lib/mf-jobs.js is
 * deliberately Electron-free. The one thing they cannot see is the only thing that
 * actually changed: whether utilityProcess.fork() finds lib/mf-worker.js in a real
 * Electron, whether parentPort messages round-trip, and — the point of the exercise —
 * whether the main thread keeps running while a job is in flight.
 *
 * The measurement is timer ticks. A 10 ms interval in the main process cannot fire while
 * that process is inside zlib, so counting how often it did fire during a convert says
 * directly whether the app could have drawn a frame or answered a click.
 *
 *   npm run test:e2e:3mfworker              CI mode: a built fixture, three runs
 *   node scripts/e2e-3mf-worker.mjs FILE    one real file, through the real handler
 *
 * CI mode runs the same job three ways — through the worker, inline as a control, and
 * through the real hub:mf-convert handler. The inline control is what makes the numbers
 * mean anything: it proves the metric can still detect a blocked thread on this machine,
 * so no threshold has to be guessed at.
 *
 * Given a real file, it converts ONCE, through the real handler. Big files are the reason
 * this exists, and running a 229 MB convert three times over — one of them deliberately on
 * the main thread — costs a great deal of memory to re-prove what the fixture run already
 * established.
 */
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import { launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const require = createRequire(import.meta.url);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const userData = makeUserDataDir();
const fail = (m) => { throw new Error(m); };
const mb = (n) => (n / 1048576).toFixed(1) + ' MB';

const given = process.argv[2] ? path.resolve(process.argv[2]) : null;
if (given && !fs.existsSync(given)) fail(`no such file: ${given}`);

let electronApp;
let builtDir = null;                                    // only removed if WE made it
const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-worker-e2e-'));

/**
 * A 3MF big enough that the job takes real time, small enough to build in a second.
 *
 * Shaped like the real thing: the bulk lives in a 3D/Objects/ part rather than the root
 * model. That is not decoration — the geometry-passthrough assertion below only looks at
 * object meshes, since the root can legitimately be rewritten, so a fixture without one
 * would sail past it proving nothing.
 */
function buildFixture() {
  const { writeZip } = require(path.join(root, 'lib', 'zip-write.js'));
  builtDir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-worker-fx-'));

  const meshXml = (id, tris) => {
    const v = [], t = [];
    for (let i = 0; i < tris; i++) {
      const b = i * 3;
      for (let k = 0; k < 3; k++) v.push(`<vertex x="${i % 97}.5" y="${k}.25" z="${i % 31}.125"/>`);
      t.push(`<triangle v1="${b}" v2="${b + 1}" v3="${b + 2}"/>`);
    }
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
      + '<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">'
      + `<resources><object id="${id}" type="model"><mesh><vertices>${v.join('')}</vertices>`
      + `<triangles>${t.join('')}</triangles></mesh></object></resources>`
      + `<build><item objectid="${id}" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>`;
  };

  const buf = writeZip([
    { name: '[Content_Types].xml', data: Buffer.from('<?xml version="1.0" encoding="UTF-8"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>', 'utf8') },
    { name: 'Metadata/project_settings.config', data: Buffer.from(JSON.stringify({ filament_colour: ['#FF0000', '#00FF00'], printable_area: ['0x0', '256x0', '256x256', '0x256'] }), 'utf8') },
    { name: '3D/3dmodel.model', data: Buffer.from(meshXml(1, 4), 'utf8') },
    { name: '3D/Objects/object_1.model', data: Buffer.from(meshXml(2, 120000), 'utf8') },
  ]);
  const p = path.join(builtDir, 'big.3mf');
  fs.writeFileSync(p, buf);
  return p;
}

const rate = (m) => (m.elapsed ? m.ticks / (m.elapsed / 10) : 0);
const pct = (r) => (r * 100).toFixed(0) + '%';

try {
  const src = given || buildFixture();
  console.log(`source: ${path.basename(src)} — ${mb(fs.statSync(src).size)}`);

  ({ electronApp } = await launchApp(userData));

  // ── CI mode: worker against an inline control, from inside the main process ──
  if (!given) {
    const res = await electronApp.evaluate(async ({ utilityProcess }, a) => {
      const jobArgs = (tmpOut) => ({ src: a.src, maxBytes: 600000000, tmpOut, opts: { targetId: 'generic', mode: 'normalize' } });
      const measure = async (work) => {
        let ticks = 0;
        const timer = setInterval(() => { ticks++; }, 10);
        const startedAt = Date.now();
        const reply = await work();
        clearInterval(timer);
        return { reply, ticks, elapsed: Date.now() - startedAt };
      };

      const viaWorker = await measure(() => {
        const worker = utilityProcess.fork(a.workerPath, [], { serviceName: 'khayt-3mf-e2e', stdio: 'ignore' });
        return new Promise((resolve) => {
          const to = setTimeout(() => resolve({ ok: false, error: 'worker never replied' }), 90000);
          const done = (r) => { clearTimeout(to); try { worker.kill(); } catch (_) {} resolve(r); };
          worker.on('message', (m) => done(m && m.res));
          worker.on('exit', (c) => done({ ok: false, error: 'worker exited ' + c }));
          worker.postMessage({ id: 1, op: 'convert', args: jobArgs(a.outPath) });
        });
      });

      // Playwright's evaluate runs outside module scope, so `require` is not bound here;
      // the main module's own loader is.
      const nodeRequire = (typeof require === 'function') ? require
        : (process.mainModule && process.mainModule.require
          ? process.mainModule.require.bind(process.mainModule) : null);
      if (!nodeRequire) return { viaWorker, inline: { reply: { ok: false, error: 'no require in main process' } } };
      // The control: the identical job on this thread, which is what the app used to do.
      const inline = await measure(() => nodeRequire(a.jobsPath).run('convert', jobArgs(a.inlineOut)));
      return { viaWorker, inline };
    }, {
      src,
      outPath: path.join(workDir, 'worker.3mf'),
      inlineOut: path.join(workDir, 'inline.3mf'),
      workerPath: path.join(root, 'lib', 'mf-worker.js'),
      jobsPath: path.join(root, 'lib', 'mf-jobs.js'),
    });

    const { viaWorker, inline } = res;
    if (!viaWorker.reply || !viaWorker.reply.ok) fail(`the worker could not convert: ${viaWorker.reply && viaWorker.reply.error}`);
    if (!inline.reply || !inline.reply.ok) fail(`the inline control failed, so it proves nothing: ${inline.reply && inline.reply.error}`);
    console.log(`worker: ${viaWorker.ticks} ticks / ${viaWorker.elapsed} ms  (${pct(rate(viaWorker))} of a free thread)`);
    console.log(`inline: ${inline.ticks} ticks / ${inline.elapsed} ms  (${pct(rate(inline))})`);

    if (rate(inline) > 0.5) {
      fail(`the inline control did not block this thread (${pct(rate(inline))}) — the fixture is too small `
        + 'to tell the two apart, so this test cannot prove anything');
    }
    if (rate(viaWorker) < 0.5) {
      fail(`main thread was blocked while the worker converted (${pct(rate(viaWorker))}) — the work is back on the main thread`);
    }
  }

  // ── the real path a maker takes ──────────────────────────────────────────
  // hub:mf-convert routes through the worker client, has the child write to a temp file,
  // and moves that into place. An explicit outPath keeps the save dialog out of it and
  // still exercises the finalize.
  //
  // The destination has to be APPROVED first, through the output-folder picker, exactly
  // as batch conversion does it. This used to work without that because the handler
  // authorised writes with the READ allow-list, which includes temp — the hole that let a
  // renderer write anywhere under Documents/Downloads/Desktop/userData with no dialog.
  //
  // Ticks are counted in the MAIN process across the whole IPC call. This is the assertion
  // that cannot be satisfied by accident: if mfRun ever stops reaching the worker and runs
  // the job here instead, every other check in this file still passes and only this fails.
  const handlerOut = path.join(workDir, 'handler-out.3mf');
  const win0 = await electronApp.firstWindow();
  await electronApp.evaluate(async ({ dialog }, dir) => {
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: [dir] });
  }, workDir);
  const approved = await win0.evaluate(() => window.hubAPI.mfPickOutdir());
  if (!approved || !approved.ok) fail('could not approve the output folder for the batch write');

  await electronApp.evaluate(() => {
    globalThis.__ticks = 0;
    globalThis.__t0 = Date.now();
    globalThis.__timer = setInterval(() => { globalThis.__ticks++; }, 10);
  });
  const win = await electronApp.firstWindow();
  const viaIpc = await win.evaluate(
    ([s, out]) => window.hubAPI.mfConvert({ path: s, targetId: 'generic', mode: 'normalize', outPath: out }),
    [src, handlerOut],
  );
  const ipc = await electronApp.evaluate(() => {
    clearInterval(globalThis.__timer);
    return { ticks: globalThis.__ticks, elapsed: Date.now() - globalThis.__t0 };
  });

  if (!viaIpc || !viaIpc.ok) fail(`hub:mf-convert failed: ${viaIpc && (viaIpc.error || 'canceled')}`);
  if (viaIpc.outPath !== handlerOut) fail(`converted file landed at ${viaIpc.outPath}, not the path asked for`);
  if (!fs.existsSync(handlerOut)) fail('the handler reported success but no file arrived at the destination');
  if (!viaIpc.report) fail('the handler returned no report');

  console.log(`hub:mf-convert: ${ipc.ticks} ticks / ${ipc.elapsed} ms  (${pct(rate(ipc))}) → ${mb(fs.statSync(handlerOut).size)}`);
  if (rate(ipc) < 0.5) {
    fail(`the real hub:mf-convert handler blocked the main thread (${pct(rate(ipc))}) — it is not going through the worker`);
  }

  // The temp file it worked through must not be left behind.
  const strays = fs.readdirSync(os.tmpdir()).filter((f) => f.startsWith('khayt-3mf-'));
  if (strays.length) fail(`the converter left ${strays.length} temp file(s) behind: ${strays.slice(0, 3).join(', ')}`);

  // Geometry came through untouched — checked from the two central directories, which
  // costs no inflation at all. Matching CRC and stored length for every mesh is the
  // passthrough holding across a process boundary, not just in a unit test.
  {
    const { listEntries } = require(path.join(root, 'lib', 'zip-read.js'));
    const byName = (buf) => new Map(listEntries(buf).map((e) => [e.name, e]));
    const before = byName(fs.readFileSync(src));
    const after = byName(fs.readFileSync(handlerOut));
    let checked = 0;
    for (const [name, a] of before) {
      if (!/\.model$/i.test(name)) continue;
      const b = after.get(name);
      if (!b) fail(`${name} is missing from the converted file`);
      // The root model can legitimately be rewritten (plate re-tiling); object meshes cannot.
      if (!/Objects\//i.test(name)) continue;
      if (b.crc !== a.crc || b.compSize !== a.compSize) {
        fail(`${name} was rebuilt instead of copied (crc ${a.crc}→${b.crc}, stored ${a.compSize}→${b.compSize})`);
      }
      checked++;
    }
    if (!checked) fail('no object meshes were checked — this assertion proved nothing');
    console.log(`geometry: ${checked} object mesh(es) carried across byte-for-byte`);
  }

  // The window is still alive and answering afterwards.
  if (!(await win.evaluate(() => document.title))) fail('the window stopped responding');

  console.log('PASS — 3MF work runs off the main thread and the app stays responsive');
} catch (err) {
  console.error('FAIL —', err && err.message ? err.message : err);
  process.exitCode = 1;
} finally {
  try { if (electronApp) await electronApp.close(); } catch (_) {}
  try { fs.rmSync(workDir, { recursive: true, force: true }); } catch (_) {}
  try { if (builtDir) fs.rmSync(builtDir, { recursive: true, force: true }); } catch (_) {}
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}
