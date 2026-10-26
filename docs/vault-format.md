# Khayt Vault format, v1

The encryption for files a shop keeps in Khayt Cloud and shares by link. The server
stores only ciphertext, wrapped keys and hashes. It never holds a key that opens a file.

There are two implementations, and they are twins:

- `lib/vault-crypto.js`: WebCrypto, for browsers and Node 20+ (the cloud's share page).
- `mac/KhaytCore/Sources/KhaytCore/VaultCrypto.swift`: CryptoKit, for the Mac and iPhone.
  The Mac can't use the JS file, because JavaScriptCore has no WebCrypto.

Both are checked against `test/fixtures/vault-crypto-vectors.json`. That file is written by
`scripts/gen-vault-crypto-vectors.js` from `node:crypto` alone, so it is a third reading
of this document and not the output of either twin. Change this format only by changing
all three, and bump `v`.

## Conventions

- `utf8(s)` is the UTF-8 bytes of a string. `||` is byte concatenation.
- `HKDF(ikm, salt, info)` is HKDF-SHA256 (RFC 5869), 32 bytes out.
- `GCM(key, nonce, pt, aad)` is AES-256-GCM with a 12-byte nonce. Its output is
  `ct || tag`, with a 16-byte tag. Decryption fails for a wrong key, a wrong AAD and
  tampering alike, and implementations must not try to tell these apart.
- `sealN(key, pt, aad)` is `nonce(12, random) || GCM(key, nonce, pt, aad)`.
- `hex` is lowercase hex.
- **IDs.** `fileId`, `uploadId` and `grantId` must match `[A-Za-z0-9_-]{1,64}`, judged on
  their bytes. Both twins refuse everything else. This is an allow-list because a deny-list
  fails: Swift's `String.contains("|")` compares graphemes and misses `|` followed by a
  combining mark (`"a|\u{301}b"`), and lone surrogates mean different things in the two
  languages. IDs are joined with `|` in AADs, and the allow-list is what keeps those joins
  unambiguous.
- **Sizes.** A file `size` is an integer from 0 to 2^53−1 (`Number.MAX_SAFE_INTEGER`). Both twins refuse anything larger
  before doing anything else.

## Keys

| Key | Derivation | Bytes |
|---|---|---|
| shop DEK (root) | the shop's existing E2E data key (see below) | 32 |
| `vaultKey` | `HKDF(DEK, utf8("khayt-vault-v1"), utf8("vault"))` | 32 |
| `dedupeKey` | `HKDF(DEK, utf8("khayt-vault-v1"), utf8("dedupe"))` | 32 |
| `DK` (data key) | 32 random bytes, **fresh for every upload attempt** | 32 |
| `chunkKey` | `HKDF(DK, utf8(uploadId), utf8("khayt-vault-chunk-v1"))` | 32 |
| `grantId` | `newGrantId()`: base64url of 16 random bytes, no padding (22 characters) | 16 |
| `linkSecret` | 32 random bytes, sent as base64url (no padding) in the URL `#fragment` | 32 |
| `linkKey`, no password | `HKDF(linkSecret, utf8(grantId), utf8("khayt-link-v1"))` | 32 |
| `linkKey`, password | `HKDF(linkSecret \|\| P, utf8(grantId), utf8("khayt-link-v1"))` | 32 |

where `P = scrypt(utf8(NFC(password)), utf8("khayt-link-pw|" + grantId), N=32768, r=8, p=1, 32 bytes)`.

`vaultKey` and `dedupeKey` are siblings. Both come from the DEK under different labels,
and neither is derived from the other.

**The root is the shop's DEK.** These are the 32 random bytes that `lib/sync-crypto.js`
creates in `createKeyset` and wraps under the passphrase, the recovery key and, for an
organisation member, the org key (`wrappedByOrg`). Every device that can read the shop's
store already unlocks it (on the Mac, `CloudKeyMemory` keeps it). It also survives a
passphrase change, because `changePassphrase` re-wraps the DEK and does not replace it.

- **Organisation members.** Whoever holds the org key can unwrap every member shop's DEK,
  so they can derive every member's `vaultKey` and open every member's vault files. That
  is the same reach the org key already has over the stores. Leaving an org removes
  `wrappedByOrg` but does not change the DEK, so an org key that was copied out before the
  shop left still opens vault files uploaded afterwards. Only a DEK rotation ends that.
- **DEK rotation** does not exist today. If it is ever added, it changes `vaultKey` and
  `dedupeKey`. Every shop DK wrap and every meta record must then be re-sealed under the
  new `vaultKey`. Chunks, DKs and link grants are untouched, because they never use the
  DEK. Every dedupe tag changes as well, so dedupe against files uploaded before the
  rotation stops working until those tags are recomputed. Recomputing needs each file's
  plaintext SHA-256, which only a client can supply.

### Link passwords

The password must be passed explicitly. In JS, `null` means no password and `undefined`
is refused, so a forgotten argument can never produce a password-less link. In Swift the
parameter has no default and `nil` must be written out. An empty password is refused.
The password is normalised to NFC first, so "é" typed as one code point and "é" typed as
`e` plus U+0301 give the same key.

**A password protects a leaked link only if the password is strong.** Anyone who has the
link (and with it `linkSecret`) and the grant's ciphertext can test guesses offline at
the cost of one scrypt at 2^15 each, with no rate limit. Both twins provide
`linkPasswordOk(pw)`, which is true when the password has at least 10 Unicode scalars
after NFC (scalars, not graphemes, so both twins count the same way). The share UI should
refuse anything shorter. Length alone is still not strength, so the UI should also say
this plainly.

The scrypt cost is fixed by the format. Swift's test-only cost override is `internal`
(visible only to `@testable` code), and an injected JS scrypt is always called with the
fixed parameters.

## Chunks

`chunkBytes = 4194304`. A file of `size` bytes has
`n = 1` if `size == 0`, otherwise `n = size / chunkBytes + (size % chunkBytes == 0 ? 0 : 1)`.
This is written without `size + chunkBytes - 1`, which overflows near `Int.max`. Every
chunk but the last holds exactly `chunkBytes` of plaintext, and the last holds the rest.
An empty file is one empty chunk. A file of exactly `chunkBytes` bytes is one chunk.

For chunk `i` (counting from 0), with `last = (i == n - 1)`:

```
nonce_i  = 00 00 00 00 || u64_be(i)                                 (12 bytes)
aad_i    = utf8("khayt-vault-v1|" + fileId + "|" + uploadId + "|" + decimal(i) + "|" + (last ? "1" : "0"))
sealed_i = GCM(chunkKey, nonce_i, plaintext_i, aad_i)               (len(plaintext_i) + 16 bytes)
```

The nonce is a counter, which is safe only because no `(chunkKey, i)` pair ever repeats.
Every upload attempt draws a new `DK` and a new `uploadId`, and `chunkKey` also depends on
`uploadId`, so even a reused `DK` under a new `uploadId` gets a new key.

**Resuming an upload re-sends the sealed chunks stored from the first attempt and never
re-encrypts them.** Re-encrypting chunk `i` of the same upload would reuse
`(chunkKey, nonce_i)` on plaintext that may have changed in between, and that leaks the
XOR of the two plaintexts and the GCM authentication key. A client that has lost its
sealed chunks abandons the upload and starts a new one with a fresh `DK` and `uploadId`.

A reader decrypts chunk `i` with the index and the `last` flag of the position it expects.
That gives these rejections, and both twins test each one:

- **Wrong index or reordering**: the nonce and the AAD both carry `i`.
- **Truncation**: the chunk that is now final was sealed with `last = 0`.
- **Extension**: the real last chunk was sealed with `last = 1`.
- **Splicing from another file or upload**: the AAD carries `fileId` and `uploadId`, and
  `chunkKey` carries `uploadId`.

## Manifest

```
manifestJson = {"v":1,"chunkBytes":4194304,"size":N,"chunks":["<hex sha256(sealed_0)>",...]}
manifestHash = hex(sha256(utf8(manifestJson)))
```

The JSON has no whitespace, the keys come in exactly this order, and `size` is the
plaintext length. Build the string by hand; don't use a JSON serialiser. The hashes cover
`ct || tag` of each chunk. (The test vectors also use `chunkBytes = 16`, a test-only
scale-down, and the manifest records whatever value was used.)

`manifestHash` must reach the reader by an authenticated route. The shop gets it from its
meta record, and a share page gets it from the link meta record.

## Streaming reader

`createReader` (JS) and `ChunkReader` (Swift) take the manifest and the pinned
`manifestHash`, and check one against the other up front. Each `push(sealed)` then checks
the chunk's hash, opens it at its position, checks that a non-last chunk is full, and
returns its plaintext. `finish()` succeeds only once the chunk sealed with `last = 1` has
opened and the total equals `size`. A stream that ends before that fails at `finish()`. A
chunk pushed after the last is refused, and any failure is final. **Plaintext a reader has
already returned is not proof of anything until `finish()` succeeds.** A consumer that
writes plaintext out as it goes must discard it if `finish()` throws. `decryptFile` is the
same reader run over a list.

## Dedupe tag

```
dedupeTag = hex(HMAC-SHA256(dedupeKey, sha256(plaintext)))
```

The tag is keyed per shop, so the server learns only that one shop uploaded the same bytes
twice. WebCrypto has no incremental SHA-256, so a streaming browser page must hash with its
own incremental SHA-256 and call `dedupeTagFromDigest`.

## Key wrap

```
wrapKey(kek, key, aad) = sealN(kek, key, aad)                    (12 + 32 + 16 = 60 bytes)
```

| Wrap | kek | aad |
|---|---|---|
| shop's copy of a file's DK | `vaultKey` | `utf8("khayt-vault-dk|" + fileId + "|" + uploadId)` |
| a link grant's copy of a DK | `linkKey` | `utf8("khayt-link-dk|" + grantId + "|" + fileId + "|" + uploadId)` |
| a released file's DK (phase 3b) | `productKey` | `utf8("khayt-product-dk|" + productId + "|" + fileId + "|" + uploadId)` |

## Shop meta record

```
meta = sealN(vaultKey, utf8(json), utf8("khayt-vault-meta|" + fileId + "|" + uploadId))
```

`json` is a JSON object that must carry `seq`, an integer that increases with every new head
of the file. Writers must emit, and readers must accept, only `0 ≤ seq ≤ 2^53−1`
(`Number.isSafeInteger` in JS, checked on the parsed value before any arithmetic), and both
twins refuse anything else. A JS reader cannot tell 2^53 from 2^53+1, so the twins could
not otherwise agree on what was seen. The vectors include a record sealed with `seq = 2^53`
(`meta.sealedSeqTooBig`) that both twins must refuse. The JSON text is sealed byte for byte. The pinned
`manifestHash` for that upload goes in this record.

`checkMetaSeq(seq, lastSeen)` refuses a `seq` lower than the reader's last-seen value. An
equal `seq` is accepted, because re-reading the same head is normal. **Rollback, meaning
the server serving an older, validly sealed head, is detected only by readers that
remember the last `seq` they saw.** A device reading a file for the first time, or one
that has lost its memory, cannot tell an old head from the current one. The AAD binds the
record to its `uploadId`, so the server cannot pair one upload's meta with another
upload's chunks.

## Version meta record

Every version also has a record of its own, so that a reader has the whole manifest (every
chunk hash) before the first chunk arrives and can check each chunk as it streams. The shop
meta record holds only one `manifestHash`, and the cloud keeps one shop record per file.

```
versionMetaJson = {"manifest":<manifestJson>,"size":N,"seq":S}
versionMeta     = sealN(vaultKey, utf8(versionMetaJson), utf8("khayt-vault-vmeta|" + fileId + "|" + uploadId))
```

- `<manifestJson>` is the exact manifest string from the Manifest section, inlined
  unchanged. `size` repeats the manifest's size, and `seq` is the file's `seq` for the
  head this version became.
- Writers build the string by hand. Readers refuse any record whose bytes are not exactly
  the canonical form they would write themselves for the parsed values. The trusted
  `manifestHash` is the hash of the inlined manifest.
- **It has its own AAD label**, `khayt-vault-vmeta`, so neither record opens as the other.
  As a second guard, a shop meta record must not carry a `manifest` key, and both twins
  refuse one on write and on read.
- The cloud requires it on `/complete`. It comes back in the feed's `versions[]` and on the
  chunks route.

## Link meta record

```
linkMeta = sealN(linkKey, utf8(json), utf8("khayt-link-meta|" + grantId + "|" + fileId))
json     = {"uploadId":"…","manifest":<manifestJson>,"manifestHash":"<64 hex>","name":"…","size":N,"kind":"…"}
```

This is what a share page opens first. It names the upload to fetch and carries the whole
manifest, so the page has every chunk hash before the first chunk and can check each chunk
as it streams. It also carries the **authenticated** `manifestHash`.

- **Key order.** Writers emit the keys in exactly this order, with `JSON.stringify`
  escaping. The manifest is inlined as its canonical JSON object `{v, chunkBytes, size,
  chunks}`, which is exactly what `JSON.stringify` writes for it. Swift's
  `LinkMeta.canonicalJSON()` reproduces those bytes.
- **Validation.** Readers check every field:
  - `uploadId` must be an ID;
  - `manifestHash` must be 64 lowercase hex characters;
  - `size` must be in range and equal `manifest.size`;
  - `manifest.v` must be 1;
  - `name` and `kind` must be strings;
  - `sha256` of the manifest, rebuilt canonically from its fields, must equal
    `manifestHash`.
- **Size.** A 5 GiB file has about 1,280 chunks, which makes the record about 90 KB.
  That is why the cloud's cap on `linkMeta` is 256 KB.

**Links have no rollback protection, and that is accepted.** A share page keeps no memory
between visits, so it has no last-seen anything to compare against. A server that serves an
entirely old grant item that is consistent with itself (an old link meta, the grant DK wrap
for that old upload, and that upload's chunks) passes every check, and the visitor sees the
older version of the file. What the server cannot do is mix items: the grant DK wrap's AAD
carries `uploadId` and the chunk key derives from it, so an old wrap with new chunks, or the
reverse, fails.

The share page's full path: `linkKey` → `decryptLinkMeta` → `unwrapDkForGrant(…, linkMeta.uploadId)` →
`createReader(DK, fileId, linkMeta.uploadId, linkMeta.manifest, linkMeta.manifestHash,
{chunkBytes: linkMeta.manifest.chunkBytes})` → push each chunk as it arrives → `finish()`.

## Published files (phase 3b)

```
productKey  = 32 random bytes, fresh on EVERY release (newProductKey)
productDk   = wrapKey(productKey, DK, utf8("khayt-product-dk|" + productId + "|" + fileId + "|" + uploadId))
productMeta = sealN(productKey, utf8(json), utf8("khayt-product-meta|" + productId + "|" + fileId + "|" + uploadId))
json        = the link meta record above, byte for byte, with json.uploadId == uploadId
```

A file a creator **sells** is readable by Khayt Cloud, and only that file. The reason is
that a buyer who pays at night must get the file while the creator's Mac is asleep. Private
vault files are never wrapped under a product key.

- **Release.** The Mac makes a fresh `productKey` and sends it together with `productDk`
  and `productMeta` for **every** file in the product. A release is the complete set, and
  the cloud swaps the key and the items in one step. The Mac keeps nothing about a product:
  no product key in the Keychain and none in the book.
- **The cloud.** It seals `productKey` under its own server key, with AAD
  `"khayt-product-pk|" + shopId + "|" + productId`. On a sale it unwraps, then makes an
  ordinary link grant locked to the buyer's email, with no password:
  `newGrantId`, `newLinkSecret`, `deriveLinkKey(secret, grantId, null)`, `wrapDkForGrant`,
  and `encryptLinkMeta` of the decrypted record. The buyer's page is the share page,
  unchanged.
- **Binding.** Both AADs name the product, the file and the upload. A v1 wrap is never
  served as v2, a wrap made for one product never opens for another, and neither label can
  be read as a link's or the shop's.
- **What the cloud can read, and for how long.** DKs are fresh per upload. A released
  version therefore stays readable by the cloud while it is stored and either still on
  sale or reachable through a buyer's link. Stopping a sale protects only the versions
  that come after it.

## Encoding on the wire

Every value above is raw bytes. The only encoding this format fixes is the `linkSecret`
in the URL fragment, which is base64url without padding. The cloud API chooses how to
carry the rest, and hex or base64 both work.

## Client state (the Mac and iPhone client, not the format)

This section is about `VaultClient`, `VaultUpload`, `VaultDownload` and `VaultSync` in
KhaytCore. Another client may do these things differently and still read the same vault.

- **Wire encoding.** Blobs (`wrappedKey`, `meta`, `versionMeta`) are standard base64 with
  padding, and the cloud refuses anything else with 422. IDs are base64url without padding.
- **Version numbers can have gaps.** An aborted upload still uses up its number, so nothing
  may assume that version `head − 1` exists.
- **The shop meta record's JSON** (`VaultMeta`) is
  `{seq, uploadId, manifestHash, size, sha256, name, path, kind, key?, recordId?}`. It names
  the file. It is not what a download trusts: a download pins each version's own record (see
  "Version meta record"), so a version committed by another device verifies even after a
  later shop record has replaced the one that came with it.
- **The record field.** A library record that has a vault copy carries **`vaultFileId`**,
  the vault's `fileId`. The meta record carries the library record's id as `recordId`, so
  the link can be followed in either direction. `VaultSync` never writes the book. It
  reports changes, and the app writes `vaultFileId`.
- **The per-device state file** lives in the app's own folder (on the Mac, the book's
  folder): `<app folder>/vault-state.<shopId>.<first 16 hex of sha256(root path)>.json`.
  - It holds the feed's `rev`, each file's last-seen `seq` and accepted plaintext
    `sha256`, the key → fileId and recordId → fileId indexes, and the last feed row of
    each file. Those rows are ciphertext and wraps only.
  - It also holds `pending`: every change a pull reported that the app has not applied
    yet. Each one carries `base`, the hash of the version this device held before the
    head moved. Every pull appends to it, whoever made the pull, and the app removes
    entries only after the library edits are written (`VaultApply`, `Shop+VaultApply`).
    A state file without the key was written before it existed. Its next pull seeds
    `pending` once from the files it already knows.
- **Applying changes.** The app applies a change only inside a record's own folder
  under the primary library root. It writes one of three things:
  - a `.cloud` sidecar with `provider: "vault"`, so the model is fetched on use;
  - the new head over a local copy that still hashes to `base`;
  - the other version beside a copy edited since then, named `<name> (vault v<N>).<ext>`.
  A kept copy is marked by a hidden `.<copy name>.vault-kept` file (`{v, of, fileId, version}`)
  beside it, so backups and Free Up Space skip it. The marker is what decides, never the
  name. The shop then chooses which to keep, and the other goes to the Trash.
  A replaced version marks the record's figures out of date (`figuresStaleFor`, the new
  hash) until it is measured again.
  It never deletes a model and never writes a linked or adopted file. The record
  fields it writes are `vaultFileId`, `contentHash`/`sourceFile.size`, and for a
  vault trash `vaultTrashedAt`. A trash also sets `archivedAt` with `vaultArchived: true`
  when the record was not already archived. A restore clears what the trash set, and a
  purge drops the link.
  - It is kept out of the book because the last-seen `seq` protects against rollback only if
    it is this device's own memory.
  - It is kept out of the library root and its parent because either can be iCloud, a NAS
    or a shared folder.
  - Nothing is read from beside the root. An unreleased build wrote the state there, and a
    file in that place can be planted by anyone who can write the folder, so it is ignored.
- **Uploads spool.** Sealed chunks are written to disk before any part is sent. A resumed
  upload re-sends those exact bytes. A spool that was never fully sealed is abandoned
  (`DELETE /uploads/{id}`) and the upload starts again. The raw DK is never written to disk.
- **Share links (`VaultLinks`).** A grant shares each file's head version. The manifest in
  its link meta comes from the version's own sealed record, never from the server's
  listing. The link secret and the link key are kept in the device's Keychain only
  (service `Khayt Vault Link`, account `<shopId>/<grantId>`, this device only, not
  synchronised), never in the book. The password is never stored. A link sent in several
  requests is marked pending in that record until its last batch lands. A pending link is
  never offered for copying, and one still pending after 10 minutes is revoked the next time
  the Links screen loads. A link the cloud no longer calls `ok` has its secret forgotten. The grant's `ownerNote` is the shop's own memo,
  sealed as `sealN(vaultKey, utf8(note), utf8("khayt-grant-note|" + grantId))`. It is a
  client record, not part of format v1, and the share page never reads it.
- **Downloads take one pass.** The version record supplies every chunk hash up front.
  Each chunk is fetched into memory, checked and opened by `ChunkReader`, and appended to a
  temporary file. No ciphertext ever touches disk. The file is renamed into place only after
  `finish()`.

## API map

| Operation | JS (`KhaytVault`, async unless noted) | Swift (`VaultCrypto`) |
|---|---|---|
| keys | `deriveVaultKey(dek)`, `deriveDedupeKey(dek)`, `deriveChunkKey(dk, uploadId)` | `vaultKey(shopDek:)`, `dedupeKey(shopDek:)`, `chunkKey(dk:uploadId:)` |
| link key | `deriveLinkKey(secret, grantId, password\|null)`, `linkPasswordOk(pw)` (sync) | `linkKey(linkSecret:grantId:password:)`, `linkPasswordOk(_:)` |
| chunk | `encryptChunk(dk, fileId, uploadId, i, last, pt)` / `decryptChunk(…)` | `encryptChunk(dk:fileId:uploadId:index:last:plaintext:)` / `decryptChunk(…)` |
| manifest | `manifestJson` (sync), `manifestHash`, `chunkHash`, `chunkCount` (sync) | `manifestJSON`, `manifestHash`, `chunkHash`, `chunkCount` |
| reading | `createReader(…)` → `{push, finish, done}`, `decryptFile` | `ChunkReader(…)`, `decryptFile` |
| wraps | `wrapDkForShop` / `unwrapDkForShop`, `wrapDkForGrant` / `unwrapDkForGrant` | same names |
| dedupe | `dedupeTag(dek, pt)`, `dedupeTagFromDigest(dek, sha)` | `dedupeTag(shopDek:plaintext:)`, `dedupeTag(shopDek:plaintextSha256:)` |
| shop meta | `encryptMeta(vk, fileId, uploadId, json)`, `decryptMeta(…, lastSeenSeq)`, `checkMetaSeq` (sync) | `encryptMeta(…)`, `decryptMeta(…, lastSeenSeq:)` → `(json, seq)`, `checkMetaSeq` |
| version meta | `versionMetaJson` (sync), `encryptVersionMeta(vk, fileId, uploadId, {size, chunkHashes, seq, chunkBytes?})`, `decryptVersionMeta(…, lastSeenSeq)` | `versionMetaJSON`, `encryptVersionMeta(…)`, `decryptVersionMeta(…, lastSeenSeq:)` → `VersionMeta` |
| link meta | `encryptLinkMeta(lk, grantId, fileId, meta)`, `decryptLinkMeta(…)` | `encryptLinkMeta(…, meta: LinkMeta)`, `decryptLinkMeta(…)` |

In the browser, load `lib/scrypt-js.js` before `lib/vault-crypto.js`, because a password
link needs `globalThis.KhaytScrypt`. Every random draw accepts a test-only override
(`opts._nonce` in JS, `nonce:` in Swift), and only the vectors use it.
