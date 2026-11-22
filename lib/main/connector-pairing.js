'use strict';
/**
 * Pairing a slicer plugin (Khayt for OrcaSlicer) with this computer: the
 * window a person opens ("Pair a slicer") and the commit-then-reveal state
 * machine behind POST /api/connectors/pair. The native Mac's
 * `LanConnectorPairing`, state for state; docs/LAN_API.md "POST
 * /api/connectors/pair", vectors docs/connector-pair.vectors.json.
 *
 * It IS the phone's window (lib/main/phone-pairing.js) with the connector's
 * own three prefixes, so the two cannot drift in how an offer is counted,
 * revealed, polled or approved. Only the prefixes and the bodies differ.
 *
 * Approve enrols the device as kind `connector` (lib/lan-devices.js
 * admitConnector): its key opens `/api/connectors/*` and nothing else.
 *
 * OFF BY DEFAULT, as the Mac's `connectorPairing` defaults switch: main wires
 * `enabled` to KHAYT_CONNECTOR_PAIRING=1 read from the environment at launch.
 * Off, every `/api/connectors/*` path answers the ordinary 404 and `open`
 * does nothing.
 *
 * Main process only (node:crypto).
 */
const PhonePairing = require('./phone-pairing.js');

const FLAVOR = Object.freeze({
  commit: 'khayt-connector-commit-v2',
  offer: 'khayt-enrol-commit-v2',
  check: 'khayt-connector-check-v2',
});

/** Same options as createPhonePairing; the prefixes are the connector's. */
function createConnectorPairing(opts = {}) {
  return PhonePairing.createPhonePairing(Object.assign({}, opts, { flavor: FLAVOR }));
}

const commitment = (pluginPublic, nonce) => PhonePairing.commitment(pluginPublic, nonce, FLAVOR);
const offerMessage = (deviceId, serverPublic, commit) => PhonePairing.offerMessage(deviceId, serverPublic, commit, FLAVOR);
const checkNumber = (deviceId, identityPublic, serverPublic, pluginPublic, nonce) =>
  PhonePairing.checkNumber(deviceId, identityPublic, serverPublic, pluginPublic, nonce, FLAVOR);

// The reasons are the Mac's; the words name this computer's own setting.
const CLOSED_BODY = JSON.stringify({ reason: 'pairing-closed', error: 'On the computer, open Settings, Online, Connected apps, and click Pair a slicer' });
const UPGRADE_BODY = JSON.stringify({ reason: 'pairing-upgrade', error: 'Update Khayt for OrcaSlicer: this computer pairs with version 2 of the handshake' });
const BUSY_BODY = JSON.stringify({ reason: 'pairing-busy', error: 'Another slicer is waiting for the shop to answer. Try again in a minute' });

module.exports = {
  createConnectorPairing, commitment, offerMessage, checkNumber, FLAVOR,
  plausiblePairId: PhonePairing.plausiblePairId,
  CLOSED_BODY, UPGRADE_BODY, BUSY_BODY,
};
