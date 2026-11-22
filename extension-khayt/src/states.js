// What the popup says after a save, by Khayt's answer.
//
// Khayt answers `saved`, `updated`, `queued` (written, and Khayt is not open
// to take it yet), `refused` (with why) or `invalid`; the browser itself can
// only say `no-host` (it cannot reach Khayt) or `no-inbox` (Khayt was built
// without the shared folder a save waits in). Each is one sentence, and the
// sentence is a message key, so it is in the shop's language.

const KEYS = {
  saved: 'resultSaved',
  updated: 'resultUpdated',
  attached: 'resultAttached',
  queued: 'resultQueued',
  invalid: 'resultInvalid',
  'no-host': 'resultNoHost',
  'no-inbox': 'resultNoHost',
};

const REFUSED = {
  off: 'resultRefusedOff',
  'not-allowed': 'resultRefusedLock',
  sample: 'resultRefusedSample',
};

/** `{key, tone}` for an answer — tone is `good`, `wait` or `bad`. */
export function describe(reply) {
  const state = reply && reply.state;
  if (state === 'refused') {
    return { key: REFUSED[reply.reason] || 'resultRefused', tone: 'bad' };
  }
  const key = KEYS[state] || 'resultNoHost';
  const tone = state === 'saved' || state === 'updated' || state === 'attached' ? 'good'
    : state === 'queued' ? 'wait' : 'bad';
  return { key, tone };
}
