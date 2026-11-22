#!/usr/bin/env node
/** Copy latin/arabic UI subsets from @fontsource packages into renderer/fonts/. */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'renderer/fonts');

const copies = [
  ['@fontsource/archivo/files/archivo-latin-400-normal.woff2', 'archivo-latin-400.woff2'],
  ['@fontsource/archivo/files/archivo-latin-600-normal.woff2', 'archivo-latin-600.woff2'],
  ['@fontsource/archivo/files/archivo-latin-700-normal.woff2', 'archivo-latin-700.woff2'],
  ['@fontsource/hanken-grotesk/files/hanken-grotesk-latin-400-normal.woff2', 'hanken-grotesk-latin-400.woff2'],
  ['@fontsource/hanken-grotesk/files/hanken-grotesk-latin-500-normal.woff2', 'hanken-grotesk-latin-500.woff2'],
  ['@fontsource/hanken-grotesk/files/hanken-grotesk-latin-600-normal.woff2', 'hanken-grotesk-latin-600.woff2'],
  ['@fontsource/hanken-grotesk/files/hanken-grotesk-latin-700-normal.woff2', 'hanken-grotesk-latin-700.woff2'],
  ['@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-400-normal.woff2', 'ibm-plex-mono-latin-400.woff2'],
  ['@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-500-normal.woff2', 'ibm-plex-mono-latin-500.woff2'],
  ['@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-600-normal.woff2', 'ibm-plex-mono-latin-600.woff2'],
  ['@fontsource/ibm-plex-sans/files/ibm-plex-sans-latin-400-normal.woff2', 'ibm-plex-sans-latin-400.woff2'],
  ['@fontsource/ibm-plex-sans/files/ibm-plex-sans-latin-500-normal.woff2', 'ibm-plex-sans-latin-500.woff2'],
  ['@fontsource/ibm-plex-sans/files/ibm-plex-sans-latin-600-normal.woff2', 'ibm-plex-sans-latin-600.woff2'],
  ['@fontsource/ibm-plex-sans/files/ibm-plex-sans-latin-700-normal.woff2', 'ibm-plex-sans-latin-700.woff2'],
  ['@fontsource/jetbrains-mono/files/jetbrains-mono-latin-400-normal.woff2', 'jetbrains-mono-latin-400.woff2'],
  ['@fontsource/jetbrains-mono/files/jetbrains-mono-latin-500-normal.woff2', 'jetbrains-mono-latin-500.woff2'],
  ['@fontsource/jetbrains-mono/files/jetbrains-mono-latin-600-normal.woff2', 'jetbrains-mono-latin-600.woff2'],
  ['@fontsource/jetbrains-mono/files/jetbrains-mono-latin-700-normal.woff2', 'jetbrains-mono-latin-700.woff2'],
  ['@fontsource/albert-sans/files/albert-sans-latin-400-normal.woff2', 'albert-sans-latin-400.woff2'],
  ['@fontsource/albert-sans/files/albert-sans-latin-500-normal.woff2', 'albert-sans-latin-500.woff2'],
  ['@fontsource/albert-sans/files/albert-sans-latin-600-normal.woff2', 'albert-sans-latin-600.woff2'],
  ['@fontsource/albert-sans/files/albert-sans-latin-700-normal.woff2', 'albert-sans-latin-700.woff2'],
  ['@fontsource/newsreader/files/newsreader-latin-400-normal.woff2', 'newsreader-latin-400.woff2'],
  ['@fontsource/newsreader/files/newsreader-latin-500-normal.woff2', 'newsreader-latin-500.woff2'],
  ['@fontsource/newsreader/files/newsreader-latin-600-normal.woff2', 'newsreader-latin-600.woff2'],
  ['@fontsource/outfit/files/outfit-latin-400-normal.woff2', 'outfit-latin-400.woff2'],
  ['@fontsource/outfit/files/outfit-latin-500-normal.woff2', 'outfit-latin-500.woff2'],
  ['@fontsource/outfit/files/outfit-latin-600-normal.woff2', 'outfit-latin-600.woff2'],
  ['@fontsource/outfit/files/outfit-latin-700-normal.woff2', 'outfit-latin-700.woff2'],
  ['@fontsource/bricolage-grotesque/files/bricolage-grotesque-latin-400-normal.woff2', 'bricolage-grotesque-latin-400.woff2'],
  ['@fontsource/bricolage-grotesque/files/bricolage-grotesque-latin-600-normal.woff2', 'bricolage-grotesque-latin-600.woff2'],
  ['@fontsource/bricolage-grotesque/files/bricolage-grotesque-latin-700-normal.woff2', 'bricolage-grotesque-latin-700.woff2'],
  ['@fontsource/plus-jakarta-sans/files/plus-jakarta-sans-latin-400-normal.woff2', 'plus-jakarta-sans-latin-400.woff2'],
  ['@fontsource/plus-jakarta-sans/files/plus-jakarta-sans-latin-500-normal.woff2', 'plus-jakarta-sans-latin-500.woff2'],
  ['@fontsource/plus-jakarta-sans/files/plus-jakarta-sans-latin-600-normal.woff2', 'plus-jakarta-sans-latin-600.woff2'],
  ['@fontsource/plus-jakarta-sans/files/plus-jakarta-sans-latin-700-normal.woff2', 'plus-jakarta-sans-latin-700.woff2'],
  ['@fontsource/space-grotesk/files/space-grotesk-latin-400-normal.woff2', 'space-grotesk-latin-400.woff2'],
  ['@fontsource/space-grotesk/files/space-grotesk-latin-500-normal.woff2', 'space-grotesk-latin-500.woff2'],
  ['@fontsource/space-grotesk/files/space-grotesk-latin-600-normal.woff2', 'space-grotesk-latin-600.woff2'],
  ['@fontsource/space-grotesk/files/space-grotesk-latin-700-normal.woff2', 'space-grotesk-latin-700.woff2'],
  ['@fontsource/spline-sans-mono/files/spline-sans-mono-latin-400-normal.woff2', 'spline-sans-mono-latin-400.woff2'],
  ['@fontsource/spline-sans-mono/files/spline-sans-mono-latin-500-normal.woff2', 'spline-sans-mono-latin-500.woff2'],
  ['@fontsource/spline-sans-mono/files/spline-sans-mono-latin-600-normal.woff2', 'spline-sans-mono-latin-600.woff2'],
  ['@fontsource/ibm-plex-sans-arabic/files/ibm-plex-sans-arabic-arabic-400-normal.woff2', 'ibm-plex-sans-arabic-arabic-400.woff2'],
  ['@fontsource/ibm-plex-sans-arabic/files/ibm-plex-sans-arabic-arabic-600-normal.woff2', 'ibm-plex-sans-arabic-arabic-600.woff2'],
  ['@fontsource/ibm-plex-sans-arabic/files/ibm-plex-sans-arabic-arabic-700-normal.woff2', 'ibm-plex-sans-arabic-arabic-700.woff2'],
];

fs.mkdirSync(out, { recursive: true });
let n = 0;
for (const [src, dest] of copies) {
  const from = path.join(root, 'node_modules', src);
  if (!fs.existsSync(from)) {
    console.warn('skip missing', src);
    continue;
  }
  fs.copyFileSync(from, path.join(out, dest));
  n++;
}
console.log(`Vendored ${n} font files to renderer/fonts/`);
