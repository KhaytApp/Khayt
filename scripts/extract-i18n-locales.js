#!/usr/bin/env node
'use strict';
/**
 * One-time / maintenance: extract STRINGS from monolithic renderer/i18n.js
 * into renderer/locales/<lang>.js. Run before replacing i18n.js with the loader.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const srcPath = path.join(root, 'renderer/i18n.js');
const src = fs.readFileSync(srcPath, 'utf8');
const i18nIdx = src.indexOf('const i18n =');
if (i18nIdx < 0) throw new Error('const i18n = not found — already split?');

const stringsStart = src.indexOf('const STRINGS = ') + 'const STRINGS = '.length;
let stringsSrc = src.slice(stringsStart, i18nIdx).trim();
if (stringsSrc.endsWith(';')) stringsSrc = stringsSrc.slice(0, -1).trim();

const STRINGS = vm.runInNewContext(`(${stringsSrc})`, {}, { timeout: 30_000 });
const langs = ['en', 'ar', 'de', 'es', 'fr', 'zh', 'ja'];
const outDir = path.join(root, 'renderer/locales');
fs.mkdirSync(outDir, { recursive: true });

for (const lang of langs) {
  if (!STRINGS[lang]) throw new Error(`missing language block: ${lang}`);
  const payload = JSON.stringify(STRINGS[lang], null, 2);
  const file = [
    `/* Khayt UI strings (${lang}). Regenerate: npm run i18n:extract */`,
    '(function (root) {',
    '  var g = root;',
    '  g.KhaytLocales = g.KhaytLocales || {};',
    `  g.KhaytLocales.${lang} = ${payload};`,
    "})(typeof globalThis !== 'undefined' ? globalThis : window);",
    '',
  ].join('\n');
  fs.writeFileSync(path.join(outDir, `${lang}.js`), file);
  console.log('wrote', lang, Object.keys(STRINGS[lang]).length, 'keys');
}
