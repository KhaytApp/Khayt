#!/usr/bin/env node
'use strict';
/**
 * Print one version's CHANGELOG entry, for use as a release's notes.
 *
 * Every release this repo has ever published carries the same body:
 *
 *     See [README](https://github.com/KhaytApp/Khayt#readme) for full release notes.
 *
 * which is what `release.yml` passes to `gh release create --notes`. That string
 * is also what electron-updater hands the app, so Khayt's own update dialog —
 * which has a panel built for release notes and a heading that says "Review what
 * is new before installing" — has never had anything to put in it, and falls
 * back to "Release notes were not included with this update."
 *
 * A shop cannot agree to changes it is not shown, so the consent gate in
 * lib/major-changes.js is impossible until this exists.
 *
 *   node scripts/changelog-section.js 3.7.0-beta.23
 *
 * Exits non-zero when the version has no section, rather than printing nothing:
 * a release whose notes are silently empty is the state this replaces.
 *
 * ── AND IT FITS IN A GITHUB RELEASE BODY ──────────────────────────────────
 *
 * A release body is capped at 125,000 characters and the API rejects the whole
 * request with `HTTP 422: body is too long`. The `v3.7.0` cut hit it: 2,357
 * lines and 152,890 characters, because a stable promotion carries the entire
 * line's entry, and that line absorbed 269 changes. The tag existed, no release
 * was created, and every platform job was skipped — a cut that looks done from
 * `git ls-remote --tags` and has shipped nothing.
 *
 * So the body is capped here, where it is built, rather than in `release.yml`.
 * Two reasons: the workflow calls this script with no arguments, so a default
 * protects every lane at once — including Bed Ready's — and a truncation rule
 * that lives next to the parser it must not break is one somebody can check.
 *
 * IT TRUNCATES FROM THE END, and that is not a detail. `lib/major-changes.js`
 * reads `### Before you update` out of this body to decide whether the update
 * gates, and that section is written first in every entry. Cutting from the
 * front to "keep the recent stuff" would silently un-gate a release that moves
 * a shop's data — which is the exact failure the gate exists to prevent.
 */
const fs = require('fs');
const path = require('path');

function sectionFor(changelog, version) {
  const lines = String(changelog).split(/\r?\n/);
  // `## [3.7.0-beta.23] - 2026-09-02`, and tolerant of a missing date or the
  // brackets being dropped — the heading is written by hand at cut time.
  const wanted = String(version).trim().replace(/^v/, '');
  const isVersionHeading = (l) => /^##\s+/.test(l);
  const versionOf = (l) => {
    const m = l.match(/^##\s+\[?([^\]\s]+)\]?/);
    return m ? m[1].trim() : '';
  };

  const start = lines.findIndex((l) => isVersionHeading(l) && versionOf(l) === wanted);
  if (start === -1) return null;

  const rest = lines.slice(start + 1);
  const end = rest.findIndex(isVersionHeading);
  const body = (end === -1 ? rest : rest.slice(0, end)).join('\n').trim();
  return body || null;
}

/**
 * GitHub's hard limit on a release body. Not a tuning knob: the API returns
 * 422 at 125,001 and the release is not created at all.
 */
const GITHUB_BODY_LIMIT = 125000;

/** Headroom, so a future `gh` that appends anything cannot push us over. */
const DEFAULT_MAX_CHARS = 120000;

/**
 * Cut `body` to `maxChars`, at a boundary a reader would recognise.
 *
 * Prefers the last section heading, then the last top-level bullet, then a
 * blank line — a body that stops mid-sentence reads as a broken release rather
 * than a long one. Falls back to a hard cut only if none of those exist, which
 * for a CHANGELOG entry means something is already very wrong.
 */
function fitForRelease(body, opts = {}) {
  const maxChars = Number.isFinite(opts.maxChars) ? opts.maxChars : DEFAULT_MAX_CHARS;
  const version = opts.version || '';
  const text = String(body || '');
  if (text.length <= maxChars) return { text, truncated: false, omitted: 0 };

  const notice = [
    '',
    '---',
    '',
    `**This entry is longer than a GitHub release body can hold, so it stops here.**`,
    `The rest of what changed in ${version || 'this release'} is in the full changelog:`,
    'https://github.com/KhaytApp/Khayt/blob/main/CHANGELOG.md',
    '',
  ].join('\n');

  const budget = maxChars - notice.length;
  const head = text.slice(0, budget);
  // Last recognisable boundary, most preferred first.
  const cut = Math.max(
    head.lastIndexOf('\n### '),
    head.lastIndexOf('\n- **'),
    head.lastIndexOf('\n\n'),
  );
  const kept = cut > 0 ? head.slice(0, cut) : head;
  return {
    text: kept.replace(/\s+$/, '') + '\n' + notice,
    truncated: true,
    omitted: text.length - kept.length,
  };
}

/**
 * Entries addressed to whoever maintains this repo, not to a shop.
 *
 * `(Maintainers)` and `(Repo)` are written into the bullet by the author to say
 * exactly that. They belong in CHANGELOG.md — that is the record — but a shop
 * reading its update dialog has no use for "the release script ran a comment",
 * and in 3.8.0 they were 22,000 characters of the 126,885 that would not fit.
 *
 * The alternative was letting `fitForRelease` trim the overflow from the END,
 * which lands in `### Fixed` and would have dropped fourteen entries including
 * "Break-even was telling shops to bill LESS than they must" and "The cash-flow
 * chart counted a deposit as the whole job". Cutting the notes a shop cannot use
 * to keep the money bugs it can is the trade that needed making.
 *
 * NOT folded into `sectionFor`. That function feeds the update-consent gate
 * (`scripts/e2e-update-consent-smoke.mjs` reads it), and what a shop is asked to
 * agree to must stay exactly what the file says. This shapes the RELEASE BODY
 * and nothing else.
 */
const MAINTAINER_BULLET = /^- \*\*\((?:Maintainers|Repo)\)/;

function withoutMaintainerNotes(body) {
  const lines = String(body || '').split('\n');
  const kept = [];
  let dropping = false;
  let removed = 0;
  for (const line of lines) {
    if (/^- /.test(line)) {
      dropping = MAINTAINER_BULLET.test(line);
      if (dropping) { removed++; continue; }
    } else if (dropping) {
      // A bullet runs until the next bullet or the next heading.
      if (/^#{2,3} /.test(line)) dropping = false;
      else continue;
    }
    kept.push(line);
  }

  // A subsection emptied of every bullet is a heading with nothing under it.
  const out = [];
  for (let i = 0; i < kept.length; i++) {
    if (/^### /.test(kept[i])) {
      let j = i + 1;
      while (j < kept.length && !/^#{2,3} /.test(kept[j]) && !/^- /.test(kept[j])) j++;
      if (j >= kept.length || /^#{2,3} /.test(kept[j])) { i = j - 1; continue; }
    }
    out.push(kept[i]);
  }
  return { text: out.join('\n').replace(/\n{3,}/g, '\n\n').trim(), removed };
}

/* ────────────────────────────────────────────────────────────────────────────
 * A RELATIVE LINK IS RELATIVE TO THE REPOSITORY IT IS READ IN.
 *
 * These notes are written in KhaytApp/Khayt's CHANGELOG.md, where
 * `[VERSIONING.md](./VERSIONING.md)` is correct, and they are PUBLISHED on a
 * release in KhaytApp/khayt-mac, where that path does not exist. Every Mac
 * alpha so far has shipped notes whose first line links to a 404 — checked:
 *
 *     https://github.com/KhaytApp/khayt-mac/blob/main/VERSIONING.md → 404
 *
 * Nobody reported it, which is what a dead link in release notes does: the
 * reader assumes they misread something and moves on.
 *
 * Rewritten here rather than in the changelog, because the changelog's own
 * reader is the repository the file lives in and the link is right for them.
 * ──────────────────────────────────────────────────────────────────────────── */

/** Where a relative link in the changelog actually points. */
const SOURCE_REPO = 'https://github.com/KhaytApp/Khayt/blob/main/';

/**
 * Make every relative markdown link absolute against the repository the
 * changelog lives in.
 *
 * Only relative ones: anything with a scheme, an anchor, or a protocol-relative
 * `//` is left exactly as written.
 *
 * @param {string} text  release notes
 * @returns {string}
 */
function withAbsoluteLinks(text) {
  return String(text || '').replace(/\]\(([^)\s]+)(\s+"[^"]*")?\)/g, (whole, target, title) => {
    if (/^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith('//') || target.startsWith('#')) {
      return whole;
    }
    const cleaned = target.replace(/^\.\//, '');
    return `](${SOURCE_REPO}${cleaned}${title || ''})`;
  });
}

module.exports = { sectionFor, fitForRelease, withoutMaintainerNotes, withAbsoluteLinks, GITHUB_BODY_LIMIT, DEFAULT_MAX_CHARS };

if (require.main === module) {
  const version = process.argv[2];
  if (!version) {
    console.error('usage: changelog-section.js <version>');
    process.exit(2);
  }
  const file = path.join(__dirname, '..', 'CHANGELOG.md');
  const body = sectionFor(fs.readFileSync(file, 'utf8'), version);
  if (!body) {
    console.error(`No CHANGELOG section for ${version}.`);
    console.error('A release with no notes cannot tell anyone what changed, and a release');
    console.error('carrying a "Before you update" section cannot ask them to agree to it.');
    process.exit(1);
  }
  const shopFacing = withoutMaintainerNotes(body);
  if (shopFacing.removed) {
    console.error(`changelog-section: ${version} — ${shopFacing.removed} maintainer-marked `
      + `entr${shopFacing.removed === 1 ? 'y' : 'ies'} lifted out of the release body `
      + `(${body.length} -> ${shopFacing.text.length} characters). They stay in CHANGELOG.md.`);
  }
  // Before the budget, so the longer absolute links are what gets measured.
  const fitted = fitForRelease(withAbsoluteLinks(shopFacing.text), { version });
  if (fitted.truncated) {
    // stderr, so the workflow log says so while stdout stays the notes.
    console.error(`changelog-section: ${version} is ${shopFacing.text.length} characters, over the `
      + `${DEFAULT_MAX_CHARS} budget — ${fitted.omitted} trimmed from the END, `
      + `with a link to the full changelog. The "Before you update" section is at the `
      + `top of an entry and is kept.`);
  }
  process.stdout.write(fitted.text + '\n');
}
