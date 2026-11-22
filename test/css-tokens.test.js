const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

/**
 * A `var(--x)` with no fallback that resolves to nothing is not an error — CSS
 * just drops the declaration. The result is INVISIBLE, which is the worst
 * failure mode for a design system that reserves colour for conditions:
 *
 *   kanban.js styled an OVERDUE due-pill with var(--danger-soft) and the
 *   "Unassigned" pill with var(--warn)/var(--warn-soft). All three were defined
 *   only in the Bed Ready stylesheets, so in every Khayt theme the urgent state
 *   rendered with no fill while the calm state kept its --surface-2 — the alarm
 *   was quieter than the normal case. Nobody noticed because nothing broke.
 *
 * The same audit then found --grid, --l1, --l5 and --gap in the same position,
 * plus --bg-alt and --bg-soft which were defined nowhere at all.
 *
 * So: every no-fallback custom property referenced by SHARED renderer code must
 * be defined somewhere every flavor loads. Bed Ready-only definitions do not
 * count — that is exactly the bug.
 */

/** Files loaded by both Khayt and Bed Ready. Flavor-specific files are excluded. */
function sharedSources() {
  const out = [];
  for (const entry of fs.readdirSync(path.join(ROOT, 'renderer'))) {
    if (!/\.(js|css)$/.test(entry)) continue;
    if (entry.startsWith('bedready')) continue;   // Bed Ready-only, may use its own tokens
    out.push(path.join('renderer', entry));
  }
  return out;
}

/** Everywhere a custom property is DEFINED, across base + theme stylesheets. */
function definedTokens() {
  const defined = new Set();
  const addFrom = (rel) => {
    const abs = path.join(ROOT, rel);
    if (!fs.existsSync(abs)) return;
    for (const m of fs.readFileSync(abs, 'utf8').matchAll(/^\s*(--[a-z0-9-]+)\s*:/gm)) defined.add(m[1]);
  };
  addFrom('renderer/styles.css');
  const themes = path.join(ROOT, 'renderer/themes');
  for (const t of fs.readdirSync(themes)) {
    const dir = path.join(themes, t);
    if (!fs.statSync(dir).isDirectory()) continue;
    for (const f of fs.readdirSync(dir)) if (f.endsWith('.css')) addFrom(path.join('renderer/themes', t, f));
  }
  return defined;
}

/** Properties set at runtime (inline styles, setProperty) are legitimately absent from CSS. */
function inlineTokens() {
  const set = new Set();
  const scan = (rel) => {
    const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    for (const m of src.matchAll(/setProperty\(\s*['"](--[a-z0-9-]+)/g)) set.add(m[1]);
    for (const m of src.matchAll(/(--[a-z0-9-]+)\s*:/g)) set.add(m[1]);
  };
  for (const rel of sharedSources()) scan(rel);
  const themes = path.join(ROOT, 'renderer/themes');
  for (const t of fs.readdirSync(themes)) {
    const dir = path.join(themes, t);
    if (!fs.statSync(dir).isDirectory()) continue;
    for (const f of fs.readdirSync(dir)) if (f.endsWith('.js')) scan(path.join('renderer/themes', t, f));
  }
  return set;
}

test('every no-fallback var() in shared code resolves somewhere', () => {
  const defined = definedTokens();
  const inline = inlineTokens();
  const unresolved = [];
  for (const rel of sharedSources()) {
    const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    src.split('\n').forEach((line, i) => {
      // `var(--x)` with no comma — a fallback makes it safe by construction.
      for (const m of line.matchAll(/var\(\s*(--[a-z0-9-]+)\s*\)/g)) {
        const tok = m[1];
        if (!defined.has(tok) && !inline.has(tok)) unresolved.push(`${rel}:${i + 1} ${tok}`);
      }
    });
  }
  assert.deepEqual(unresolved, [],
    `these resolve to nothing and render invisibly — define them in styles.css :root or add a fallback:\n  ${unresolved.join('\n  ')}`);
});

test('the condition tokens are defined in the BASE stylesheet, not per-flavor', () => {
  // The specific regression: shared code styles conditions with these, so a
  // definition that only exists in bedready-theme.css leaves Khayt colourless.
  const base = fs.readFileSync(path.join(ROOT, 'renderer/styles.css'), 'utf8');
  const inBase = new Set([...base.matchAll(/^\s*(--[a-z0-9-]+)\s*:/gm)].map((m) => m[1]));
  for (const tok of ['--warn', '--warn-soft', '--danger-soft', '--ok',
                     '--grid', '--l1', '--l5', '--gap', '--bg-alt', '--bg-soft']) {
    assert.ok(inBase.has(tok), `${tok} must be defined in renderer/styles.css so every theme inherits it`);
  }
});

test('an urgent state is never styled with a token the calm state does not need', () => {
  // Direct pin on the original defect: the overdue pill and the unassigned pill
  // in kanban.js must reference tokens the base sheet actually defines.
  const base = fs.readFileSync(path.join(ROOT, 'renderer/styles.css'), 'utf8');
  const inBase = new Set([...base.matchAll(/^\s*(--[a-z0-9-]+)\s*:/gm)].map((m) => m[1]));
  const kanban = fs.readFileSync(path.join(ROOT, 'renderer/kanban.js'), 'utf8');
  const bad = [];
  for (const m of kanban.matchAll(/var\(\s*(--[a-z0-9-]+)\s*\)/g)) {
    if (!inBase.has(m[1]) && !/^--kcard-/.test(m[1])) bad.push(m[1]);
  }
  assert.deepEqual([...new Set(bad)], [], `kanban.js references tokens missing from the base sheet: ${bad.join(', ')}`);
});

test('Bed Ready resolves its tokens too', () => {
  // The shared-code test above excludes bedready* files, because Bed Ready may
  // legitimately use tokens only its own sheets define. That exclusion was
  // unexamined ground, so check it on its own terms: every no-fallback var() in
  // a Bed Ready file must resolve against base + Bed Ready's own stylesheets.
  const defs = new Set();
  const addFrom = (rel) => {
    for (const m of fs.readFileSync(path.join(ROOT, rel), 'utf8').matchAll(/^\s*(--[a-z0-9-]+)\s*:/gm)) defs.add(m[1]);
  };
  addFrom('renderer/styles.css');
  const bdFiles = [];
  for (const e of fs.readdirSync(path.join(ROOT, 'renderer'))) {
    if (/^bedready.*\.(css|js)$/.test(e)) bdFiles.push(path.join('renderer', e));
  }
  const bdDir = path.join(ROOT, 'renderer/bedready');
  if (fs.existsSync(bdDir)) {
    for (const e of fs.readdirSync(bdDir)) if (/\.(css|js)$/.test(e)) bdFiles.push(path.join('renderer/bedready', e));
  }
  for (const rel of bdFiles) if (rel.endsWith('.css')) addFrom(rel);

  const inline = inlineTokens();
  for (const rel of bdFiles) {
    for (const m of fs.readFileSync(path.join(ROOT, rel), 'utf8').matchAll(/setProperty\(\s*['"](--[a-z0-9-]+)/g)) inline.add(m[1]);
  }

  const unresolved = [];
  for (const rel of bdFiles) {
    fs.readFileSync(path.join(ROOT, rel), 'utf8').split('\n').forEach((line, i) => {
      for (const m of line.matchAll(/var\(\s*(--[a-z0-9-]+)\s*\)/g)) {
        if (!defs.has(m[1]) && !inline.has(m[1])) unresolved.push(`${rel}:${i + 1} ${m[1]}`);
      }
    });
  }
  assert.deepEqual(unresolved, [], `Bed Ready tokens that resolve to nothing:\n  ${unresolved.join('\n  ')}`);
});

test('Bed Ready loads the base stylesheet before its own', () => {
  // This is WHY the base :root additions reach Bed Ready at all. If styles.css
  // stopped being loaded first, every shared-code token would silently go
  // unresolved there while Khayt stayed fine.
  const html = fs.readFileSync(path.join(ROOT, 'renderer/bedready.html'), 'utf8');
  const base = html.indexOf('href="styles.css"');
  const own = html.indexOf('href="bedready/ds.css"');
  assert.ok(base > -1, 'bedready.html must load renderer/styles.css');
  assert.ok(own > base, 'Bed Ready sheets must load AFTER the base so their overrides win');
});
