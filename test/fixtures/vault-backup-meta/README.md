# Desktop vault backup → the Mac's VaultApply

What a Windows/Linux backup of ONE library model puts in the Khayt Vault, written
by `scripts/gen-vault-backup-fixture.js`. That script runs the real
`lib/main/vault-backup.js` against a fake vault.

- `inputs.json`: the shop DEK (hex, a test key: bytes 01…20), the library
  record (its id has a `/`, a `:` and a space, so the folder name is
  `itemDirName`'s whole job), and the model file's bytes (base64).
- `feed-row.json`: the vault feed row exactly as `GET /vault/files` returns it.
  `_sealedChunksB64` holds the uploaded part ciphertexts for a full open.
- `expected.json`: the meta plaintext, and what the Mac's VaultApply should do
  with this row on a book holding that record. It should give the SAME record
  `vaultFileId`, `contentHash` and `sourceFile.size`, create no new record, and
  hold nothing for 7 days.

The ciphertext changes every time the script writes; the meta plaintext does
not (`--check`, run by `test/vault-backup-desktop.test.js`).
