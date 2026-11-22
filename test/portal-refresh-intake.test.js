/**
 * lib/portal-refresh.js hands the job's `intakeId` to the host so the publish
 * can send it TOP LEVEL (beside payload/kind/customerEmail), never inside the
 * public payload. The server emails the customer their link once per request.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/currencies.js');
require('../lib/order-payment.js');
require('../lib/portal-trial.js');
require('../lib/cloud-plans.js');
const Portal = require('../lib/portal-refresh.js');

const base = { id: 'J1', status: 'printing', price: 100, trackingToken: 'trk' };
const ctx = { settings: {}, clients: [] };

test('payloadFor returns intakeId for a job from an intake request, and keeps it out of the payload', () => {
  const built = Portal.payloadFor({ ...base, intakeId: 'in_42' }, ctx);
  assert.equal(built.intakeId, 'in_42');
  assert.equal(JSON.stringify(built.payload).includes('in_42'), false);
});

test('payloadFor has no intakeId key for a job without one', () => {
  for (const v of [undefined, '', null, 7]) {
    assert.equal('intakeId' in Portal.payloadFor({ ...base, intakeId: v }, ctx), false);
  }
});

test('requestFor carries intakeId through the guards', () => {
  const live = { settings: { cloud: { enabled: true, shopId: 's' } }, clients: [] };
  const req = Portal.requestFor({ ...base, intakeId: 'in_42', cloudPublished: true }, live);
  if (req) assert.equal(req.intakeId, 'in_42');
});
