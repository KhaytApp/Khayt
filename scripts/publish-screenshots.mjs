#!/usr/bin/env node
/**
 * Upload assets/screenshot-*.png to a GitHub Release.
 * Usage: node scripts/publish-screenshots.mjs [v2.2.0]
 */
import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const assetsDir = path.join(root, 'assets');
const tag = process.argv[2] || 'v2.2.0';

const files = fs.readdirSync(assetsDir)
  .filter((f) => /^screenshot-\d+-.+\.png$/.test(f))
  .sort((a, b) => {
    const na = +(/^screenshot-(\d+)/.exec(a)?.[1] || 0);
    const nb = +(/^screenshot-(\d+)/.exec(b)?.[1] || 0);
    return na - nb;
  });

if (files.length === 0) {
  console.error('No screenshot-*.png files in assets/');
  process.exit(1);
}

const paths = files.map((f) => path.join('assets', f));
console.log(`Uploading ${paths.length} screenshots to release ${tag}…`);
execSync(`gh release upload ${tag} ${paths.join(' ')} --clobber`, { cwd: root, stdio: 'inherit' });
console.log(`Done: https://github.com/khaytapp/Khayt/releases/tag/${tag}`);
