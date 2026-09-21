#!/usr/bin/env node
/**
 * Khayt's design tokens, read out of the Mac app's own source.
 *
 * ── WHY THIS IS A SCRIPT AND NOT A HAND-WRITTEN STYLESHEET ─────────────────
 *
 * The Mac app IS the design system: `Palette.swift` holds every colour as a
 * light/dark pair with its contrast measured against the surface it sits on,
 * `TypeScale.swift` holds the four steps and their tracking, and `Surface.swift`
 * holds the one card geometry the whole app is built from. Those files are
 * reviewed, tested (`DesignSpecTests.swift`) and argued over in their own
 * comments.
 *
 * A stylesheet typed out by hand from them is a second opinion that starts
 * correct and drifts the first time somebody re-measures a colour. So the
 * values are READ, every one of them, and a value this script cannot find is a
 * hard failure rather than a default — a silently-substituted colour is exactly
 * the drift this exists to prevent.
 *
 * Run: node .design-sync/extract-tokens.mjs
 * Writes: design-system/src/tokens/khayt.css
 */
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');
const APP = path.join(ROOT, 'mac/KhaytCore/Sources/KhaytApp');
const OUT = path.join(ROOT, 'design-system/src/tokens/khayt.css');

const read = (f) => fs.readFileSync(path.join(APP, f), 'utf8');

/** Every `adaptive(light: 0xRRGGBB, dark: 0xRRGGBB, name:)` in a file. */
function adaptives(text) {
  const out = {};
  const rx = /static let (\w+)\s*=\s*adaptive\(light:\s*0x([0-9A-Fa-f]{6}),\s*dark:\s*0x([0-9A-Fa-f]{6})/g;
  for (const m of text.matchAll(rx)) {
    out[m[1]] = { light: `#${m[2].toLowerCase()}`, dark: `#${m[3].toLowerCase()}` };
  }
  return out;
}

const palette = { ...adaptives(read('Palette.swift')), ...adaptives(read('Surface.swift')) };

/**
 * The colours this design system is not complete without.
 *
 * Named rather than inferred: a rename in Palette.swift should stop this script
 * dead, not quietly ship a token list that is missing a colour nobody noticed.
 */
const NEEDED = ['brand', 'onBrand', 'hot', 'done', 'attention', 'late', 'note',
                'marked', 'surface', 'ground', 'hairline'];
const missing = NEEDED.filter((k) => !palette[k]);
if (missing.length) {
  console.error(`✗ not found in Palette.swift / Surface.swift: ${missing.join(', ')}`);
  console.error('  A colour that moved is a token that would silently go stale. Fix the name here.');
  process.exit(1);
}

/** The card, read out of the one modifier the whole app draws through.
 *
 * Scoped to `KhaytCard`'s own body, and with comment lines stripped first. Both
 * matter: Surface.swift's header comment shows a `cornerRadius: 8` example of
 * what NOT to do, and a `recessed` surface further down uses 12. A whole-file
 * search takes the first of those and ships a card that is the wrong shape —
 * which it did, silently, until the generated token was read back. */
const surfaceRaw = read('Surface.swift');
const cardStart = surfaceRaw.indexOf('private struct KhaytCard');
if (cardStart === -1) {
  console.error('✗ KhaytCard is no longer in Surface.swift — the card moved.');
  process.exit(1);
}
const surface = surfaceRaw
  .slice(cardStart)
  .split('\n')
  .filter((l) => !l.trim().startsWith('//'))
  .join('\n');
const radius = surface.match(/RoundedRectangle\(cornerRadius:\s*(\d+)/)?.[1];
const railWidth = surface.match(/Rectangle\(\)\.fill\(rail\)\.frame\(width:\s*(\d+)\)/)?.[1];
// The padding DEFAULT lives on the `card(...)` signature, which sits in the
// `extension View` above KhaytCard and so is outside the scoped body. Read from
// that signature by name — a bare `padding: CGFloat =` search finds whichever
// other view declares one first (it found a 10, and the card's is 12).
const cardPad = surfaceRaw
  .split('\n')
  .filter((l) => !l.trim().startsWith('//'))
  .join('\n')
  .match(/func card\(rail: Color\? = nil, padding: CGFloat = (\d+)/)?.[1];
const railPad = surface.match(/\.padding\(\.leading,\s*rail == nil \? 0 : (\d+)\)/)?.[1];
if (!radius || !railWidth || !cardPad || !railPad) {
  console.error('✗ the card geometry moved in Surface.swift:',
                JSON.stringify({ radius, railWidth, cardPad, railPad }));
  process.exit(1);
}

/** The type steps, with their default size, weight and tracking in ems. */
const type = read('TypeScale.swift');
const step = (name) => {
  const m = type.match(new RegExp(`static func ${name}\\(_ size: CGFloat = ([\\d.]+),\\s*weight: Font\\.Weight\\??\\s*=\\s*\\.(\\w+)`));
  return m ? { size: m[1], weight: m[2] || null } : null;
};
const steps = { display: step('display'), title: step('title'), row: step('row'), body: step('body') };
const label = type.match(/static func label\(_ size: CGFloat = ([\d.]+)/)?.[1];
if (!steps.display || !steps.title || !steps.row || !steps.body || !label) {
  console.error('✗ the type scale moved in TypeScale.swift:', JSON.stringify({ ...steps, label }));
  process.exit(1);
}
// Tracking is written in ems in the Swift, as the spec writes it.
const trackDisplay = type.match(/case \(\.display, true\):\s*em = (-?[\d.]+)/)?.[1];
const trackLabel = type.match(/case \(\.label, true\):\s*em = (-?[\d.]+)/)?.[1];
const family = type.match(/static let brandFamily = "([^"]+)"/)?.[1];
if (!trackDisplay || !trackLabel || !family) {
  console.error('✗ tracking or the brand family moved in TypeScale.swift');
  process.exit(1);
}

/**
 * How the app MOVES, from Motion.swift.
 *
 * Read for the same reason the colours are: `Motion.swift` argues its four
 * durations out in its own comments ("quicker than a person can notice",
 * "stands for hours of work"), and a stylesheet that guesses at them is a
 * second opinion that drifts. A design built in the wrong timing is off-brand
 * in a way nobody can point at.
 *
 * The two named behaviours come with it, because they are the vocabulary:
 * `Alive` is the slow breath reserved for the one thing happening right now,
 * and `Lift` is the whole of "this is yours to press".
 */
const motionRaw = read('Motion.swift');
const motionBody = motionRaw
  .split('\n')
  .filter((l) => !l.trim().startsWith('///') && !l.trim().startsWith('//'))
  .join('\n');

/** SwiftUI curve names to their CSS equivalents. */
const CURVE = { easeOut: 'ease-out', easeInOut: 'ease-in-out', easeIn: 'ease-in', linear: 'linear' };

const motion = {};
for (const m of motionBody.matchAll(
  /static let (\w+)\s*=\s*Animation\.(easeOut|easeInOut|easeIn|linear)\(duration:\s*([\d.]+)\)/g)) {
  motion[m[1]] = { curve: CURVE[m[2]], seconds: m[3] };
}

/* NAMED, not inferred — the same rule the colours follow. A duration that is
 * renamed should stop this script dead rather than quietly ship a motion set
 * with one timing missing, which is the kind of gap nobody sees in a diff. */
const MOTION_NEEDED = ['figure', 'gauge', 'progress', 'hover'];
const motionMissing = MOTION_NEEDED.filter((k) => !motion[k]);
if (motionMissing.length) {
  console.error(`✗ not found in Motion.swift: ${motionMissing.join(', ')}`);
  console.error('  A duration that moved is motion that would silently go stale.');
  process.exit(1);
}

// The breath, and how far it dims. Both live inside `Alive`, not on `Motion`.
const aliveSeconds = motionBody.match(/\.easeInOut\(duration:\s*([\d.]+)\)\.repeatForever/)?.[1];
const aliveDim = motionBody.match(/\.opacity\(active && breathed && !reduced \? ([\d.]+)/)?.[1];
// The lift, as a PERCENT in the Swift (`1 + amount / 100`).
const liftPercent = motionBody.match(/by amount: CGFloat = ([\d.]+)/)?.[1];
if (!aliveSeconds || !aliveDim || !liftPercent) {
  console.error('✗ Alive or Lift moved in Motion.swift:',
                JSON.stringify({ aliveSeconds, aliveDim, liftPercent }));
  process.exit(1);
}

const ms = (seconds) => `${Math.round(parseFloat(seconds) * 1000)}ms`;

/** SwiftUI weight names to CSS numbers. */
const WEIGHT = { regular: 400, medium: 500, semibold: 600, bold: 700, heavy: 800 };
const w = (name) => WEIGHT[name] ?? 400;

const px = (pt) => `${pt}px`;   // 1pt == 1 CSS px at the scale these are authored at

const lines = [];
lines.push('/* GENERATED by .design-sync/extract-tokens.mjs — do not edit.');
lines.push(' *');
lines.push(' * Every value below is read out of the Mac app\'s own source:');
lines.push(' *   colours  — Palette.swift, Surface.swift (adaptive light/dark pairs)');
lines.push(' *   card     — Surface.swift (the one KhaytCard modifier)');
lines.push(' *   type     — TypeScale.swift (four steps, tracking in ems)');
lines.push(' *');
lines.push(' * Re-run the extractor after any change to those files.');
lines.push(' */');
lines.push('');
lines.push(':root {');
lines.push('  /* Semantic colour. Each is a sentence in Palette.swift — read it there');
lines.push('     before reaching for one: `attention` means "wants a person", `late`');
lines.push('     means "late, failed, refused". They are not a rainbow to pick from. */');
for (const k of NEEDED) {
  lines.push(`  --khayt-${kebab(k)}: ${palette[k].light};`);
}
lines.push('');
lines.push('  /* The card, from the one modifier the whole app draws through. */');
lines.push(`  --khayt-radius: ${px(radius)};`);
lines.push(`  --khayt-card-padding: ${px(cardPad)};`);
lines.push(`  --khayt-rail-width: ${px(railWidth)};`);
lines.push(`  --khayt-rail-inset: ${px(railPad)};`);
lines.push(`  --khayt-hairline-width: 1px;`);
lines.push('');
lines.push('  /* Type. The brand family is bundled with the app; the fallback is what');
lines.push('     TypeScale falls back to when it is not installed. */');
lines.push(`  --khayt-font-brand: "${family}", ui-sans-serif, system-ui, sans-serif;`);
lines.push('  --khayt-font-system: ui-sans-serif, system-ui, -apple-system, sans-serif;');
lines.push(`  --khayt-size-display: ${px(steps.display.size)};`);
lines.push(`  --khayt-size-title: ${px(steps.title.size)};`);
lines.push(`  --khayt-size-row: ${px(steps.row.size)};`);
lines.push(`  --khayt-size-body: ${px(steps.body.size)};`);
lines.push(`  --khayt-size-label: ${px(label)};`);
lines.push(`  --khayt-weight-display: ${w(steps.display.weight)};`);
lines.push(`  --khayt-weight-title: ${w(steps.title.weight)};`);
lines.push(`  --khayt-weight-row: ${w(steps.row.weight)};`);
lines.push(`  --khayt-weight-body: ${w(steps.body.weight)};`);
lines.push('  --khayt-weight-label: 700;');
lines.push(`  --khayt-track-display: ${trackDisplay}em;`);
lines.push(`  --khayt-track-label: ${trackLabel}em;`);
lines.push('');
lines.push('  /* Motion, from Motion.swift. Each duration is argued for in that file —');
lines.push('     read it before reaching for one. `hover` is "quicker than a person can');
lines.push('     notice"; `progress` is slow BECAUSE it stands for hours of work, and a');
lines.push('     snappy one would misrepresent it. */');
for (const k of MOTION_NEEDED) {
  lines.push(`  --khayt-motion-${k}: ${ms(motion[k].seconds)};`);
  lines.push(`  --khayt-ease-${k}: ${motion[k].curve};`);
}
lines.push('');
lines.push('  /* The two named behaviours. `alive` is the slow breath reserved for the');
lines.push('     one thing happening right now — the amber dot on a running print, and');
lines.push('     NOTHING else. `lift` is the whole vocabulary for "this is yours to');
lines.push('     press". Neither is decoration: see the head of Motion.swift. */');
lines.push(`  --khayt-motion-alive: ${ms(aliveSeconds)};`);
lines.push(`  --khayt-alive-dim: ${aliveDim};`);
lines.push(`  --khayt-lift: ${1 + parseFloat(liftPercent) / 100};`);
lines.push('}');
lines.push('');
lines.push('/* Dark. Only the colours change — the geometry and the type scale are one');
lines.push('   set of numbers in the Mac app and stay one set here. */');
lines.push('[data-theme="dark"] {');
for (const k of NEEDED) {
  lines.push(`  --khayt-${kebab(k)}: ${palette[k].dark};`);
}
lines.push('}');
lines.push('');
lines.push('/* REDUCE MOTION TAKES EVERYTHING TO ZERO, and that is not a nicety.');
lines.push('   Motion.swift: "this app is for a workshop, motion sensitivity is common,');
lines.push('   and a pulsing dot on a screen somebody has to look at all day is the exact');
lines.push('   thing the setting exists for." `Motion.of` returns no animation at all and');
lines.push('   the breath STOPS rather than slowing, so the tokens do the same. */');
lines.push('@media (prefers-reduced-motion: reduce) {');
lines.push('  :root {');
for (const k of MOTION_NEEDED) {
  lines.push(`    --khayt-motion-${k}: 0ms;`);
}
lines.push('    --khayt-motion-alive: 0ms;');
lines.push('    /* Full opacity, not a dimmed resting state: a dot left at 45% on a');
lines.push('       machine that has finished reads as a fault. */');
lines.push('    --khayt-alive-dim: 1;');
lines.push('    --khayt-lift: 1;');
lines.push('  }');
lines.push('}');
lines.push('');
lines.push('@media (prefers-color-scheme: dark) {');
lines.push('  :root:not([data-theme="light"]) {');
for (const k of NEEDED) {
  lines.push(`    --khayt-${kebab(k)}: ${palette[k].dark};`);
}
lines.push('  }');
lines.push('}');
lines.push('');

function kebab(s) { return s.replace(/([a-z])([A-Z])/g, '$1-$2').toLowerCase(); }

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, lines.join('\n'));
console.log(`✓ ${NEEDED.length} colours, ${Object.keys(steps).length + 1} type steps, 5 card values, `
            + `${MOTION_NEEDED.length} durations + alive/lift`);
console.log(`  → ${path.relative(ROOT, OUT)}`);
