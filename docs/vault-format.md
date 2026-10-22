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
- `HKDF(ikm, salt, info)` is HKDF-SHA256 (RFC 5869), 32 bytes out. An empty salt means
  32 zero bytes, which is what WebCrypto, node:crypto and CryptoKit all do.
- `GCM(key, nonce, pt, aad)` is AES-256-GCM with a 12-byte nonce. Its output is
  `ct || tag`, with a 16-byte tag. Decryption fails for a wrong key, a wrong AAD and
  tampering alike, and implementations must not try to tell these apart.
- `hex` is lowercase hex.
- `fileId`, `uploadId` and `grantId` are non-empty strings that **must not contain `|`**.
  They are joined with `|` inside AADs, so an ID containing `|` could make two different
  ID pairs produce the same AAD. Both twins refuse such IDs.

## Keys

| Key | Derivation | Bytes |
|---|---|---|
| shop DEK (root) | the shop's existing E2E data key (see below) | 32 |
| `vaultKey` | `HKDF(DEK, utf8("khayt-vault-v1"), utf8("vault"))` | 32 |
| `dedupeKey` | `HKDF(vaultKey, empty, utf8("khayt-vault-dedupe-v1"))` | 32 |
| `DK` (data key) | 32 random bytes, **fresh for every upload attempt** | 32 |
| `linkSecret` | 32 random bytes, sent as base64url (no padding) in the URL `#fragment` | 32 |
| `linkKey`, no password | `HKDF(linkSecret, utf8(grantId), utf8("khayt-link-v1"))` | 32 |
| `linkKey`, password | `HKDF(linkSecret \|\| P, utf8(grantId), utf8("khayt-link-v1"))` | 32 |

where `P = scrypt(utf8(NFC(password)), utf8("khayt-link-pw|" + grantId), N=32768, r=8, p=1, 32 bytes)`.

**The root is the shop's DEK.** These are the 32 random bytes that `lib/sync-crypto.js`
creates in `createKeyset` and wraps three ways: `wrappedByPassphrase`,
`wrappedByRecovery` and, for an organisation member, `wrappedByOrg`. Every device that can
read the shop's store already unlocks it (on the Mac, `CloudKeyMemory` keeps it). It is
also the only shop key that survives a passphrase change, because `changePassphrase`
re-wraps the DEK and does not replace it. The vault never uses the DEK directly as a
cipher key; HKDF separates `vaultKey` from it.

An empty password is refused. A link with no password passes none (`null` in JS, `nil` in
Swift). Normalise the password to NFC before encoding, so that "é" typed as one code point
and "é" typed as `e` plus U+0301 give the same key.

## Chunks

`chunkBytes = 4194304`. A file of `size` bytes has `n = max(1, ceil(size / chunkBytes))`
chunks. Every chunk but the last holds exactly `chunkBytes` of plaintext, and the last
holds the rest. An empty file is one empty chunk. A file of exactly `chunkBytes` bytes is
one chunk, with no trailing empty chunk.

For chunk `i` (counting from 0), with `last = (i == n - 1)`:

```
nonce_i = 00 00 00 00 || u64_be(i)                                 (12 bytes)
aad_i   = utf8("khayt-vault-v1|" + fileId + "|" + uploadId + "|" + decimal(i) + "|" + (last ? "1" : "0"))
sealed_i = GCM(DK, nonce_i, plaintext_i, aad_i)                    (len(plaintext_i) + 16 bytes)
```

The nonce is a counter, which is safe only because `DK` is never reused: a retried upload
draws a new `DK` and a new `uploadId`.

A reader decrypts chunk `i` with the index and the `last` flag of the position it expects.
That gives these rejections, and both twins test each one:

- **Wrong index or reordering**: the nonce and the AAD both carry `i`.
- **Truncation**: the chunk that is now final was sealed with `last = 0`.
- **Extension**: the real last chunk was sealed with `last = 1`.
- **Splicing from another file or upload**: the AAD carries `fileId` and `uploadId`.

## Manifest

```
manifestJson = {"v":1,"chunkBytes":4194304,"size":N,"chunks":["<hex sha256(sealed_0)>",...]}
manifestHash = hex(sha256(utf8(manifestJson)))
```

The JSON has no whitespace, the keys come in exactly this order, and `size` is the
plaintext length. Build the string by hand; don't use a JSON serialiser. The hashes cover
`ct || tag` of each chunk.

`manifestHash` must reach the reader by an authenticated route, such as inside the
encrypted meta record. `decryptFile` checks the manifest against the pinned hash, checks
each chunk against its listed hash, opens each chunk at its position, and checks that every
non-last chunk is full and that the total equals `size`. All of this happens before it
returns a byte. (The test vectors also use `chunkBytes = 16`, a test-only scale-down, and
the manifest records whatever value was used.)

## Dedupe tag

```
dedupeTag = hex(HMAC-SHA256(dedupeKey, sha256(plaintext)))
```

The tag is keyed per shop, so the server learns only that one shop uploaded the same bytes
twice. WebCrypto has no incremental SHA-256, so a streaming browser page must hash with its
own incremental SHA-256 and call `dedupeTagFromDigest`.

## Key wrap

```
wrapKey(kek, key, aad) = nonce(12, random) || GCM(kek, nonce, key, aad)      (12 + 32 + 16 = 60 bytes)
```

| Wrap | kek | aad |
|---|---|---|
| shop's copy of a file's DK | `vaultKey` | `utf8("khayt-vault-dk|" + fileId + "|" + uploadId)` |
| a link grant's copy of a DK | `linkKey` | `utf8("khayt-link-dk|" + grantId + "|" + fileId)` |

## Metadata record

```
encryptMeta(vaultKey, fileId, json) = nonce(12, random) || GCM(vaultKey, nonce, utf8(json), utf8("khayt-vault-meta|" + fileId))
```

The JSON text is sealed byte for byte, so the reader gets back exactly those bytes.

## Encoding on the wire

Every value above is raw bytes. The only encoding this format fixes is the `linkSecret`
in the URL fragment, which is base64url without padding. The cloud API chooses how to
carry the rest, and hex or base64 both work.

## API map

| Operation | JS (`KhaytVault`, all async) | Swift (`VaultCrypto`) |
|---|---|---|
| vault key | `deriveVaultKey(dek)` | `vaultKey(shopDek:)` |
| link key | `deriveLinkKey(secret, grantId, password\|null)` | `linkKey(linkSecret:grantId:password:)` |
| chunk | `encryptChunk(dk, fileId, uploadId, i, last, pt)` / `decryptChunk(…)` | `encryptChunk(dk:fileId:uploadId:index:last:plaintext:)` / `decryptChunk(…)` |
| manifest | `manifestJson(size, hashes)`, `manifestHash(…)`, `chunkHash(sealed)` | `manifestJSON(size:chunkHashes:)`, `manifestHash(…)`, `chunkHash(_:)` |
| whole file | `encryptFile`, `decryptFile` | `encryptFile`, `decryptFile` |
| wraps | `wrapDkForShop` / `unwrapDkForShop`, `wrapDkForGrant` / `unwrapDkForGrant` | same names |
| dedupe | `dedupeTag(vk, pt)`, `dedupeTagFromDigest(vk, sha)` | `dedupeTag(vaultKey:plaintext:)`, `dedupeTag(vaultKey:plaintextSha256:)` |
| meta | `encryptMeta`, `decryptMetaText`, `decryptMeta` (parsed) | `encryptMeta`, `decryptMeta` (bytes) |

In the browser, load `lib/scrypt-js.js` before `lib/vault-crypto.js`, because a password
link needs `globalThis.KhaytScrypt`. Every random draw accepts a test-only override
(`opts._nonce` in JS, `nonce:` in Swift), and only the vectors use it.
