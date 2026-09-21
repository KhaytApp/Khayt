'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { wouldWarn, oneLine, NAMED } = require('../lib/low-stock-alert.js');

const bot = (extra = {}) => ({
  telegram: { botToken: 't', chatId: '-100', notifyOnLowStock: true, ...extra },
});
const spools = (...names) => names.map((material) => ({ material }));

test('it warns only when there is a bot, a chat, the switch, and something low', () => {
  assert.equal(wouldWarn({ settings: bot(), low: spools('PLA Black') }).send, true);

  // Each condition on its own is enough to stay quiet.
  assert.equal(wouldWarn({ settings: bot({ notifyOnLowStock: false }), low: spools('PLA') }).send, false);
  assert.equal(wouldWarn({ settings: bot({ botToken: '' }), low: spools('PLA') }).send, false);
  assert.equal(wouldWarn({ settings: bot({ chatId: '' }), low: spools('PLA') }).send, false);
  assert.equal(wouldWarn({ settings: bot(), low: [] }).send, false);
  // And nothing at all.
  assert.equal(wouldWarn({}).send, false);
  assert.equal(wouldWarn().send, false);
});

test('it names up to five and counts the rest', () => {
  const few = wouldWarn({ settings: bot(), low: spools('PLA', 'PETG') });
  assert.equal(few.message, '⚠️ Low stock alert: PLA, PETG');

  const many = wouldWarn({
    settings: bot(),
    low: spools('A', 'B', 'C', 'D', 'E', 'F', 'G'),
  });
  assert.equal(many.message, '⚠️ Low stock alert: A, B, C, D, E and 2 more');
  assert.equal(NAMED, 5);

  // Exactly five names none as "more" — the off-by-one that would read
  // "and 0 more".
  const five = wouldWarn({ settings: bot(), low: spools('A', 'B', 'C', 'D', 'E') });
  assert.equal(five.message, '⚠️ Low stock alert: A, B, C, D, E');
});

test('a material name cannot break the message into several', () => {
  // A name is typed by a shop and pasted from a supplier's page, so it holds
  // whatever was on the clipboard. A newline would split one alert into lines
  // that each read as a separate warning.
  const out = wouldWarn({ settings: bot(), low: [{ material: 'PLA\nBlack\tmatte' }] });
  assert.equal(out.message, '⚠️ Low stock alert: PLA Black matte');
  assert.ok(!out.message.includes('\n'));

  // And it cannot run away with the message.
  assert.equal(oneLine('x'.repeat(400)).length, 100);
});

test('a row with no name at all is not warned about', () => {
  // `material` is what a spool is called; `name` is what some imported rows
  // carry. A row with neither would put an empty entry in the list, and
  // "Low stock alert: , , " tells a shop nothing.
  assert.equal(wouldWarn({ settings: bot(), low: [{}, {}] }).send, false);
  assert.equal(wouldWarn({ settings: bot(), low: [{ name: 'Resin' }] }).message,
    '⚠️ Low stock alert: Resin');
  // A nameless row among named ones simply drops out.
  assert.equal(wouldWarn({ settings: bot(), low: [{}, { material: 'PLA' }] }).message,
    '⚠️ Low stock alert: PLA');
});

test('it carries the bot and chat through, still sealed', () => {
  // The token comes back as it sits in the book — opening it is the host's
  // job, and a module that decrypted anything would be a module that needs a
  // Keychain.
  const out = wouldWarn({ settings: bot({ botToken: '__enc__sealed' }), low: spools('PLA') });
  assert.equal(out.botToken, '__enc__sealed');
  assert.equal(out.chatId, '-100');
});
