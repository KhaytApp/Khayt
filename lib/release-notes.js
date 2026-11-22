'use strict';

const DEFAULT_RELEASES_URL = 'https://github.com/khaytapp/Khayt/releases/latest';

/** Strip scripts and inline handlers from updater/GitHub release HTML. */
function sanitizeReleaseNotesHtml(html) {
  return String(html || '')
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/\s+on\w+\s*=\s*(".*?"|'.*?'|[^\s>]+)/gi, '')
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

  if (/<[a-z][\s\S]*>/i.test(raw)) {
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
