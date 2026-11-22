'use strict';
/**
 * A link's owner note, sealed as the Mac seals it (Core/VaultLinks.swift
 * sealNote / note): AES-256-GCM under the vault key, AAD
 * "khayt-grant-note|" + grantId, nonce(12) || ct || tag, standard base64.
 * Checked against node:crypto directly — a third reading, as the format's
 * vectors are.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const VC = require('../lib/vault-crypto.js');

const vaultKey = Buffer.alloc(32, 3);
const grantId = 'AbCdEfGhIjKlMnOpQrStUv';
const nonce = Buffer.from('000102030405060708090a0b', 'hex');

test('a fixed nonce gives exactly the bytes AES-GCM with the Mac\'s AAD gives', async () => {
  const got = await VC.encryptGrantNote(vaultKey, grantId, 'for Sara — the kit', { _nonce: nonce });
  const c = crypto.createCipheriv('aes-256-gcm', vaultKey, nonce);
  c.setAAD(Buffer.from('khayt-grant-note|' + grantId, 'utf8'));
  const ct = Buffer.concat([c.update(Buffer.from('for Sara — the kit', 'utf8')), c.final()]);
  assert.equal(got, Buffer.concat([nonce, ct, c.getAuthTag()]).toString('base64'));
});

test('it opens under the same key and grant, and nowhere else', async () => {
  const sealed = await VC.encryptGrantNote(vaultKey, grantId, 'note');
  assert.equal(await VC.decryptGrantNote(vaultKey, grantId, sealed), 'note');
  assert.equal(await VC.decryptGrantNote(vaultKey, 'OtherGrantIdOtherGrant', sealed), null, 'moved to another link');
  assert.equal(await VC.decryptGrantNote(Buffer.alloc(32, 4), grantId, sealed), null);
  assert.equal(await VC.decryptGrantNote(vaultKey, grantId, ''), null);
  assert.equal(await VC.decryptGrantNote(vaultKey, grantId, 'not base64!!'), null);
});

test('a grant id outside the allow-list is refused', async () => {
  await assert.rejects(VC.encryptGrantNote(vaultKey, 'a|b', 'x'));
});
