const { test } = require('node:test');
const assert = require('node:assert/strict');

test('KhaytAppBoot exports initWizard', () => {
  const boot = require('../renderer/app-boot.js');
  assert.equal(typeof boot.initWizard, 'function');
});

/**
 * `global` does not exist in the Electron renderer (nodeIntegration is off) —
 * only `globalThis` and `window` do. The renderer modules are plain scripts, so
 * a bare `global.X` is a ReferenceError at the moment that line runs, not at
 * load, which is why it can sit in a rarely-run branch undetected.
 *
 * Optional chaining does NOT save it: `global.Foo?.bar?.()` still throws,
 * because resolving the identifier `global` happens before `?.` is applied.
 * That is exactly how the setup wizard broke — goToStep(2) threw before it
 * could mount the theme picker, and the step-2 Continue handler threw before
 * reaching goToStep(3), so every new shop was trapped on "Choose your look"
 * with an empty picker and a dead button. finishWizard() threw too, so even
 * skipping out did not work.
 *
 * `global` is legitimate as an IIFE PARAMETER — `(function (global) { ... })
 * (globalThis)` — which is the export idiom used across renderer/. This guard
 * flags only uses outside such a block.
 */
test('no renderer module uses a bare `global.` outside a (function (global)) IIFE', () => {
  const fs = require('fs');
  const path = require('path');
  const ROOT = path.join(__dirname, '..', 'renderer');

  const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(path.join(d, e.name)) : (e.name.endsWith('.js') ? [path.join(d, e.name)] : []));

  const bad = [];
  for (const file of walk(ROOT)) {
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    let inIife = false;
    let brace = 0;
    lines.forEach((line, i) => {
      const opens = /\(function\s*\(\s*global\s*\)/.test(line);
      if (opens) { inIife = true; brace = 0; }
      if (inIife) {
        brace += (line.match(/{/g) || []).length - (line.match(/}/g) || []).length;
        if (brace <= 0 && !opens) inIife = false;
      }
      if (inIife) return;
      // Ignore comments — app-state.js documents the IIFE idiom in prose.
      const code = line.replace(/\/\/.*$/, '');
      if (/^\s*[*/]/.test(line)) return;
      if (/\bglobal\./.test(code)) {
        bad.push(`${path.relative(ROOT, file)}:${i + 1}  ${line.trim().slice(0, 90)}`);
      }
    });
  }
  assert.deepEqual(bad, [], `\`global.\` is undefined in the renderer — use globalThis:\n  ${bad.join('\n  ')}`);
});
