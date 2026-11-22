#!/usr/bin/env node
/**
 * Capture README / release screenshots from the Studio UI with demo data.
 * Linux CI: xvfb-run -a npm run capture:screenshots
 *
 * The boot-and-seed sequence lives in screenshot-capture.mjs, shared with the
 * Microsoft Store capture, which needs the same demo data at a different size.
 */
import path from 'path';
import { captureShots, README_VIEWPORT, root } from './screenshot-capture.mjs';

const assetsDir = path.join(root, 'assets');

const written = await captureShots({
  viewport: README_VIEWPORT,
  outDir: assetsDir,
  onShot: (shot) => console.log(`  ${shot.file}`),
});

console.log(`\nScreenshots saved to assets/ (${written.length} files)`);
