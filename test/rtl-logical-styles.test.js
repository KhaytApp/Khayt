'use strict';
/**
 * The window runs in Arabic as well as English, so an inline style in the
 * renderer says START and END, never left and right: `text-align:start`,
 * `margin-inline-start`, `padding-inline-end`, `border-inline-start`,
 * `float:inline-end`. A physical side stays where it is when the page turns
 * right-to-left, and a name column hugging the wrong edge is what Arabic
 * shops saw in Analytics (about 70 of these, Nov 2026).
 *
 * A ratchet at zero: a new physical side fails here with its file and line.
 * Positioning (`left:`/`right:` for a popover) is not covered — it is not
 * always a reading direction.
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const RENDERER = path.join(__dirname, '..', 'renderer');
const PHYSICAL = /(text-align:\s*(left|right)\b|\b(margin|padding|border)-(left|right)\s*:|float:\s*(left|right)\b)/;

test('renderer inline styles use logical sides, not left and right', () => {
  const hits = [];
  for (const name of fs.readdirSync(RENDERER)) {
    if (!name.endsWith('.js')) continue;
    const lines = fs.readFileSync(path.join(RENDERER, name), 'utf8').split('\n');
    lines.forEach((line, i) => { if (PHYSICAL.test(line)) hits.push(`${name}:${i + 1}  ${line.trim().slice(0, 120)}`); });
  }
  assert.deepEqual(hits, [], 'use start/end and inline-start/inline-end:\n' + hits.join('\n'));
});
