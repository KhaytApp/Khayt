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
- **Sizes.** A file `size` is an integer from 0 to 2^53. Both twins refuse anything larger
  before doing anything else.

## Keys

| Key | Derivation | Bytes |
|---|---|---|
| shop DEK (root) | the shop's existing E2E data key (see below) | 32 |
| `vaultKey` | `HKDF(DEK, utf8("khayt-vault-v1"), utf8("vault"))` | 32 |
| `dedupeKey` | `HKDF(DEK, utf8("khayt-vault-v1"), utf8("dedupe"))` | 32 |
| `DK` (data key) | 32 random bytes, **fresh for every upload attempt** | 32 |
| `chunkKey` | `HKDF(DK, utf8(uploadId), utf8("khayt-vault-chunk-v1"))` | 32 |
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
| a link grant's copy of a DK | `linkKey` | `utf8("khayt-link-dk|" + grantId + "|" + fileId)` |

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

## Link meta record

```
linkMeta = sealN(linkKey, utf8(json), utf8("khayt-link-meta|" + grantId + "|" + fileId))
json     = {"uploadId":"…","manifestHash":"<64 hex>","name":"…","size":N,"kind":"…"}
```

This is what a share page opens first. It names the upload to fetch and carries the
**authenticated** `manifestHash` that the page passes to the reader. Writers emit the keys
in exactly this order, with `JSON.stringify` escaping; Swift's `LinkMeta.canonicalJSON()`
reproduces those bytes. Readers validate every field: `uploadId` must be an ID,
`manifestHash` must be 64 lowercase hex characters, `size` must be in range, and `name`
and `kind` must be strings.

The share page's full path: `linkKey` → `decryptLinkMeta` → `unwrapDkForGrant` →
`createReader(DK, fileId, linkMeta.uploadId, manifest, linkMeta.manifestHash)` → push the
chunks → `finish()`.

## Encoding on the wire

Every value above is raw bytes. The only encoding this format fixes is the `linkSecret`
in the URL fragment, which is base64url without padding. The cloud API chooses how to
carry the rest, and hex or base64 both work.

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
| link meta | `encryptLinkMeta(lk, grantId, fileId, meta)`, `decryptLinkMeta(…)` | `encryptLinkMeta(…, meta: LinkMeta)`, `decryptLinkMeta(…)` |

In the browser, load `lib/scrypt-js.js` before `lib/vault-crypto.js`, because a password
link needs `globalThis.KhaytScrypt`. Every random draw accepts a test-only override
(`opts._nonce` in JS, `nonce:` in Swift), and only the vectors use it.
