#!/usr/bin/env node
'use strict';
/**
 * The Sparkle appcast for the native Mac app.
 *
 * Sparkle decides whether to offer an update by reading this feed, so it is the
 * one file that has to be right for an install to ever move. Written by a
 * script with tests rather than by a heredoc in a workflow, because the two
 * fields most likely to be wrong are silent when they are:
 *
 *   sparkle:version          MUST be CFBundleVersion — the integer build, not
 *                            the marketing string. Sparkle compares THIS.
 *                            A feed carrying "4.0.0-alpha.2" here against an
 *                            app whose CFBundleVersion is "2" compares a
 *                            string to a number and offers nothing, forever.
 *   sparkle:edSignature      the EdDSA signature of the archive. Wrong or
 *                            missing and Sparkle refuses the update AFTER
 *                            downloading it, which reads to a shop as "the
 *                            update is broken" rather than "the feed is".
 *
 * `length` is the archive's byte count and Sparkle checks it. Taken from the
 * file rather than passed in, so it cannot disagree with what was uploaded.
 *
 * THE RELEASE NOTES ARE IN THE FEED, NOT BEHIND A LINK (Nov 2026). The feed
 * is signed after this writes it (`sign_update`, in the publish workflows;
 * checked by scripts/mac-appcast-verify.js). Once the app REQUIRES a signed
 * feed, Sparkle also requires notes it fetches from a link to be signed, and
 * the link used to be a GitHub release page, which nobody but GitHub writes.
 * Notes inside `<description>` are covered by the feed's own signature. The
 * page stays as `sparkle:fullReleaseNotesLink` ("Version History"), which
 * Sparkle opens in the browser and does not load into the update window.
 *
 * NOTHING AFTER THIS MAY REWRITE THE FILE. The signature covers its bytes: a
 * formatter, a trailing newline, an editor that re-saves it, and no Mac that
 * requires a signed feed will take it.
 *
 *   node scripts/mac-appcast.js --archive <zip> --signature <sig> \
 *        --url <download-url> [--notes-file <md>] [--notes-url <url>] [--out appcast.xml]
 */
const fs = require('fs');
const path = require('path');

/** XML text, with the five characters that would otherwise end the document. */
function xml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

/** The most notes a feed carries. A promotion's whole CHANGELOG section can be
 * 150,000 characters; the update window is not where that is read. */
const NOTES_MAX = 40000;

/**
 * Markdown inside CDATA. Two sequences are split across CDATA sections, which
 * a parser joins back into the same text:
 *   `]]>`  would end the section early.
 *   `<!-- sparkle-signatures:`  is the marker of the signature block.
 *     `sign_update` looks for the LAST one in the file before it signs
 *     (SPUExtractAppcastContent), so notes that quote it would have the feed
 *     cut off at that point and signed short. The cut is caught (the check
 *     finds no enclosure) but it stops the release; splitting it means the
 *     marker never appears in the file's bytes outside the real block.
 */
function cdata(s) {
  return `<![CDATA[${String(s)
    .replace(/]]>/g, ']]]]><![CDATA[>')
    .replace(/<!-- sparkle-signatures:/g, '<!-]]><![CDATA[- sparkle-signatures:')}]]>`;
}

/** Characters XML 1.0 does not allow anywhere, CDATA included: the C0 controls
 * but tab, newline and return, and U+FFFE/U+FFFF. One of them (an ESC from
 * pasted terminal colours, a form feed) in a CHANGELOG entry makes a feed
 * that signs and verifies and that no Mac can parse. */
const XML_ILLEGAL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g;

/** The notes, whole or cut at a line with a pointer to the rest. */
function fitNotes(notes, notesUrl) {
  const text = String(notes == null ? '' : notes).replace(/\r\n?/g, '\n').replace(XML_ILLEGAL, '').trim();
  if (text.length <= NOTES_MAX) return text;
  const cut = text.slice(0, NOTES_MAX);
  const at = cut.lastIndexOf('\n');
  return `${cut.slice(0, at > 0 ? at : NOTES_MAX).trimEnd()}\n\n…${notesUrl ? `\n\nThe rest is in the full release notes: ${notesUrl}` : ''}`;
}

/**
 * One release's feed.
 *
 * A single item, deliberately. Sparkle only needs the newest an install could
 * move to, and a feed that accumulates every alpha ever cut is a feed where a
 * mistake in an old entry can still be chosen.
 */
function appcast({ version, build, archiveBytes, signature, url, minimumSystemVersion,
                   title = 'Khayt for macOS', notes = null, notesUrl = null, pubDate = new Date() }) {
  if (!version) throw new Error('appcast: version is required');
  if (!Number.isInteger(build) || build < 1) {
    throw new Error(`appcast: build must be a positive integer, got ${build}`);
  }
  if (!Number.isInteger(archiveBytes) || archiveBytes < 1) {
    throw new Error(`appcast: archive length must be a positive integer, got ${archiveBytes}`);
  }
  if (!signature) throw new Error('appcast: an EdDSA signature is required — an unsigned feed installs nothing');
  if (!/^https:\/\//.test(String(url || ''))) {
    throw new Error(`appcast: the download URL must be https, got "${url}"`);
  }

  if (notesUrl != null && !/^https:\/\//.test(String(notesUrl))) {
    throw new Error(`appcast: the notes URL must be https, got "${notesUrl}"`);
  }
  // Never `sparkle:releaseNotesLink`: see the header. The notes ride inside
  // the feed, as markdown (Sparkle shows it as plain text where it cannot
  // render it), and the page is the "Version History" link, which Sparkle
  // offers on its "you're up to date" alert.
  const body = fitNotes(notes, notesUrl);
  const inline = body
    ? `      <description sparkle:format="markdown">${cdata(body)}</description>\n`
    : '';
  const history = notesUrl
    ? `      <sparkle:fullReleaseNotesLink>${xml(notesUrl)}</sparkle:fullReleaseNotesLink>\n`
    : '';

  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${xml(title)}</title>
    <description>Updates for the native Khayt Mac app.</description>
    <language>en</language>
    <item>
      <title>${xml(version)}</title>
      <pubDate>${new Date(pubDate).toUTCString()}</pubDate>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${xml(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${xml(minimumSystemVersion || '26.0')}</sparkle:minimumSystemVersion>
${inline}${history}      <enclosure url="${xml(url)}"
                 length="${archiveBytes}"
                 type="application/octet-stream"
                 sparkle:edSignature="${xml(signature)}" />
    </item>
  </channel>
</rss>
`;
}

module.exports = { appcast, xml, cdata, fitNotes, NOTES_MAX, XML_ILLEGAL };

if (require.main === module) {
  const args = {};
  for (let i = 2; i < process.argv.length; i += 2) {
    args[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
  }
  const v = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'mac', 'version.json'), 'utf8'));
  if (!args.archive || !fs.existsSync(args.archive)) {
    console.error(`--archive must point at the built zip (got "${args.archive}")`);
    process.exit(2);
  }
  const out = appcast({
    version: v.version,
    build: v.build,
    archiveBytes: fs.statSync(args.archive).size,
    signature: args.signature,
    url: args.url,
    // A file that is missing or empty is "no notes", not a failed release:
    // the feed must still be written and signed.
    notes: args['notes-file'] && fs.existsSync(args['notes-file']) ? fs.readFileSync(args['notes-file'], 'utf8') : null,
    notesUrl: args['notes-url'] || null,
  });
  if (args.out) { fs.writeFileSync(args.out, out); console.error(`wrote ${args.out}`); }
  else process.stdout.write(out);
}
