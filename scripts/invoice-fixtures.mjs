#!/usr/bin/env node
/**
 * Photograph the invoice, before it moves.
 *
 * `renderInvoice` is 425 lines of template string and is about to become
 * `lib/invoice-document.js`, so that something other than the Electron window
 * can produce a document. A wrong character in it is not a crash — it is a
 * customer's invoice with a missing VAT line, discovered by an auditor.
 *
 * So the HTML it produces TODAY is written down for a set of orders that
 * between them reach every branch, and the test asserts the lifted version
 * gives back the same bytes. Regenerate deliberately, never to make a test
 * pass: `node scripts/invoice-fixtures.mjs --write`.
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const { render } = require(join(ROOT, 'test/helpers/invoice-harness.js'));
const { CASES } = require(join(ROOT, 'test/helpers/invoice-cases.js'));

const write = process.argv.includes('--write');
const dir = join(ROOT, 'test/fixtures/invoices');
if (write) mkdirSync(dir, { recursive: true });

for (const { name, order, opts, money } of CASES) {
  const html = render(order, opts, money);
  if (write) {
    writeFileSync(join(dir, `${name}.html`), html);
    process.stdout.write(`wrote ${name}.html (${html.length} bytes)\n`);
  } else {
    process.stdout.write(`${name}: ${html.length} bytes\n`);
  }
}
