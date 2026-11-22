# Cloud storage for the print library

How to keep a print library that is larger than the disk it lives on, which
provider to pick, and what the safety guarantees actually are.

Prices checked **2026-08-23**. They go stale; the date is here so you can tell.

---

## 1. Three different jobs, one bucket

Khayt can use the same cloud storage for three unrelated purposes, and confusing
them is the main way people end up disappointed:

| | What it does | Frees disk space? |
|---|---|---|
| **Backup folder** (`printLibrary.mirror`) | Copies every new file to a second folder | **No** — it is a second copy |
| **Object storage backup** (`printLibrary.s3`) | Copies every new file to a bucket | **No** — it is a second copy |
| **Cloud tiering** (`printLibrary.tier`) | *Moves* cold models to the bucket | **Yes** |

The first two are backups, and [main.js](../main.js) is deliberate about never
reading from them: a backup you read from is a second primary, and the two
drift.

**Tiering is the one that solves a full disk.** A tiered model is not a copy —
it *is* the file, and the local disk becomes a cache. That is why it is allowed
to be read back when the backups are not.

Most shops should run a backup **and** tiering. They answer different questions:
"the workshop burned down" and "the laptop is full".

---

## 2. Choosing a provider

Roughly what a 500 GB library costs per month. Every one of these already worked
before the provider list existed — they are all S3, and
[lib/s3-client.js](../lib/s3-client.js) speaks to all of them.

| Provider | ~500 GB/mo | Downloads | Notes |
|---|---|---|---|
| **[Cloudflare R2](https://dash.cloudflare.com/sign-up)** | ~$7.50 | **Free, unmetered** | The safest default. See below. |
| **[Backblaze B2](https://www.backblaze.com/sign-up/cloud-storage)** | ~$3.00 | Free to 3× stored | Cheapest mainstream option |
| **[IDrive e2](https://www.idrive.com/e2/)** | ~$2.00 | Free up to stored | Endpoint is per-account — copy it from their dashboard |
| **[Hetzner](https://www.hetzner.com/storage/object-storage/)** | ~$6 floor | 1 TB included | Flat fee including 1 TB; poor value well under that. EU only |
| **[Scaleway](https://www.scaleway.com/en/object-storage/)** | Free under 75 GB | 75 GB free | Real free tier — the cheapest way to try tiering. EU |
| **[OVHcloud](https://www.ovhcloud.com/en/public-cloud/object-storage/)** | ~$4–6 | Allowance | EU sovereign, has an archive tier |
| **[Synology C2](https://c2.synology.com/en-global/object-storage/overview)** | ~$3 | Free | Sensible if the shop already runs Synology |
| **[Storj](https://www.storj.io/signup)** | ~$2.00 | **Billed** | Also bills per segment — many small files cost more than their size |
| **[DigitalOcean Spaces](https://www.digitalocean.com/products/spaces)** | ~$10 | 1 TB included | $5 covers the first 250 GB, then per-GB |
| **[Akamai / Linode](https://www.linode.com/products/object-storage/)** | ~$10 | 1 TB included | Same shape as Spaces |
| **[Wasabi](https://wasabi.com/cloud-object-storage)** | ~$7 **minimum** | Free 1:1 | Bills a 1 TB minimum and 90-day minimum retention — see below |
| **[Amazon S3](https://aws.amazon.com/s3/)** | ~$11.50 | **~$0.09/GB** | Widest regions. Pick it if your IT requires it |
| **[Google Cloud Storage](https://cloud.google.com/storage)** | ~$10 | **Billed** | Needs an HMAC key from Settings → Interoperability |
| **[Oracle Cloud](https://www.oracle.com/cloud/free/)** | ~$12 | Large allowance | Generous always-free tier |
| **[MinIO / NAS](https://min.io/download)** | Your hardware | Yours | Frees the laptop, but see the warning below |

Every provider name above links to its signup page, and the same links are in
the app under **Settings → Print library location → Provider**, next to whichever
one you have selected. You do not need an account with any of them to read this
page, but you do need one to fill in a single field of that form — which is why
the link is there.

**On referral links.** Khayt ships none today: every link above and in the app
goes straight to the provider with nothing appended. If that ever changes, the
app labels a referral link as one at the point you would click it, and the plain
link stays here in this file. The mechanism lives in one table in
[lib/storage-providers.js](../lib/storage-providers.js) so that all of it can be
read at once.

### Why R2 is the default recommendation

Not because it is cheapest — B2 and IDrive e2 are less than half the price. It
is because **a print library is re-read constantly.** Every reprint of a
year-old order pulls the model back down, and with tiering that is the normal
path rather than the exception. R2 is the only entry where that can never
produce a bill. Whether downloads are metered is a pricing *philosophy* and
changes far more slowly than a rate, which is why the app shows it next to each
provider.

If your library is mostly write-once and rarely re-read, B2 at ~$3 is the better
buy.

### Two traps

**Wasabi below 1 TB.** The headline $6.99/TB is competitive, but you are billed
for 1 TB whether or not you use it, and a deleted file keeps billing for 90
days. At 500 GB you pay double. Above 1 TB, with a library that does not churn,
it is fine. It is offered in the list with this stated.

**A NAS is not a backup.** MinIO or a Synology in the workshop genuinely frees
the laptop's disk, and that is a real result. But it is in the same building —
one fire, one flood, one theft takes both. Pair it with an off-site copy.

---

## 3. Setting up a bucket

1. Create a bucket at your provider. No account yet? The provider dropdown in
   Khayt links straight to their signup page. It does **not** need to be
   public — Khayt signs every request.
2. Create an access key with read and write on that bucket.
3. In Khayt: **Settings → Print library location → Also back up to object
   storage**.
4. Pick your provider from the dropdown and fill in the one or two fields it
   asks for. The endpoint is built for you.
5. Press **Test connection**. It writes a file, reads it back, compares the
   bytes, and deletes it — a reachable host with credentials that cannot write
   is otherwise indistinguishable from a working setup until the first model
   fails to upload.

The secret is encrypted at rest ([lib/store-io.js](../lib/store-io.js)) and the
app's own window is never given the real value, only a mask.

---

## 4. Turning on tiering

**Settings → Print library location → Move old models to the cloud.**

- **Keep on this computer for** — days. Default 90. A model reprinted quarterly
  never leaves the disk. The minimum is 1 day; zero would evict every model the
  moment it was saved and turn every first open into a download.
- **Free up space now** — runs a sweep. It tells you how many models and how
  much space *before* it does anything.
- **Bring everything back** — downloads the whole tiered library again. The way
  out, and the reason this is not a one-way door.

### What is never evicted

- **Thumbnails and photos.** They are what the library grid draws. Evicting them
  would make browsing a network operation — hundreds of round trips to paint one
  screen, and a wall of blank placeholders when the connection is away. They are
  also tiny, so they free nothing worth having.
- **Anything under 1 MB.** The request costs more than the space.
- **Anything newer than your keep-days setting.**

### The safety rule

> Nothing is deleted locally until the cloud has been asked, in its own separate
> request, and has answered with a checksum matching the local file.

Specifically, per file: compute SHA-256 and MD5 locally → upload → **HEAD the
object in a fresh request** → compare its size *and* its ETag against the local
MD5 → write a `.cloud` record → only then delete the local file.

The separate request matters. A PUT that returns `200` through a proxy which
stored nothing is exactly the failure this catches, and the upload's own
response cannot catch it. The ETag matters too: a size match alone is satisfied
by a truncated-then-padded upload, or by somebody else's object of the same
length under a colliding key in a shared bucket.

If a provider returns a multipart-style ETag that is not a plain MD5, Khayt pays
for a full download and hashes it rather than deleting on a size match.

### The `.cloud` record

An evicted model leaves a few hundred bytes of JSON behind, holding its size,
its SHA-256 and its object key.

It exists so the difference between *"this model is in the cloud"* and *"this
model is gone"* is answerable **from the disk, with no network and no
credentials**. A shop whose credentials expire opens a library where everything
is still listed and still explains where it went — rather than one that looks
empty, which is indistinguishable from lost.

### Known limitation

Deleting a model from the library does **not** delete the object from the
bucket. Mirroring and tiering write the same object key, so deleting it would
destroy the off-site backup of a shop running both. An orphaned object costs
pennies; a deleted backup costs the model. Orphans accumulate slowly and can be
cleared with your provider's own lifecycle rules.

---

## 5. Google Drive

The one non-S3 backend. It exists because a lot of makers already pay Google for
storage and would rather not open a second account.

**Dropbox and OneDrive need none of this.** Their desktop apps make the storage
a plain folder — point **Settings → Print library folder** at it and you are
done. That already worked before any of this, at no code cost. iCloud Drive too.
Drive gets a real integration only because tiering needs to verify uploads, and
a synced folder cannot answer that question.

### The scope

Khayt requests **`drive.file` only** — access to files this app itself created.
It cannot read your tax returns, your family photos, or anything it did not put
there. This is the right level of access on its own merits, and it also keeps
Khayt out of Google's restricted-scope programme, which requires an annual
third-party security assessment costing more than most shops using Khayt earn in
a year.

The cost of `drive.file` is real and worth knowing: **Khayt cannot adopt files
already in your Drive.** A library you uploaded by hand is invisible to it.

### Setting it up

You need your own OAuth client ID. Khayt cannot ship one — a client ID in an
open-source desktop app is public, and Google's verification is per-project.

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create
   a project.
2. **APIs & Services → Library** → enable **Google Drive API**.
3. **APIs & Services → OAuth consent screen** → choose **External**, fill in the
   app name and your email. Add the scope
   `https://www.googleapis.com/auth/drive.file`. Add your own Google account
   under **Test users**.
   - Leaving it in *Testing* is fine for your own shop. Test-user refresh tokens
     expire after 7 days; publish the app (no review is needed for `drive.file`)
     to stop that.
4. **Credentials → Create credentials → OAuth client ID → Desktop app**. Copy
   the client ID.
5. In Khayt: **Settings → Print library location → Use Google Drive**, paste the
   client ID, **Save**, then **Connect Google account**.

Consent opens in your real browser. Khayt never hosts the sign-in itself —
Google blocks embedded windows, and rightly: an app hosting the login window can
read what you type into it.

### If it says no refresh token was issued

Google issues one only on first consent. Remove Khayt at
**myaccount.google.com → Security → Third-party access** and connect again.

---

## 6. Where the code is

| | |
|---|---|
| [lib/storage-providers.js](../lib/storage-providers.js) | The provider table and endpoint builder |
| [lib/s3-client.js](../lib/s3-client.js) | SigV4, every S3-compatible provider |
| [lib/gdrive-client.js](../lib/gdrive-client.js) | Drive, imitating the S3 client's shape |
| [lib/print-library-tier.js](../lib/print-library-tier.js) | What may be evicted, and what proves it is safe |
| [main.js](../main.js) | `printLibRemote`, `printLibEnsureInBucket`, `printLibRehydrate`, the sweep |

`printLibRemote()` is the seam: S3 and Drive expose the same `put/get/head/del`
over the same opaque keys, so the mirror, the sweep and rehydration are written
once and do not know which backend they hold. That is the whole reason
`gdrive-client`'s `head()` returns `{size, etag}` — Drive's `md5Checksum` is
exactly what an S3 ETag is for a single-part upload.
