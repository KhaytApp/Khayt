'use strict';
/**
 * The changes a person has to agree to before an update is allowed to happen.
 *
 * ── WHY THIS EXISTS ────────────────────────────────────────────────────────
 * Khayt is a shop's working tool. A release that moves the controls somebody
 * uses fifty times a day costs them their muscle memory in the middle of a job,
 * and until now they had no say in it: the update prompt asked "install?" and
 * the answer to "install what?" was, literally, "Release notes were not included
 * with this update."
 *
 * So a release may declare the changes that will surprise someone, and when it
 * does, the update is GATED on their acceptance rather than merely annotated
 * with it. Accepting is the thing that unlocks the download.
 *
 * ── WHY THE GATE IS ON THE DOWNLOAD ────────────────────────────────────────
 * `autoInstallOnAppQuit` is true, so a downloaded update installs when the app
 * next quits whether or not anyone pressed anything. A gate on the INSTALL
 * button would therefore be no gate at all — the update would land on the next
 * quit regardless. `autoDownload` is false, so the download is the last moment
 * at which "no" still means no. See lib/updater.js.
 *
 * ── HOW A RELEASE DECLARES ONE ─────────────────────────────────────────────
 * A `### Before you update` section in that version's CHANGELOG entry, which
 * scripts/changelog-section.js carries into the GitHub release body and from
 * there into the updater's release notes:
 *
 *     ## [3.8.0] - 2026-09-09
 *
 *     ### Before you update
 *
 *     - The buttons on a print file have moved into a ··· menu.
 *
 *     ### Fixed
 *     …
 *
 * No section means no gate: an ordinary release still prompts, still shows its
 * notes, and installs on one press. **The absence of the section is the normal
 * case and must stay cheap** — a gate that appears on every release is a gate
 * everyone learns to click through without reading.
 *
 * Pure: no DOM, no fs, no Electron. Takes text, returns a verdict.
 */
(function (global) {

  /** The heading that turns a release into one somebody has to agree to. */
  const HEADING = 'Before you update';

  /**
   * Whether notes are HTML: a `<` followed by a letter, with a `>` somewhere
   * after it, exactly what `/<[a-z][\s\S]*>/i` answered. That regex re-scanned
   * to the end from every `<letter`, so `<a` × n with no `>` took quadratic
   * time on text the release feed controls (4.11.0 release review, LOW-2).
   * This finds the last `>` once and walks the `<`s before it: linear.
   * lib/updater.js notesSince asks the same question with it.
   */
  function looksLikeHtml(s) {
    const text = String(s == null ? '' : s);
    const last = text.lastIndexOf('>');
    if (last < 0) return false;
    for (let i = text.indexOf('<'); i >= 0 && i < last; i = text.indexOf('<', i + 1)) {
      const c = text.charCodeAt(i + 1) | 32;
      if (c >= 97 && c <= 122) return true;
    }
    return false;
  }

  /* A `<script>`/`<style>` block, open tag to the next close, goes whole: what
   * `/<script[\s\S]*?<\/script>/gi` did, without re-scanning to the end from
   * every opener that has no closer after it (4.11.0 release review, LOW-2).
   * lib/release-notes.js sanitizes the update dialog's HTML with it too. */
  const dropBlocks = (text, tag) => {
    const open = new RegExp('<' + tag, 'gi');
    const close = new RegExp('</' + tag + '>', 'gi');
    let out = '';
    let from = 0;
    for (;;) {
      open.lastIndex = from;
      const o = open.exec(text);
      if (!o) break;
      close.lastIndex = o.index + o[0].length;
      const c = close.exec(text);
      if (!c) break;                       // no closer after this opener, nor after any later one
      out += text.slice(from, o.index);
      from = c.index + c[0].length;
    }
    return out + text.slice(from);
  };

  // `[^<>]` rather than `[^>]` in the tag patterns: one scan per `<`, not one
  // to the end of the notes (`<li` × n with no `>` took minutes; LOW-2).
  const stripKnownTags = (s) => dropBlocks(dropBlocks(String(s || ''), 'script'), 'style')
    /* A heading has to survive as a HEADING, not as a bare line of text.
     * Without this the list below "Before you update" ran straight on through
     * "Fixed" and everything after it — the section boundary vanished with the
     * tag, so a shop was asked to agree to the whole release. Caught by the
     * test, which is the only reason this line exists. */
    .replace(/<h[1-6]\b[^<>]*>/gi, '\n### ')
    .replace(/<li\b[^<>]*>/gi, '\n- ')
    .replace(/<\/(p|div|h[1-6]|ul|ol|li)>/gi, '\n')
    .replace(/<br\s*\/?>/gi, '\n');
  /* Every other tag goes: what `.replace(/<[^>]+>/g, '')` did, a `<`, at least
   * one character, and the next `>`. That regex re-scanned to the end from
   * every `<` with no `>` after it: 20 KB of `<p>x</p>` then `<a` × n took six
   * seconds (4.11.0 release review, LOW-2). One indexOf walk instead. */
  const stripTags = (s) => {
    const text = stripKnownTags(s);
    let out = '';
    let from = 0;
    for (let i = text.indexOf('<'); i >= 0; ) {
      const j = text.indexOf('>', i + 1);
      if (j < 0) break;                                   // no `>` after any later `<` either
      if (j === i + 1) { i = text.indexOf('<', i + 1); continue; }   // `<>` is not a tag
      out += text.slice(from, i);
      from = j + 1;
      i = text.indexOf('<', from);
    }
    return out + text.slice(from);
  };

  const decode = (s) => String(s || '')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#(\d+);/g, (_, d) => String.fromCharCode(+d))
    .replace(/&amp;/g, '&');   // last, or &amp;lt; becomes "<"

  /** Markdown emphasis carries no meaning once this is a list in a dialog. */
  const plain = (s) => String(s || '')
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/(^|\W)\*(\S[^*]*?)\*(?=\W|$)/g, '$1$2')
    .replace(/`([^`]+)`/g, '$1')
    // `[^\][]` and `[^()]`: a scan per bracket, not to the end of the item from
    // every `[` (`[` × n took half a minute; LOW-2).
    .replace(/\[([^\][]+)\]\([^()]*\)/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();

  /**
   * Read a release's notes and say whether they demand consent.
   *
   * @param {string} notes  release notes, markdown or HTML
   * @returns {{needsConsent: boolean, items: string[]}}
   *   `items` is one plain sentence per change. `needsConsent` is true only when
   *   the section exists AND lists something: an empty section is a drafting
   *   mistake, and blocking an update on a heading with nothing under it would
   *   ask somebody to accept the unstated.
   */
  function parseMajorChanges(notes) {
    const text = decode(looksLikeHtml(String(notes || '')) ? stripTags(notes) : notes);
    if (!text.trim()) return { needsConsent: false, items: [] };

    const lines = text.split(/\r?\n/);
    const isHeading = (l) => /^\s*#{1,6}\s+\S/.test(l);
    const headingText = (l) => l.replace(/^\s*#{1,6}\s+/, '').trim();

    let i = lines.findIndex((l) => isHeading(l)
      && headingText(l).toLowerCase().replace(/[:.]+$/, '') === HEADING.toLowerCase());
    // GitHub's own rendering can drop the heading markers, so a bare line
    // carrying only the phrase counts too. Anchored, so a sentence that merely
    // mentions it in passing does not.
    if (i === -1) {
      i = lines.findIndex((l) => l.trim().replace(/[:.*_]+$/g, '').replace(/^[*_]+/, '').toLowerCase() === HEADING.toLowerCase());
    }
    if (i === -1) return { needsConsent: false, items: [] };

    const items = [];
    for (let j = i + 1; j < lines.length; j++) {
      const line = lines[j];
      if (isHeading(line)) break;
      /* An EMPTY bullet still opens an item.
       *
       * stripTags turns `<li>` into "\n- ", and GitHub puts the content on the
       * line after it — so the marker arrives alone and `[-*•]\s+(.+)` matched
       * nothing, leaving the text below with no item to attach to. Opening an
       * empty item here is what lets the continuation rule below fill it. */
      const bullet = line.match(/^\s*[-*•]\s*(.*)$/);
      if (bullet) { items.push(bullet[1]); continue; }
      /* A WRAPPED CONTINUATION BELONGS TO THE BULLET ABOVE IT.
       *
       * This required two leading spaces — the indentation a CHANGELOG has and a
       * RENDERED PAGE does not. And rendered is what production sends:
       * electron-updater reads the release atom feed, which carries GitHub's
       * HTML, so stripTags runs and every continuation arrives at column 0.
       *
       * The effect was not a truncated sentence. `<li>` becomes "\n- " and the
       * text after the first line becomes bare lines matching nothing, so a
       * multi-line item was DROPPED — and a section whose items are all
       * multi-line, which is what CHANGELOG.md holds today, parsed to zero
       * items and `needsConsent: false`. The gate would simply not have appeared
       * on the next release.
       *
       * A blank line still ends an item, so two separate bullets never merge;
       * anything else after a bullet, at any indentation, continues it. */
      if (items.length && line.trim()) {
        items[items.length - 1] += ' ' + line;
      }
    }
    // Each item is made plain ONCE, when it is whole: re-running `plain` on the
    // growing item at every continuation line was quadratic in the section's
    // length (4.11.0 release review, LOW-2).
    // An item that never gained any text is a stray marker, not a change.
    const real = items.map(plain).filter((x) => x && x.trim());
    return { needsConsent: real.length > 0, items: real };
  }

  const api = { parseMajorChanges, looksLikeHtml, dropBlocks, HEADING };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytMajorChanges = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
