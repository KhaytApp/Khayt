#!/usr/bin/env node
/**
 * Build the Microsoft Store listing metadata that CI submits.
 *
 * Inputs:  store/microsoft/listing.json  — the copy, under version control
 *          CHANGELOG.md                  — becomes "What's new in this version"
 *          store/microsoft/baseline.json — OPTIONAL: the account's own submission
 *                                          JSON, from `msstore submission get`
 * Output:  store/microsoft/metadata.json — fed to `msstore submission updateMetadata`
 *
 * Why a baseline. Microsoft's documented flow is to fetch the current submission
 * JSON and edit it, because the exact shape belongs to the account and product,
 * not to the CLI — it is not a published schema. So this script does not invent a
 * shape: with a baseline present it copies it and overwrites only the fields we
 * own, leaving age ratings, pricing, markets and anything else untouched. Without
 * one it emits the flat listing object the CLI docs show, which is enough for the
 * first bootstrap run.
 *
 * Why the limits are checked here. Every one of these is a certification failure
 * if it is wrong, and certification failures are discovered hours later by a human
 * reading a rejection email. Failing the build on a 10,001-character description
 * costs seconds instead.
 *
 * Usage: node scripts/build-store-metadata.mjs [--version 3.6.0] [--check]
 *        --check validates and prints, without writing the output file.
 */
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
const storeDir = path.join(root, 'store', 'microsoft');

/** Store limits. Sources cited in docs/MICROSOFT-STORE.md. */
export const LIMITS = {
  description: 10_000,
  shortDescription: 255,
  whatsNew: 1_500,
  features: { count: 20, length: 200 },
  searchTerms: { count: 7, length: 40, totalWords: 21 },
  caption: 200,
  screenshots: 10,
  additionalSystemRequirements: 200,
  copyrightAndTrademark: 200,
  developedBy: 255,
};

/** Markdown → the plain text the Store actually renders. */
export function markdownToPlainText(md) {
  return String(md)
    .replace(/```[\s\S]*?```/g, '')              // fenced code
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')        // images
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')     // links → their text
    .replace(/^#{1,6}\s+/gm, '')                 // headings
    .replace(/^\s*[-*+]\s+/gm, '• ')             // bullets
    .replace(/\*\*([^*]+)\*\*/g, '$1')           // bold
    .replace(/(^|[^*])\*([^*\n]+)\*/g, '$1$2')   // italics
    .replace(/`([^`]+)`/g, '$1')                 // inline code
    .replace(/[ \t]+$/gm, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/**
 * Pull one version's section out of the CHANGELOG.
 * Headings look like: `## [3.6.0-rc.1] - 2026-08-12`.
 */
export function changelogSection(changelog, version) {
  const lines = String(changelog).split('\n');
  const isHeading = (l) => /^##\s+\[/.test(l);
  const start = lines.findIndex((l) => isHeading(l) && l.includes(`[${version}]`));
  if (start === -1) return null;
  const rest = lines.slice(start + 1);
  const end = rest.findIndex(isHeading);
  return rest.slice(0, end === -1 ? rest.length : end).join('\n').trim() || null;
}

/**
 * Turn a changelog section into a "What's new" blurb inside the Store's limit.
 * Truncating mid-sentence reads like a bug, so this drops whole paragraphs and
 * then whole sentences, and always leaves a pointer to the full notes.
 */
export function buildWhatsNew(section, version, { limit = LIMITS.whatsNew } = {}) {
  const pointer = `\n\nFull release notes: https://github.com/khaytapp/Khayt/releases/tag/v${version}`;
  const body = markdownToPlainText(section || '');
  if (!body) return `Maintenance and stability improvements.${pointer}`.trim();
  if (body.length + pointer.length <= limit) return body + pointer;

  const budget = limit - pointer.length;
  const paragraphs = body.split('\n\n');
  let out = '';
  for (const p of paragraphs) {
    if ((out ? out.length + 2 : 0) + p.length > budget) break;
    out = out ? `${out}\n\n${p}` : p;
  }
  if (!out) {
    // A single paragraph longer than the budget — fall back to whole sentences.
    for (const s of paragraphs[0].split(/(?<=[.!?])\s+/)) {
      if ((out ? out.length + 1 : 0) + s.length > budget) break;
      out = out ? `${out} ${s}` : s;
    }
  }
  if (!out) out = paragraphs[0].slice(0, budget - 1).trimEnd() + '…';
  return out + pointer;
}

const countWords = (s) => String(s).trim().split(/\s+/).filter(Boolean).length;

/** Every Store limit, checked. Returns a list of human-readable problems. */
export function validateListing(listing, whatsNew, { screenshotDir } = {}) {
  const problems = [];
  const tooLong = (label, value, max) => {
    const n = String(value ?? '').length;
    if (n > max) problems.push(`${label} is ${n} characters, limit is ${max} (over by ${n - max})`);
  };
  const required = (label, value) => {
    if (!String(value ?? '').trim()) problems.push(`${label} is required and is empty`);
  };

  required('description', listing.description);
  tooLong('description', listing.description, LIMITS.description);
  tooLong('shortDescription', listing.shortDescription, LIMITS.shortDescription);
  tooLong("what's new", whatsNew, LIMITS.whatsNew);
  tooLong('additionalSystemRequirements', listing.additionalSystemRequirements, LIMITS.additionalSystemRequirements);
  tooLong('copyrightAndTrademark', listing.copyrightAndTrademark, LIMITS.copyrightAndTrademark);
  tooLong('developedBy', listing.developedBy, LIMITS.developedBy);

  const features = listing.features || [];
  if (features.length > LIMITS.features.count) {
    problems.push(`${features.length} features, limit is ${LIMITS.features.count}`);
  }
  features.forEach((f, i) => tooLong(`feature ${i + 1} ("${String(f).slice(0, 30)}…")`, f, LIMITS.features.length));

  const terms = listing.searchTerms || [];
  if (terms.length > LIMITS.searchTerms.count) {
    problems.push(`${terms.length} search terms, limit is ${LIMITS.searchTerms.count}`);
  }
  terms.forEach((s, i) => tooLong(`search term ${i + 1} ("${s}")`, s, LIMITS.searchTerms.length));
  const words = terms.reduce((n, s) => n + countWords(s), 0);
  if (words > LIMITS.searchTerms.totalWords) {
    problems.push(`search terms use ${words} words across all terms, limit is ${LIMITS.searchTerms.totalWords}`);
  }

  const shots = listing.screenshots || [];
  if (!shots.length) problems.push('at least one screenshot is required');
  if (shots.length > LIMITS.screenshots) {
    problems.push(`${shots.length} screenshots, limit is ${LIMITS.screenshots}`);
  }
  shots.forEach((s, i) => {
    tooLong(`screenshot ${i + 1} caption`, s.caption, LIMITS.caption);
    if (screenshotDir && !fs.existsSync(path.join(screenshotDir, s.file))) {
      problems.push(`screenshot file is missing: ${s.file} (run npm run capture:store-screenshots)`);
    }
  });

  return problems;
}

/**
 * Overwrite only the fields we own, wherever they live in the baseline.
 *
 * The baseline's shape is the account's, so this walks it and replaces keys by
 * name rather than assuming a path. Keys we do not own — age ratings, pricing,
 * markets, certification notes — are copied through untouched, which is what
 * keeps an automated metadata update from resetting something nobody meant to
 * touch.
 */
export function mergeIntoBaseline(baseline, fields) {
  const owned = new Set(Object.keys(fields));
  let replaced = 0;
  const walk = (node) => {
    if (Array.isArray(node)) return node.map(walk);
    if (node && typeof node === 'object') {
      const out = {};
      for (const [k, v] of Object.entries(node)) {
        if (owned.has(k)) { out[k] = fields[k]; replaced++; }
        else out[k] = walk(v);
      }
      return out;
    }
    return node;
  };
  const merged = walk(structuredClone(baseline));
  return { merged, replaced };
}

/**
 * A paste-ready sheet for updating the listing by hand in Partner Center.
 *
 * Khayt's Store account is an individual developer account, which cannot
 * associate a Microsoft Entra tenant — so the submission API is unavailable and
 * the listing is updated through the web UI. This turns that into copy-and-paste
 * from one validated document instead of retyping prose into a form, which is
 * where wrong and stale listing copy comes from.
 */
export function manualChecklist(listing, whatsNew, version) {
  const field = (label, value, limit) =>
    `### ${label}\n\n_${String(value).length} / ${limit} characters_\n\n\`\`\`\n${value}\n\`\`\`\n`;

  return `# Partner Center — paste sheet for v${version}

Generated by \`npm run store:manual\`. Do not edit this file: edit
\`store/microsoft/listing.json\` and regenerate, so the repo stays the source of truth.

Partner Center → your app → **Store listings** → **English (United States)**.
Every value below is already validated against the Store's limits.

---

${field("Description", listing.description, LIMITS.description)}
${field("What's new in this version", whatsNew, LIMITS.whatsNew)}
${field("Short description", listing.shortDescription, LIMITS.shortDescription)}
### Product features

_${listing.features.length} / ${LIMITS.features.count} — one per box_

${listing.features.map((f) => `- ${f}`).join('\n')}

### Search terms

_${listing.searchTerms.length} / ${LIMITS.searchTerms.count} — one per box_

${listing.searchTerms.map((s) => `- ${s}`).join('\n')}

${field("Additional system requirements", listing.additionalSystemRequirements, LIMITS.additionalSystemRequirements)}
${field("Copyright and trademark info", listing.copyrightAndTrademark, LIMITS.copyrightAndTrademark)}
### Screenshots

Upload from \`store/microsoft/screenshots/\`, in this order. Regenerate them with
\`npm run capture:store-screenshots\` whenever the UI changes — they are validated
against the Store's requirements (PNG, at least 1366x768, at most 50 MB) on capture.

| # | File | Caption |
|---|---|---|
${listing.screenshots.map((s, i) => `| ${i + 1} | \`${s.file}\` | ${s.caption} |`).join('\n')}

### Package

Download the \`windows-store-msix\` artifact from the **Build & Release** run for
\`v${version}\` and upload the \`.appx\` under **Packages**. The artifact is kept for
90 days.

**Do not re-run a completed Build & Release to regenerate it** — that forks the release
into a duplicate draft and breaks the published update manifests. If it has expired, cut
a new tag instead.
`;
}

function main(argv) {
  const arg = (name) => {
    const i = argv.indexOf(name);
    return i === -1 ? null : argv[i + 1];
  };
  const checkOnly = argv.includes('--check');
  const manual = argv.includes('--manual');
  const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  const version = arg('--version') || pkg.version;

  const listingPath = path.join(storeDir, 'listing.json');
  if (!fs.existsSync(listingPath)) {
    console.error(`Missing ${path.relative(root, listingPath)}`);
    return 1;
  }
  const listing = JSON.parse(fs.readFileSync(listingPath, 'utf8'));

  const changelog = fs.readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8');
  const section = changelogSection(changelog, version);
  if (!section) {
    console.warn(`! No CHANGELOG section for ${version} — "What's new" falls back to a generic line.`);
  }
  const whatsNew = buildWhatsNew(section, version);

  const screenshotDir = path.join(storeDir, 'screenshots');
  const problems = validateListing(listing, whatsNew, {
    screenshotDir: fs.existsSync(screenshotDir) ? screenshotDir : null,
  });
  if (problems.length) {
    console.error(`\nStore listing would be rejected — ${problems.length} problem(s):\n`);
    for (const p of problems) console.error(`  ✖ ${p}`);
    console.error('\nFix store/microsoft/listing.json and run again.\n');
    return 1;
  }

  if (manual) {
    const outPath = path.join(storeDir, 'partner-center.md');
    fs.writeFileSync(outPath, manualChecklist(listing, whatsNew, version));
    console.log(`\nWrote ${path.relative(root, outPath)} — paste sheet for the Partner Center UI.`);
    return 0;
  }

  const fields = {
    description: listing.description,
    shortDescription: listing.shortDescription,
    releaseNotes: whatsNew,
    features: listing.features,
    searchTerms: listing.searchTerms,
    additionalSystemRequirements: listing.additionalSystemRequirements,
    copyrightAndTrademark: listing.copyrightAndTrademark,
    developedBy: listing.developedBy,
  };

  const baselinePath = path.join(storeDir, 'baseline.json');
  let out;
  if (fs.existsSync(baselinePath)) {
    const baseline = JSON.parse(fs.readFileSync(baselinePath, 'utf8'));
    const { merged, replaced } = mergeIntoBaseline(baseline, fields);
    if (replaced === 0) {
      console.error('\nThe baseline contains none of the fields this script owns.');
      console.error('That means the shape changed. Re-run the bootstrap workflow to refresh');
      console.error('store/microsoft/baseline.json, and check docs/MICROSOFT-STORE.md.\n');
      return 1;
    }
    out = merged;
    console.log(`Merged ${replaced} field(s) into the account's baseline submission JSON.`);
  } else {
    out = { ...fields, language: listing.language || 'en-us' };
    console.log('No baseline.json — emitting a flat listing object (bootstrap mode).');
    console.log('Run the "Store bootstrap" workflow once to capture the real shape.');
  }

  console.log(`\nversion            ${version}`);
  console.log(`description        ${listing.description.length} / ${LIMITS.description}`);
  console.log(`shortDescription   ${listing.shortDescription.length} / ${LIMITS.shortDescription}`);
  console.log(`what's new         ${whatsNew.length} / ${LIMITS.whatsNew}${section ? '' : '  (generic — no changelog section)'}`);
  console.log(`features           ${listing.features.length} / ${LIMITS.features.count}`);
  console.log(`searchTerms        ${listing.searchTerms.length} / ${LIMITS.searchTerms.count}  (${listing.searchTerms.reduce((n, s) => n + countWords(s), 0)} / ${LIMITS.searchTerms.totalWords} words)`);
  console.log(`screenshots        ${listing.screenshots.length} / ${LIMITS.screenshots}`);

  if (checkOnly) {
    console.log('\n--check: valid, nothing written.');
    return 0;
  }
  const outPath = path.join(storeDir, 'metadata.json');
  fs.mkdirSync(storeDir, { recursive: true });
  fs.writeFileSync(outPath, `${JSON.stringify(out, null, 2)}\n`);
  console.log(`\nWrote ${path.relative(root, outPath)}`);
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exit(main(process.argv.slice(2)));
}
