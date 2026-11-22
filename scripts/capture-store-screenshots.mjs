#!/usr/bin/env node
/**
 * Capture the Microsoft Store screenshots, at the size the Store wants.
 *
 * The README shots are 1440x940 — fine for a repo page, and they do clear the
 * Store's "1366x768 or larger" floor, but they are not 16:9, so the Store letterboxes
 * them. These are captured at 1920x1080 instead, which is the shape every Store
 * listing layout is designed around.
 *
 * Only the shots named in store/microsoft/listing.json are captured, in that order,
 * because the Store shows at most 10 desktop screenshots and displays them in order.
 *
 * Every file is then checked against the published requirements before it can reach
 * a submission: PNG, at least 1366x768, at most 50 MB. A screenshot that fails
 * certification costs a whole review cycle, and the check costs milliseconds.
 *
 * Linux CI: xvfb-run -a npm run capture:store-screenshots
 */
import fs from 'fs';
import path from 'path';
import { captureShots, SHOTS, root } from './screenshot-capture.mjs';

const STORE_VIEWPORT = { width: 1920, height: 1080 };
const MIN = { width: 1366, height: 768 };
const MAX_BYTES = 50 * 1024 * 1024;

const storeDir = path.join(root, 'store', 'microsoft');
const outDir = path.join(storeDir, 'screenshots');

/** PNG dimensions from the IHDR chunk — no image library needed for 24 bytes. */
function pngSize(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const head = Buffer.alloc(24);
    fs.readSync(fd, head, 0, 24, 0);
    const isPng = head.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    if (!isPng) return null;
    return { width: head.readUInt32BE(16), height: head.readUInt32BE(20) };
  } finally {
    fs.closeSync(fd);
  }
}

const listing = JSON.parse(fs.readFileSync(path.join(storeDir, 'listing.json'), 'utf8'));
const wanted = listing.screenshots.map((s) => s.file);

const unknown = wanted.filter((f) => !SHOTS.some((s) => s.file === f));
if (unknown.length) {
  console.error(`listing.json names screenshots that no shot produces: ${unknown.join(', ')}`);
  console.error(`Known: ${SHOTS.map((s) => s.file).join(', ')}`);
  process.exit(1);
}

// Capture in listing order, so the Store shows them in the order we chose.
const shots = wanted.map((f) => SHOTS.find((s) => s.file === f));

console.log(`Capturing ${shots.length} Store screenshots at ${STORE_VIEWPORT.width}x${STORE_VIEWPORT.height}…`);
fs.rmSync(outDir, { recursive: true, force: true });

const written = await captureShots({
  viewport: STORE_VIEWPORT,
  outDir,
  shots,
  onShot: (shot) => console.log(`  ${shot.file}`),
});

console.log('\nChecking against Microsoft Store requirements…');
const problems = [];
for (const file of written) {
  const name = path.basename(file);
  const bytes = fs.statSync(file).size;
  const size = pngSize(file);
  if (!size) { problems.push(`${name}: not a PNG`); continue; }
  if (size.width < MIN.width || size.height < MIN.height) {
    problems.push(`${name}: ${size.width}x${size.height} is below the ${MIN.width}x${MIN.height} minimum`);
  }
  if (bytes > MAX_BYTES) {
    problems.push(`${name}: ${(bytes / 1024 / 1024).toFixed(1)} MB exceeds the 50 MB limit`);
  }
  console.log(`  ok  ${name.padEnd(34)} ${size.width}x${size.height}  ${(bytes / 1024).toFixed(0)} KB`);
}

if (problems.length) {
  console.error(`\n${problems.length} screenshot(s) would fail certification:`);
  for (const p of problems) console.error(`  ✖ ${p}`);
  process.exit(1);
}

console.log(`\n${written.length} Store screenshots in ${path.relative(root, outDir)}`);
