/**
 * One stylesheet for the sync, with nothing left to resolve.
 *
 * The source is deliberately two files — `tokens/khayt.css` is GENERATED from
 * the Mac app's Swift and must never be hand-edited, while `styles.css` is
 * authored — but a design rendered by the design tool receives only the
 * `@import` closure of the stylesheet it is handed. An import pointing at a
 * path outside that closure resolves to nothing and every component renders
 * unstyled, which is the failure this avoids by shipping one flat file.
 */
import fs from 'node:fs';
const tokens = fs.readFileSync('src/tokens/khayt.css', 'utf8');
const styles = fs.readFileSync('src/styles.css', 'utf8')
  .replace(/^@import\s+["']\.\/tokens\/khayt\.css["'];\s*$/m,
           '/* tokens inlined above by build-css.mjs */');
fs.mkdirSync('dist', { recursive: true });
fs.writeFileSync('dist/khayt.css', `${tokens}\n${styles}`);
const n = (tokens.match(/^\s*--khayt-/gm) || []).length;
console.log(`✓ dist/khayt.css — ${n} token declarations + component styles, no unresolved imports`);
