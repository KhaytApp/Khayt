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
 *   node scripts/mac-appcast.js --archive <zip> --signature <sig> \
 *        --url <download-url> [--notes-url <url>] [--out appcast.xml]
 */
const fs = require('fs');
const path = require('path');

/** XML text, with the five characters that would otherwise end the document. */
function xml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

/**
 * One release's feed.
 *
 * A single item, deliberately. Sparkle only needs the newest an install could
 * move to, and a feed that accumulates every alpha ever cut is a feed where a
 * mistake in an old entry can still be chosen.
 */
function appcast({ version, build, archiveBytes, signature, url, minimumSystemVersion,
                   title = 'Khayt for macOS', notesUrl = null, pubDate = new Date() }) {
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

  const notes = notesUrl
    ? `      <sparkle:releaseNotesLink>${xml(notesUrl)}</sparkle:releaseNotesLink>\n`
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
${notes}      <enclosure url="${xml(url)}"
                 length="${archiveBytes}"
                 type="application/octet-stream"
                 sparkle:edSignature="${xml(signature)}" />
    </item>
  </channel>
</rss>
`;
}

module.exports = { appcast, xml };

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
    notesUrl: args['notes-url'] || null,
  });
  if (args.out) { fs.writeFileSync(args.out, out); console.error(`wrote ${args.out}`); }
  else process.stdout.write(out);
}
