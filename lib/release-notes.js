'use strict';

// Both linear: the regexes they replace re-scanned to the end of the notes from
// every `<letter` / `<script` with no `>` / closer after it, so a crafted feed
// held the main process for seconds (4.11.0 release review, LOW-2).
const { looksLikeHtml, dropBlocks } = require('./major-changes');

const DEFAULT_RELEASES_URL = 'https://github.com/khaytapp/Khayt/releases/latest';

/** Strip scripts and inline handlers from updater/GitHub release HTML. */
//
// The handler pattern is anchored on ONE character before `on` and its quoted
// values are bounded: `\s+on…` backtracked through every split of a long run of
// whitespace (200 KB of spaces held main for ~28 s, security review of #2602),
// and an unbounded `".*?"` re-scanned to the end for every unclosed quote. A
// handler longer than the bound loses its name and `=` all the same, so what
// is left is inert text, never a handler.
const HANDLER = /(^|[\s"'\/])on\w+\s*=\s*("[^"]{0,4096}"|'[^']{0,4096}'|[^\s>]+)/gi;
function sanitizeReleaseNotesHtml(html) {
  return dropBlocks(String(html || ''), 'script')
    .replace(HANDLER, (_m, before) => (/\s/.test(before) ? '' : before))
    .replace(/javascript\s*:/gi, '');
}

/**
 * Convert plain-text or markdown-ish release notes into safe HTML.
 * Preserves existing HTML when the input already contains tags.
 * @param {string} text
 */
function formatReleaseNotesText(text) {
  const raw = String(text || '').trim();
  if (!raw) return '';

  if (looksLikeHtml(raw)) {
    return sanitizeReleaseNotesHtml(raw);
  }

  const lines = raw.split(/\r?\n/);
  const blocks = [];
  let listItems = [];

  const flushList = () => {
    if (!listItems.length) return;
    blocks.push(`<ul class="update-notes-list">${listItems.join('')}</ul>`);
    listItems = [];
  };

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) {
      flushList();
      continue;
    }

    const heading = trimmed.match(/^#{1,6}\s+(.+)$/);
    if (heading) {
      flushList();
      blocks.push(`<h4 class="update-notes-heading">${escapeHtml(heading[1])}</h4>`);
      continue;
    }

    const bullet = trimmed.match(/^[-*•]\s+(.+)$/);
    if (bullet) {
      listItems.push(`<li>${escapeHtml(bullet[1])}</li>`);
      continue;
    }

    flushList();
    blocks.push(`<p class="update-notes-paragraph">${escapeHtml(trimmed)}</p>`);
  }

  flushList();
  return blocks.join('\n');
}

/** @param {string} s */
function escapeHtml(s) {
  return String(s || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/**
 * @param {string | undefined | null} releaseNotes
 * @param {{ version?: string, releaseDate?: string, releasesUrl?: string }} [opts]
 */
function formatReleaseNotesForDisplay(releaseNotes, opts = {}) {
  const version = opts.version ? String(opts.version) : '';
  const releasesUrl = opts.releasesUrl || DEFAULT_RELEASES_URL;
  const body = formatReleaseNotesText(releaseNotes);

  if (body) {
    return {
      html: body,
      hasContent: true,
    };
  }

  const versionLabel = version ? `Khayt ${version}` : 'This release';
  const dateSuffix = opts.releaseDate
    ? ` (${new Date(opts.releaseDate).toLocaleDateString()})`
    : '';

  return {
    html:
      `<p class="update-notes-paragraph">${escapeHtml(versionLabel)}${escapeHtml(dateSuffix)} is ready to install.</p>` +
      `<p class="update-notes-paragraph">Release notes were not included with the update package. ` +
      `<a href="${escapeHtml(releasesUrl)}" target="_blank" rel="noopener">View changes on GitHub</a>.</p>`,
    hasContent: false,
  };
}

module.exports = {
  sanitizeReleaseNotesHtml,
  formatReleaseNotesText,
  formatReleaseNotesForDisplay,
  escapeHtml,
};
