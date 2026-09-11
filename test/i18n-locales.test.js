const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const { trackedPaths } = require('./helpers/repo-files.js');

test('locale files register KhaytLocales.en with app.title', () => {
  const ctx = vm.createContext({ globalThis: {} });
  ctx.globalThis = ctx;
  vm.runInContext(fs.readFileSync(path.join(root, 'renderer/locales/en.js'), 'utf8'), ctx, {
    filename: 'en.js',
  });
  assert.equal(ctx.globalThis.KhaytLocales?.en?.['app.title'], 'Khayt');
});

test('all seven locale files exist', () => {
  for (const lang of ['en', 'ar', 'de', 'es', 'fr', 'zh', 'ja']) {
    assert.ok(fs.existsSync(path.join(root, 'renderer/locales', `${lang}.js`)));
  }
});

test('arabic locale exposes RTL dir via i18n contract keys', () => {
  const ctx = vm.createContext({ globalThis: {} });
  ctx.globalThis = ctx;
  vm.runInContext(fs.readFileSync(path.join(root, 'renderer/locales/ar.js'), 'utf8'), ctx, {
    filename: 'ar.js',
  });
  const ar = ctx.globalThis.KhaytLocales?.ar || {};
  assert.ok(ar['theme.design.workbench']);
  assert.ok(ar['theme.design.command']);
});

/**
 * Every data-i18n key in the shipped HTML must exist in en.js.
 *
 * i18n.t() ends with `|| key`, and applyToDom assigns the result straight over
 * el.textContent — so a missing key does not fall back to the English text
 * written in the HTML, it REPLACES it with the raw dotted key. The user sees
 * "theme.design.studio_desc" sitting in the settings pane.
 *
 * check-locale-files.js only runs `node --check` on each locale, so nothing
 * caught this class before: #492 and #496 were the same shape in CSS custom
 * properties, and this is its i18n twin.
 *
 * en.js is the assertion target because t() falls back to STRINGS.en before it
 * falls back to the key, so a key present in en.js can never render raw.
 */
test('every data-i18n key in the HTML shells resolves in en.js', () => {
  const fs = require('fs');
  const path = require('path');
  const ROOT = path.join(__dirname, '..');

  const en = fs.readFileSync(path.join(ROOT, 'renderer/locales/en.js'), 'utf8');
  const keys = new Set([...en.matchAll(/^\s*"([^"]+)"\s*:/gm)].map((m) => m[1]));

  // Bed Ready rebrands a set of shared strings at runtime: bedready-home.js
  // writes an override map over every loaded locale, so keys that exist ONLY
  // there still resolve (e.g. set.lang_theme_head). Counting them keeps this
  // guard from failing on copy that is demonstrably correct on screen.
  // Note the override map is English-only — it is the right home for Bed Ready
  // rebranding, and the wrong home for anything needing translation.
  const bdr = fs.readFileSync(path.join(ROOT, 'renderer/bedready-home.js'), 'utf8');
  for (const m of bdr.matchAll(/^\s*'([a-z0-9_]+(?:\.[a-z0-9_]+)+)'\s*:/gim)) keys.add(m[1]);

  const missing = [];
  for (const shell of ['renderer/index.html', 'renderer/bedready.html']) {
    const html = fs.readFileSync(path.join(ROOT, shell), 'utf8');
    for (const attr of ['data-i18n', 'data-i18n-placeholder', 'data-i18n-aria', 'data-i18n-title', 'data-i18n-html']) {
      const re = new RegExp(`${attr}="([^"]+)"`, 'g');
      for (const m of html.matchAll(re)) {
        // Currency unit labels come from settings, not locale strings —
        // applyToDom skips this key explicitly.
        if (m[1] === 'common.currency') continue;
        if (!keys.has(m[1])) missing.push(`${path.basename(shell)}: ${m[1]} (${attr})`);
      }
    }
  }
  assert.deepEqual([...new Set(missing)], [],
    `these render as their raw key instead of text:\n  ${[...new Set(missing)].join('\n  ')}`);
});

test('pt-BR is a COMPLETE locale, not a partial one', () => {
  // t() falls back to STRINGS.en before it falls back to the key, so a partial
  // locale does not break — it silently serves English to someone who chose
  // Português. That is worse than not offering the language, which is why this
  // asserts parity rather than mere existence: pt-BR is in the picker, so it
  // has to actually be finished.
  const load = (lang) => {
    const ctx = vm.createContext({ globalThis: {} });
    ctx.globalThis = ctx;
    vm.runInContext(fs.readFileSync(path.join(root, `renderer/locales/${lang}.js`), 'utf8'), ctx, {
      filename: `${lang}.js`,
    });
    return ctx.globalThis.KhaytLocales?.[lang] || {};
  };
  const en = load('en');
  const pt = load('pt-BR');
  const missing = Object.keys(en).filter((k) => pt[k] === undefined);
  assert.deepEqual(missing.slice(0, 20), [], `pt-BR is missing ${missing.length} key(s)`);
  assert.equal(Object.keys(pt).length, Object.keys(en).length);

  // Placeholders must survive translation or the string breaks at runtime:
  // "{n} pedidos" is fine, "{numero} pedidos" silently renders the literal.
  const bad = [];
  for (const [k, v] of Object.entries(pt)) {
    const want = (String(en[k]).match(/\{[a-zA-Z0-9_]+\}/g) || []).sort().join(',');
    const got = (String(v).match(/\{[a-zA-Z0-9_]+\}/g) || []).sort().join(',');
    if (want !== got) bad.push(`${k}: expected ${want || '(none)'} got ${got || '(none)'}`);
  }
  assert.deepEqual(bad, [], 'placeholders altered in translation');
});

test('every locale the language picker offers is actually registered', () => {
  // A picker entry with no locale file (or one missing from i18n's valid list)
  // silently falls back to English while the dropdown claims otherwise.
  const i18n = fs.readFileSync(path.join(root, 'renderer/i18n.js'), 'utf8');
  const valid = (i18n.match(/const valid = \[([^\]]+)\]/) || [, ''])[1]
    .split(',').map((s) => s.trim().replace(/^'|'$/g, '')).filter(Boolean);

  for (const shell of ['renderer/index.html', 'renderer/bedready.html']) {
    const html = fs.readFileSync(path.join(root, shell), 'utf8');
    const offered = new Set([...html.matchAll(/<option value="([a-zA-Z-]{2,5})">/g)]
      .map((m) => m[1]).filter((v) => valid.includes(v) || /^[a-z]{2}(-[A-Z]{2})?$/.test(v)));
    for (const lang of offered) {
      if (!valid.includes(lang)) continue;   // not a language option
      assert.ok(fs.existsSync(path.join(root, `renderer/locales/${lang}.js`)),
        `${shell} offers ${lang} but renderer/locales/${lang}.js does not exist`);
      assert.match(html, new RegExp(`locales/${lang}\\.js`),
        `${shell} offers ${lang} but never loads its locale script`);
    }
  }
});

test('deleted themes leave no strings behind', () => {
  // cockpit, atlas and the console status bar were removed in 3.3, but their
  // locale keys stayed — 54 of them, times nine languages, translated and
  // maintained for UI that no longer exists. Anything reintroducing them is
  // almost certainly a revert, not a feature.
  const gone = ['cockpit.', 'atlas.', 'console.status.'];
  for (const lang of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'tr', 'zh', 'pt-BR']) {
    const src = fs.readFileSync(path.join(root, `renderer/locales/${lang}.js`), 'utf8');
    for (const prefix of gone) {
      assert.equal(src.includes(`"${prefix}`), false,
        `${lang}.js still carries ${prefix}* keys for a deleted theme`);
    }
  }
  // And the markup those keys described must stay gone from BOTH shells — #514
  // removed it from index.html only, leaving bedready.html carrying it hidden.
  for (const shell of ['renderer/index.html', 'renderer/bedready.html']) {
    const html = fs.readFileSync(path.join(root, shell), 'utf8');
    assert.equal(html.includes('consoleStatusBar'), false, `${shell} still has the dead status bar`);
  }
});

/**
 * Every key in en.js must be reachable from code. 199 were not.
 *
 * Dead keys are not free: each one is nine translations that get re-reviewed on
 * every locale pass, and they hide real defects. The digest rewrite moved its
 * strings to a `digest.*` namespace and left `set.digest_*` behind — which
 * looked like ordinary dead copy, but "Daily"/"Weekly" were still on screen in
 * English because the rewrite had dropped the t() calls, not the feature.
 *
 * "Reachable" is deliberately generous — a key passes if its exact text appears
 * anywhere in any source file, or if it starts with a prefix that some code
 * concatenates onto ('cl.source_' + src), or ends with a tail some code appends
 * (x + '.title'). Only a key that satisfies none of those is reported. A key
 * used in a way this cannot see is a key no reader can find either.
 */
test('no locale key is unreachable from code', () => {
  const ctx = vm.createContext({ globalThis: {} });
  ctx.globalThis = ctx;
  vm.runInContext(fs.readFileSync(path.join(root, 'renderer/locales/en.js'), 'utf8'), ctx);
  const keys = Object.keys(ctx.globalThis.KhaytLocales.en);

  // The corpus is what GIT tracks, not what is sitting in the checkout. Walking
  // the working directory searched 4,886 files here of which 774 were in the
  // repo: `.claude/worktrees/` held 2,151 and an untracked `Khayt/` another
  // 1,907, all of them older copies of this same source. A key deleted from the
  // live tree is still "reachable" in a stale copy, so this test passed locally
  // and failed in CI — see test/helpers/repo-files.js, which is where the rest
  // of that reasoning lives.
  const files = trackedPaths((rel) =>
    /\.(js|mjs|cjs|html|css|json|md)$/.test(rel) && !rel.startsWith('renderer/locales/'));
  const blob = files.map((f) => fs.readFileSync(f, 'utf8')).join('\n');

  // Prefixes some code concatenates onto, and tails some code appends.
  const pre = new Set(); const suf = new Set();
  for (const re of [/['"]([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*[._])['"]\s*\+/g,
                    /`([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*[._])\$\{/g])
    for (const m of blob.matchAll(re)) pre.add(m[1].replace(/[._]$/, ''));
  // Keep the separator. Matching a bare tail against BOTH ".tail" and "_tail"
  // is far too loose: one `${x}.title` anywhere made every *_title key in the
  // app look reachable, so a genuinely dead one could never be reported.
  for (const re of [/\+\s*['"]([._][A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)['"]/g,
                    /\$\{[^}]+\}([._][A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)/g])
    for (const m of blob.matchAll(re)) suf.add(m[1]);

  const isKeyChar = (ch) => /[A-Za-z0-9_.]/.test(ch);
  const literal = (k) => {
    for (let i = blob.indexOf(k); i !== -1; i = blob.indexOf(k, i + k.length)) {
      if (!isKeyChar(blob[i - 1] || '') && !isKeyChar(blob[i + k.length] || '')) return true;
    }
    return false;
  };
  const dead = keys.filter((k) => !literal(k)
    && ![...pre].some((p) => k === p || k.startsWith(`${p}.`) || k.startsWith(`${p}_`))
    && ![...suf].some((s) => k.endsWith(s)));

  assert.deepEqual(dead, [],
    `${dead.length} locale key(s) no code can reach — delete them from all nine locales:\n  ${dead.join('\n  ')}`);
});

/**
 * The mirror of the unreachable-key guard: keys the code ASKS for that no
 * locale file defines.
 *
 * `tr(key, fallback)` returns the English fallback when the key is missing, so
 * the screen looks perfectly fine — in English — in all nine languages, and
 * nothing anywhere reports a problem. 33 keys were in this state, 29 of them
 * the whole Bed Ready filament-care log, which had never been translated at
 * all despite reading as finished code.
 *
 * The two guards together close the loop: one fails on a key nothing uses, this
 * one fails on a use with no key.
 */
test('every key the code asks for exists in en.js', () => {
  const ctx = vm.createContext({ globalThis: {} });
  ctx.globalThis = ctx;
  vm.runInContext(fs.readFileSync(path.join(root, 'renderer/locales/en.js'), 'utf8'), ctx);
  const en = ctx.globalThis.KhaytLocales.en;

  // Bed Ready rebrands some keys at runtime over every loaded locale.
  const bdr = fs.readFileSync(path.join(root, 'renderer/bedready-home.js'), 'utf8');
  const extra = new Set([...bdr.matchAll(/^\s*'([a-z0-9_]+(?:\.[a-z0-9_]+)+)'\s*:/gim)].map((m) => m[1]));

  const files = [];
  (function walk(d) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.name === 'locales') continue;
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.js')) files.push(p);
    }
  })(path.join(root, 'renderer'));

  const keys = Object.keys(en);
  const missing = new Map();
  for (const f of files) {
    const src = fs.readFileSync(f, 'utf8');
    const rel = path.relative(root, f);
    src.split('\n').forEach((line, i) => {
      // Only the two-argument forms: t('k') with no fallback already renders
      // the raw key, which the data-i18n guard and review catch on sight.
      for (const m of line.matchAll(/\b(?:tr|tt)\(\s*'([a-z0-9_]+(?:\.[a-z0-9_]+)+)'\s*,\s*'/gi)) {
        const key = m[1];
        if (en[key] === undefined && !extra.has(key)) missing.set(key, `${rel}:${i + 1}`);
      }
      /* THE FORM THIS GUARD COULD NOT SEE, AND THE ONE THE APP MOSTLY USES.
       *
       * `t('plib.folder') || 'Folder'` looks like a safe fallback and is not
       * one: i18n.js line 91 ends `|| key`, so a MISSING key comes back as the
       * key itself — truthy — and the `||` never fires. The screen renders the
       * literal text `plib.folder`.
       *
       * That is what shipped. A screenshot of v3.7.0-beta.24's print-file
       * library shows a filter chip labelled `plib.unfiled`, in English, in the
       * released app. 59 keys were in that state: the whole filter bar, the
       * batch converter's colour dialog, "Delivered", "Done", "Resent", and the
       * placeholder in the product-name box.
       *
       * Every gate was green. Locale parity compares each language to en.js, so
       * a key that is in NO file sits in neither half of that comparison.
       *
       * SO THE RULE IS NOT "does it have a fallback" — no fallback can help.
       * Every key-shaped literal inside any t(…) call must exist in en.js.
       *
       * ── AND IT IS NOT A REGEX ──────────────────────────────────────────────
       * Three versions of this were regexes and each had a hole:
       *
       *   v1 matched only tr(k, fallback);
       *   v2 tried to detect `|| 'x'` and missed `|| \`x\``, a parenthesised
       *      ternary, and anything spanning two lines;
       *   v3 matched one level of nested parens — so
       *      t('plib.show_more', { n: String(Math.min(a, b)) }) was invisible,
       *      which I found by adding exactly that call and watching the guard
       *      stay green.
       *
       * A balanced scan is not hard and has no holes. Find `t(`, count
       * parentheses to the matching close, read the literals in between. */
      for (let at = line.indexOf('t('); at !== -1; at = line.indexOf('t(', at + 1)) {
        // `t(` and not `format(`, `print(`, `.at(` — the char before must not be
        // part of an identifier.
        if (at > 0 && /[A-Za-z0-9_$.]/.test(line[at - 1])) continue;
        let depth = 0, end = -1;
        for (let j = at + 1; j < line.length; j++) {
          if (line[j] === '(') depth++;
          else if (line[j] === ')') { depth--; if (depth === 0) { end = j; break; } }
        }
        const inner = line.slice(at + 2, end === -1 ? line.length : end);
        /* A PREFIX ENDING IN A DOT, WHICH THIS GUARD USED TO SKIP ENTIRELY.
         *
         * `t('status.' + s)` carries no key-shaped literal — `'status.'` has
         * nothing after the dot — so the scan below never looked at it, and the
         * escape hatch two blocks down only forgives a trailing UNDERSCORE.
         *
         * There has never been a `status.*` key in any locale. So every status
         * chip in the report builder read the literal "status.quote" in all
         * nine languages, in a released app, with this guard green — the same
         * failure it was written for, one character to the left.
         *
         * The concatenated key still cannot be read from the source. What CAN
         * be checked is that the prefix names SOMETHING: if no key in en.js
         * begins with it, the call cannot resolve for any value of `s`. */
        for (const pre of inner.matchAll(/'([a-z0-9_]+(?:\.[a-z0-9_]+)*\.)'\s*\+/gi)) {
          const prefix = pre[1];
          if (!keys.some((k) => k.startsWith(prefix))) {
            missing.set(prefix + '*', `${rel}:${i + 1}`);
          }
        }
        for (const lit of inner.matchAll(/'([a-z0-9_]+(?:\.[a-z0-9_]+)+)'/gi)) {
          const key = lit[1];
          // A trailing underscore is a PREFIX: t('audit.act_' + kind). The real
          // key is the concatenation and cannot be read from the source.
          if (key.endsWith('_')) continue;
          if (en[key] === undefined && !extra.has(key)) missing.set(key, `${rel}:${i + 1}`);
        }
      }
    });
  }
  const report = [...missing].map(([k, at]) => `${k}  (${at})`);
  assert.deepEqual(report, [],
    'these render their own key name on screen — `plib.unfiled`, not "Unfiled" — '
    + `in every language, because i18n.t() returns the key when it has no string:\n  ${report.join('\n  ')}`);
});

test('every settings section head and hint is translatable', () => {
  // Four heads ("LAN API & iCal", "Outbound Webhooks", …) and two hints shipped
  // as bare English: no data-i18n, so applyToDom never touched them and they
  // stayed English in all nine languages. The scan found them because their
  // would-be keys were sitting unused in the locale files.
  for (const shell of ['renderer/index.html', 'renderer/bedready.html']) {
    const html = fs.readFileSync(path.join(root, shell), 'utf8');
    const bare = [...html.matchAll(/<div class="settings-section-head"([^>]*)>([^<]+)</g)]
      .filter((m) => !/data-i18n/.test(m[1]))
      .map((m) => m[2].trim());
    assert.deepEqual(bare, [],
      `${shell}: section head(s) render English in every language:\n  ${bare.join('\n  ')}`);
  }
});

test('the README states the number of languages that actually ship', () => {
  /* It said "7 UI languages" and listed seven, while renderer/locales/ held
   * nine — Turkish and Portuguese had been added and the sentence was not.
   *
   * A count in prose is the kind of fact nothing re-reads. This is the cheapest
   * possible guard for it: the number, and every language named beside it.
   */
  const fs = require('fs');
  const path = require('path');
  const root = path.join(__dirname, '..');
  const shipped = fs.readdirSync(path.join(root, 'renderer', 'locales')).filter((f) => f.endsWith('.js'));
  const readme = fs.readFileSync(path.join(root, 'README.md'), 'utf8');

  const m = readme.match(/^- (\d+) UI languages: (.+)$/m);
  assert.ok(m, 'the README must state how many languages ship');
  assert.equal(Number(m[1]), shipped.length,
    `README says ${m[1]} UI languages; renderer/locales/ has ${shipped.length}`);
  // And the names beside the number have to be that many too — a count fixed
  // without the list is the same sentence still lying, more quietly.
  assert.equal(m[2].split(',').length, shipped.length,
    'the list beside the number must name every language that ships');
});
