const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const reg = require('../renderer/themes/registry-core.js');

function loadEnLocale() {
  const ctx = vm.createContext({ globalThis: {} });
  ctx.globalThis = ctx;
  vm.runInContext(fs.readFileSync(path.join(root, 'renderer/locales/en.js'), 'utf8'), ctx, {
    filename: 'en.js',
  });
  return ctx.globalThis.KhaytLocales?.en || {};
}

function loadLocale(lang) {
  const ctx = vm.createContext({ globalThis: {} });
  ctx.globalThis = ctx;
  vm.runInContext(fs.readFileSync(path.join(root, `renderer/locales/${lang}.js`), 'utf8'), ctx, {
    filename: `${lang}.js`,
  });
  return ctx.globalThis.KhaytLocales?.[lang] || {};
}

test('every selectable built-in theme has a preview PNG', () => {
  const previewsDir = path.join(root, 'renderer/themes/previews');
  for (const id of reg.listSelectableThemes().filter((t) => !t.startsWith('custom:'))) {
    const theme = reg.getTheme(id);
    const file = theme.preview || `themes/previews/${id}.png`;
    const abs = path.join(root, 'renderer', file.replace(/^themes\//, 'themes/'));
    assert.ok(fs.existsSync(abs), `missing preview for ${id}: ${abs}`);
  }
});

test('en locale defines all built-in theme label and desc keys', () => {
  const en = loadEnLocale();
  for (const [id, theme] of Object.entries(reg.BUILTIN_THEMES)) {
    if (theme.enabled === false) continue;
    assert.ok(en[theme.labelKey], `${id} missing ${theme.labelKey}`);
    assert.ok(en[theme.descKey], `${id} missing ${theme.descKey}`);
    for (const accent of Object.values(theme.accents || {})) {
      if (accent.labelKey) assert.ok(en[accent.labelKey], `${id} missing accent ${accent.labelKey}`);
    }
  }
});

test('en locale defines reserved coming-soon theme keys', () => {
  const en = loadEnLocale();
  for (const [id, theme] of Object.entries(reg.RESERVED_THEMES)) {
    if (!theme.comingSoon) continue;
    assert.ok(en[theme.labelKey], `reserved ${id} missing ${theme.labelKey}`);
    assert.ok(en[theme.descKey], `reserved ${id} missing ${theme.descKey}`);
  }
});

test('arabic locale includes theme design keys for RTL QA', () => {
  const ar = loadLocale('ar');
  const required = [
    'theme.design.label',
    'theme.design.workbench',
    'theme.design.command',
    'theme.design.vivid',
  ];
  for (const key of required) {
    assert.ok(ar[key], `ar.js missing ${key}`);
  }
});

test('each built-in theme declares a known shell and its own body class', () => {
  // Kept in step with applyBodyClasses() in renderer/themes.js — these are the
  // exact values it toggles on.
  const SHELLS = ['workbench', 'command', 'vivid', 'meridian', 'foreman', 'flow', 'default'];
  const SHELL_CLASSES = ['bedready-ui', 'khayt-workbench', 'khayt-command', 'khayt-vivid', 'khayt-meridian', 'khayt-foreman', 'khayt-flow'];
  const seenShell = new Map();
  const seenClass = new Map();
  for (const [id, theme] of Object.entries(reg.BUILTIN_THEMES)) {
    if (theme.enabled === false) continue;
    assert.ok(theme.bodyClass, `${id} missing bodyClass`);
    assert.ok(theme.shell, `${id} missing shell`);
    // The name of this test promised distinctness but never checked it — two
    // themes sharing a shell or body class would have sailed through, and
    // applyBodyClasses() toggles on exactly these values.
    // A shell MAY be shared. It used to be one-per-theme simply because there
    // were three themes and three shells, and this asserted that coincidence as
    // a rule. Reuse is the supported mechanism — CUSTOM_THEME_SHELLS exists so a
    // theme can pick an existing layout — and applyBodyClasses() handles it: it
    // toggles the shell class from theme.shell and adds theme.bodyClass
    // separately. Blueprint rides the Workbench shell, Nocturne rides Command.
    assert.ok(SHELLS.includes(theme.shell), `${id} declares unknown shell '${theme.shell}'`);

    // The body class, however, must still be unique: it is the per-theme hook
    // every identity stylesheet is scoped to, so a collision silently gives one
    // theme another's styling.
    assert.equal(seenClass.get(theme.bodyClass), undefined,
      `${id} reuses bodyClass '${theme.bodyClass}' already claimed by ${seenClass.get(theme.bodyClass)}`);
    seenShell.set(theme.shell, id);
    seenClass.set(theme.bodyClass, id);

    // The body class must actually end up on <body>, and there are exactly two
    // ways that happens in applyBodyClasses(): it is this theme's OWN shell
    // class (set by the shell toggle), or it is not a shell class at all (added
    // as the extra per-theme hook). Naming a DIFFERENT shell's class is the
    // trap — the toggle for it stays false because the shell does not match,
    // and the extra-hook branch explicitly skips shell classes, so the theme
    // gets no hook and its stylesheet never matches. Silently, with the
    // inherited layout still looking correct.
    const ownShellClass = `khayt-${theme.shell}`;
    assert.equal(
      theme.bodyClass === ownShellClass || !SHELL_CLASSES.includes(theme.bodyClass),
      true,
      `${id} bodyClass '${theme.bodyClass}' is another shell's class and would never be applied`,
    );
  }
});

test('every enabled built-in theme has an implementation directory', () => {
  // The registry is a hand-maintained map and the directories are the code it
  // points at. An id with no directory means a theme the user can select that
  // renders nothing; a directory with no id is dead code kept alive by nobody.
  const dir = path.join(root, 'renderer/themes');
  const dirs = fs.readdirSync(dir)
    .filter((d) => fs.statSync(path.join(dir, d)).isDirectory())
    .filter((d) => !d.startsWith('_') && d !== 'previews' && d !== 'custom');
  const ids = Object.entries(reg.BUILTIN_THEMES).filter(([, t]) => t.enabled !== false).map(([id]) => id);

  assert.deepEqual(ids.filter((i) => !dirs.includes(i)), [], 'selectable theme with no implementation');
  assert.deepEqual(dirs.filter((d) => !ids.includes(d)), [], 'theme directory no registry entry points at');
});

test('the theme e2e covers every theme a user can pick', () => {
  // e2e-theme-shells.mjs pins theme ids by hand. A new theme that is selectable
  // but unpinned ships with nothing rendering its dashboard or queue — which is
  // exactly how a broken top-bar search reached users before that suite was
  // added to CI.
  const e2e = fs.readFileSync(path.join(root, 'scripts/e2e-theme-shells.mjs'), 'utf8');
  const pinned = new Set([...e2e.matchAll(/id:\s*'([a-z]+)'/g)].map((m) => m[1]));
  const selectable = reg.listSelectableThemes().filter((t) => !t.startsWith('custom:'));
  const uncovered = selectable.filter((id) => !pinned.has(id));
  assert.deepEqual(uncovered, [], `selectable themes with no e2e coverage: ${uncovered.join(', ')}`);
});

test('coming-soon cards are labelled with their own theme, not the fallback', () => {
  // getTheme() normalises first, and normalizeDesignId() maps anything
  // `enabled: false` onto workbench — correct for deciding what to RENDER (a
  // disabled theme must never be applied), wrong for describing one. The
  // picker's coming-soon loop went through getTheme(), so Pulse and Stream both
  // drew "Workbench / Native productivity app…" under a COMING SOON badge.
  // Found by opening the real Settings screen and reading the cards.
  for (const id of reg.listComingSoonThemes()) {
    const def = reg.getThemeDefinition(id);
    assert.ok(def, `${id} has no raw definition`);
    assert.equal(def.labelKey, `theme.design.${id}`, `${id} must be labelled as itself`);
    assert.equal(def.descKey, `theme.design.${id}_desc`, `${id} must describe itself`);
    // And the trap that caused it: the normalising lookup still resolves away.
    assert.equal(reg.getTheme(id).labelKey, 'theme.design.workbench',
      'getTheme() is expected to normalise a disabled theme — that is why the raw lookup exists');
  }
  // The picker must use the raw lookup for these cards.
  const src = fs.readFileSync(path.join(root, 'renderer/themes/theme-picker.js'), 'utf8');
  assert.match(src, /getThemeDefinition\(id\)/,
    'the coming-soon loop must label from getThemeDefinition, not getTheme');
});

test('the dead console status bar is gone from the shell markup', () => {
  // A leftover from a deleted legacy theme: .console-status rendered two em
  // dashes ("— —") under the content in EVERY Khayt theme, because nothing in
  // Khayt's CSS hid it and no JS ever populated it. Bed Ready had already
  // hidden it for itself — bedready-theme.css even names it "the stray '— —'"
  // — which is how it survived: fixed for one product, left for the other.
  //
  // So check BOTH shells. Asserting it only for index.html would leave the exact
  // asymmetry the comment above describes free to happen again in the other
  // direction — removed from Khayt, quietly re-added to Bed Ready.
  for (const shell of ['renderer/index.html', 'renderer/bedready.html']) {
    const html = fs.readFileSync(path.join(root, shell), 'utf8');
    for (const id of ['consoleStatusBar', 'consoleStatusPrinters', 'consoleStatusQueue',
      'consoleStatusLocation', 'consoleStatusClock']) {
      assert.equal(html.includes(id), false, `${id} is dead markup in ${shell} and must stay removed`);
    }
    assert.equal(/class="console-status"/.test(html), false, `.console-status is back in ${shell}`);
  }
});

test('Meridian will not let a running job be dragged to another printer', () => {
  // The schedule can reassign work by dropping a block on a lane. A job that is
  // PRINTING is physically on that machine, so moving it would assert something
  // untrue about the shop floor — it is not draggable, and the drop handler
  // refuses it a second time in case the attribute is bypassed.
  const src = fs.readFileSync(path.join(root, 'renderer/themes/meridian/screens.js'), 'utf8');
  assert.match(src, /const movable = b\.state !== 'run' && b\.state !== 'done';/,
    'running and finished blocks must not be draggable');
  assert.match(src, /if \(order\.status === 'printing' \|\| KhaytOrderStatus\.isFinished\(order\)\) return false;/,
    'assignToMachine must refuse a running job even if the drag attribute is bypassed');
  // Both fields, not just the id: analytics resolves a machine by NAME too.
  assert.match(src, /order\.machineId = machineId;\s*\n\s*order\.machine = machine\.name \|\| machineId;/,
    'assignment must write machineId AND machine, like the batch-assign path');
});

test('Meridian keeps its nav proxy in step however the tab changed', () => {
  // Forwarding clicks only covers clicks. A tab also changes from the ⌘K
  // palette, a single-key shortcut, an in-page link or any switchTab() call —
  // and the proxy highlighted Dashboard while Settings was open until it
  // watched the real buttons instead.
  const src = fs.readFileSync(path.join(root, 'renderer/themes/meridian/shell.js'), 'utf8');
  assert.match(src, /new MutationObserver/, 'the proxy must observe the real nav, not just its own clicks');
  assert.match(src, /attributeFilter: \['class', 'style'\]/, 'active/hidden state lives in class and style');
  assert.match(src, /stopWatching\(\)/, 'and must disconnect on teardown');
  // Overflow affordance: 15 tabs do not fit, and silent clipping is the bug.
  assert.match(src, /function syncNavOverflow/, 'the scroll arrows must be driven by real overflow');
  assert.match(src, /function scrollActiveIntoView/, 'the active tab must be pulled into view');
});

test('Foreman borrows every rule in its docket instead of inventing one', () => {
  // A triage list with its own thresholds would quietly disagree with the rest
  // of the app — the queue calling an order fine while the docket calls it
  // late. Every row type must come from the shared selector or helper.
  const src = fs.readFileSync(path.join(root, 'renderer/themes/foreman/screens.js'), 'utf8');
  assert.match(src, /KhaytAttention\.selectAttention/, 'stopped machines + overdue come from the shared selector');
  assert.match(src, /payStatus\(o\) === 'paid'/, 'unpaid uses payStatus, like the dashboard');
  assert.match(src, /orderOwedBase\(o\)/, 'the amount owed uses the shared currency helper');
  assert.match(src, /isLowStock\(item\)/, 'low stock uses the shared helper, not a local threshold');
  assert.match(src, /KhaytAttention\.machineState/, 'idle uses the shared machine-state rule');
  // And the count on the bar must come from the list, never be recomputed.
  const shell = fs.readFileSync(path.join(root, 'renderer/themes/foreman/shell.js'), 'utf8');
  assert.match(shell, /function syncDocketCount\(n\)/,
    'the bar is told the count by the list so the two cannot disagree');
});

test('Flow moves work through updateStatus, never by assigning status itself', () => {
  // The board is the one place in the app where moving an order is a single
  // gesture, so it is the worst place to bypass the rules. updateStatus() is
  // where they live: the WIP limit warning and its hard-block mode, the BOM
  // assembly gate that refuses to complete an order whose parts have not passed
  // QC, the save, and the re-render. Assigning order.status directly would skip
  // all four silently.
  const shell = fs.readFileSync(path.join(root, 'renderer/themes/flow/shell.js'), 'utf8');
  assert.match(shell, /updateStatus\(id, status\)/, 'the drop must go through updateStatus()');
  // Assignment only: `.status ===` is the legitimate comparison this must not
  // trip over, so the lookahead excludes == and ===.
  assert.equal(/\.status\s*=(?!=)/.test(shell), false,
    'the board must never assign order.status itself — that bypasses every gate');

  // And the columns must be the app's statuses, not a second opinion about them.
  const screens = fs.readFileSync(path.join(root, 'renderer/themes/flow/screens.js'), 'utf8');
  for (const status of ['pending', 'printing', 'post', 'qc', 'completed']) {
    assert.ok(screens.includes(`status: '${status}'`), `board is missing the ${status} column`);
  }
  assert.match(screens, /queue\.(pending|printing|post|qc|completed)/,
    'column labels reuse the queue keys rather than minting a second set');
  assert.match(screens, /KhaytTiers.*showsBusiness/s,
    'money on cards must be gated on the tier, like every other themed home');
  assert.match(screens, /orderMatchesActiveLocation/,
    'the board must respect the location filter like every other screen');
});

test('Foreman keyboard triage never steals a key from a field or a modal', () => {
  // J/K/Enter drive the docket. Single-letter shortcuts are exactly the kind
  // that break typing if they are not gated, and this app already has
  // single-key tab shortcuts, so the bar for getting this right is known.
  const src = fs.readFileSync(path.join(root, 'renderer/themes/foreman/shell.js'), 'utf8');
  assert.match(src, /if \(e\.metaKey \|\| e\.ctrlKey \|\| e\.altKey\) return;/, 'chords are not ours');
  assert.match(src, /INPUT\|TEXTAREA\|SELECT/, 'never fire while a field has focus');
  assert.match(src, /isContentEditable/, 'including contenteditable');
  assert.match(src, /#modalMount \.modal/, 'never fire behind an open modal');
  assert.match(src, /dashboard-tab.*classList\.contains\('active'\)/, 'only while the docket is the visible screen');
  assert.match(src, /function removeKeys/, 'and the listener must come off on teardown');
});

test('every shell declares the base layout it needs', () => {
  // .khayt-app / .khayt-body / .khayt-sidebar carry no layout of their own, so
  // a shell that keeps the sidebar but omits these renders the whole nav as a
  // full-width block stacked above the content. Foreman shipped that way for
  // one render. Each sidebar shell must claim the row + the column.
  for (const shell of ['workbench', 'command', 'vivid', 'foreman']) {
    const css = fs.readFileSync(path.join(root, `renderer/themes/${shell}/shell.css`), 'utf8');
    assert.match(css, new RegExp(`body\\.khayt-${shell} \\.khayt-body`),
      `${shell} must lay out .khayt-body`);
  }
});

test('Foreman ranking survives volume, and the count stays truthful', () => {
  // Worst-first loses to volume otherwise: thirty unpaid invoices bury the
  // stopped printer they are ranked below, and the list quietly turns into an
  // accounts-receivable report. Runs longer than GROUP_AT collapse to one row.
  const src = fs.readFileSync(path.join(root, 'renderer/themes/foreman/screens.js'), 'utf8');
  assert.match(src, /const GROUP_AT = 3;/, 'a run longer than this collapses');
  assert.match(src, /function visibleRows/, 'the drawn list is derived, not the raw one');
  // The count must report ITEMS. A group is a display affordance, and a bar
  // that counted collapsed rows would under-report what is outstanding.
  assert.match(src, /fm-count\$\{rows\.length \? '' : ' zero'\}">\$\{rows\.length\}/,
    'the header count comes from the item list, not the drawn rows');
  // Focus must walk what is on screen or it lands inside a collapsed group.
  assert.match(src, /const rows = visibleRows\(buildDocket\(\)\);/,
    'keyboard movement walks the visible rows');
});

test('Foreman treats free capacity as one decision, not one per printer', () => {
  // Which printer is free is not the decision — "there is free capacity and
  // waiting work" is, and the answer is the same for all of them. Four idle
  // machines emitting four near-identical rows padded a list whose promise is
  // that every row needs an action.
  const src = fs.readFileSync(path.join(root, 'renderer/themes/foreman/screens.js'), 'utf8');
  assert.match(src, /key: 'd:idle', sev: 'idle',/, 'idle is a single aggregate row');
  assert.equal(/key: `d:\$\{m\.id\}`/.test(src), false, 'never one row per idle machine');
  assert.match(src, /note: idle\.join\(' · '\)/, 'the machine names belong in the detail pane');
});
