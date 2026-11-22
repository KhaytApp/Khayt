#!/usr/bin/env node
'use strict';
// One-off i18n audit: coverage (keys used in code present in en) + parity (all locales vs en).
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const localesDir = path.join(root, 'renderer/locales');
const langs = ['en', 'ar', 'de', 'es', 'fr', 'ja', 'zh'];

// --- load locale dictionaries ---
const sandbox = {};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
for (const lang of langs) {
  vm.runInContext(fs.readFileSync(path.join(localesDir, `${lang}.js`), 'utf8'), sandbox, { filename: `${lang}.js` });
}
const L = sandbox.KhaytLocales;
const keysOf = (lang) => new Set(Object.keys(L[lang] || {}));
const enKeys = keysOf('en');

// --- collect keys USED in code ---
const usedStatic = new Set();
const dynamicHits = [];
function walk(dir) {
  for (const name of fs.readdirSync(dir)) {
    if (name === 'node_modules' || name === 'locales' || name.startsWith('.')) continue;
    const p = path.join(dir, name);
    const st = fs.statSync(p);
    if (st.isDirectory()) walk(p);
    else if (/\.(js|html)$/.test(name)) scan(p, fs.readFileSync(p, 'utf8'));
  }
}
function scan(file, src) {
  // t('key') / t("key")  — only the i18n function, not createElement(...) etc.
  for (const m of src.matchAll(/\bt\(\s*(['"])([^'"]+)\1/g)) {
    const k = m[2];
    if (/^[a-z][\w]*(\.[\w]+)+$/.test(k)) usedStatic.add(k); // dotted key shape
  }
  // data-i18n / -placeholder / -title / -html = "key"
  for (const m of src.matchAll(/data-i18n(?:-placeholder|-title|-html)?\s*=\s*(['"])([^'"]+)\1/g)) {
    usedStatic.add(m[2]);
  }
  // dynamic t(`...${...}`) — flag separately
  for (const m of src.matchAll(/\bt\(\s*`[^`]*\$\{[^`]*`/g)) dynamicHits.push(`${path.relative(root, file)}: ${m[0].slice(0, 60)}`);
}
walk(path.join(root, 'renderer'));

// --- report ---
const usedMissingInEn = [...usedStatic]
  .filter((k) => !enKeys.has(k))
  .filter((k) => !k.endsWith('_'))           // drop dynamic prefixes: t('x_' + var)
  .sort();
console.log(`\n=== Locale sizes ===`);
for (const lang of langs) console.log(`  ${lang}: ${keysOf(lang).size}`);

console.log(`\n=== Static i18n keys used in code: ${usedStatic.size} ===`);
console.log(`=== USED IN CODE BUT MISSING FROM en.js (raw-key leaks): ${usedMissingInEn.length} ===`);
for (const k of usedMissingInEn) console.log(`  ✗ ${k}`);

console.log(`\n=== Parity vs en (keys in en missing from each locale) ===`);
for (const lang of langs.filter((l) => l !== 'en')) {
  const miss = [...enKeys].filter((k) => !keysOf(lang).has(k));
  console.log(`  ${lang}: missing ${miss.length}`);
}

console.log(`\n=== Orphan keys (in a locale but NOT in en) ===`);
for (const lang of langs.filter((l) => l !== 'en')) {
  const orphan = [...keysOf(lang)].filter((k) => !enKeys.has(k));
  if (orphan.length) console.log(`  ${lang}: ${orphan.length} -> ${orphan.slice(0, 8).join(', ')}${orphan.length > 8 ? ' …' : ''}`);
}

console.log(`\n=== Dynamic t(\`...\`) call sites (cannot static-check): ${dynamicHits.length} ===`);
for (const h of [...new Set(dynamicHits)].slice(0, 20)) console.log(`  ~ ${h}`);

// Pass a locale list to dump that locale's full missing-key list, e.g. `node scripts/i18n-audit.cjs ar`.
for (const lang of process.argv.slice(2)) {
  if (!langs.includes(lang) || lang === 'en') continue;
  const miss = [...enKeys].filter((k) => !keysOf(lang).has(k)).sort();
  console.log(`\n=== ${lang}: ${miss.length} keys present in en but missing ===`);
  for (const k of miss) console.log(`  ${k}`);
}

// Raw-key leaks are real bugs — fail so this can guard against regressions.
if (usedMissingInEn.length) {
  console.error(`\nFAIL: ${usedMissingInEn.length} i18n key(s) used in code are missing from en.js.`);
  process.exit(1);
}
