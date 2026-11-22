'use strict';

/**
 * Strip scripts/iframes and inline handlers before writing or serving HTML.
 *
 * SECURITY: this is a regex scrubber and therefore DEFENSE-IN-DEPTH ONLY — it is
 * bypassable in the general case (malformed tags, exotic encodings) and MUST NOT
 * be treated as the primary XSS control. Every value interpolated into exported/
 * served HTML must already be escaped at the embed site (escapeHtml / lanEscapeHtml
 * / scriptSafeJson). Do not start relying on this function to make untrusted input
 * safe.
 */
function sanitizeHtmlForFile(html) {
  return String(html || '')
    .replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, '')
    .replace(/<script\b[^>]*/gi, '')
    .replace(/<iframe\b[^>]*>[\s\S]*?<\/iframe\s*>/gi, '')
    .replace(/<iframe\b[^>]*/gi, '')
    .replace(/\bon\w+\s*=/gi, 'data-removed=')
    .replace(/\bhref\s*=\s*["']?\s*javascript:/gi, 'href="blocked:');
}

/** Remove legacy client-name row from exported status pages (privacy). */
function redactStatusHtmlClientRow(html) {
  return String(html || '').replace(
    /<div class="info-row">\s*<span class="info-label">Client<\/span>[\s\S]*?<\/div>/gi,
    '',
  );
}

function prepareStatusHtmlForServe(html) {
  return sanitizeHtmlForFile(redactStatusHtmlClientRow(html));
}

/** Exported interactive pages (surveys): block javascript: URLs only. */
function prepareInteractiveHtmlForFile(html) {
  return String(html || '').replace(/\bhref\s*=\s*["']?\s*javascript:/gi, 'href="blocked:');
}

module.exports = {
  sanitizeHtmlForFile,
  redactStatusHtmlClientRow,
  prepareStatusHtmlForServe,
  prepareInteractiveHtmlForFile,
};
