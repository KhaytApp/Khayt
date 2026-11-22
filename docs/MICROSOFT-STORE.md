# Microsoft Store releases

## The problem this replaces

The MSIX was built on every release and submitted on none of it. `release.yml` ran
`electron-builder --win appx`, uploaded the `.appx` as a **30-day workflow artifact**, and
stopped. There was no Partner Center step anywhere in the repo. Store users therefore sat on
whatever build was last uploaded by hand, with no update path — MSIX updates come from the
Store, and the Store had nothing newer to give. `electron-updater` does not help them either;
it serves the GitHub channel.

This surfaced as a user report: *"the version in the Windows Store is very old and I never
updated it."* Nothing was wrong on their machine. That was the pipeline, working as built.

## What is automated now

On a **stable** tag (`v3.6.0`, not `v3.6.0-rc.1` — see [Why stable only](#why-stable-only)),
the `submit-store` job in [`release.yml`](../.github/workflows/release.yml):

1. Downloads the MSIX the Windows job already built.
2. Runs [`scripts/build-store-metadata.mjs`](../scripts/build-store-metadata.mjs), which turns
   [`store/microsoft/listing.json`](../store/microsoft/listing.json) plus this release's
   `CHANGELOG.md` section into the submission metadata — and **fails the job** if any Store
   limit is broken.
3. `msstore publish --noCommit` — stages the package without committing.
4. `msstore submission updateMetadata` — stages the listing into the *same* draft.
5. `msstore submission publish` — commits once.

Steps 3–5 are deliberately in that order. `msstore publish` commits by default; letting it do
so would open a second submission for the metadata, costing two certification passes per
release that can land out of order. `--noCommit` makes the package and the listing one
submission.

**The listing copy lives in `store/microsoft/listing.json`, not in Partner Center.** Anything
edited by hand in Partner Center is overwritten by the next release. Edit the JSON, open a PR,
and the change ships with the release — reviewable like any other change.

## What is NOT automated: screenshot upload

Screenshots are **generated and validated** in this repo, but the upload itself is not wired,
and that is a limitation of the tooling rather than an oversight.

`npm run capture:store-screenshots` boots the real app on demo data, captures the ten screens
named in `listing.json` at 1920x1080, and checks each PNG against the published requirements
(PNG, at least 1366x768, at most 50 MB) before it can reach a submission. The results are
committed under `store/microsoft/screenshots/`.

What is missing is the last hop. The Microsoft Store Developer CLI documents
`submission getListingAssets`, but it does **not** document any way to upload new image
binaries, and the metadata JSON shape is not published — so wiring an upload would mean
guessing at an undocumented contract and discovering the result in a certification queue.

The [Store bootstrap](#the-bootstrap-run) workflow answers this definitively on its first run
by dumping the real listing assets and submission JSON. Until then:

- **Captions and ordering are automated** — they come from `listing.json`.
- **The image files themselves are uploaded by hand** in Partner Center, from
  `store/microsoft/screenshots/`, only when the screens actually change.

If the bootstrap output shows images are addressable, the upload becomes a small addition to
`build-store-metadata.mjs`. If it does not, the documented fallback is the legacy
[Store submission API](https://learn.microsoft.com/en-us/windows/uwp/monetize/create-and-manage-submissions-using-windows-store-services)
(or [StoreBroker](https://github.com/microsoft/StoreBroker)), which does specify image upload —
zip to a SAS URL — at the cost of Microsoft's rule that a submission created through that API
must never be touched in Partner Center afterwards.

## STATUS: manual submission, and this is settled, not pending

**Decided 2026-08-13: there are no plans to convert to a company account for a long
time.** The automated path below is therefore dormant by choice, not waiting on someone
to find the time. Do not re-propose the conversion, and do not treat the inert
`submit-store` job as an unfinished task — it is a switch for a decision that has been
made the other way.

What that leaves is a manual submission that is well supported: see
[Releasing to the Store by hand](#releasing-to-the-store-by-hand). Revisit only if the
business is incorporated for other reasons, at which point the remaining work is the
credentials and one bootstrap run.

## Why the automated path is blocked — an account-type limit

**Khayt's Store account is an individual developer account, and individual accounts cannot
associate a Microsoft Entra tenant.** No tenant means no app registration, which means no
client credentials, which means neither the msstore CLI nor the legacy submission API can
authenticate. Every automated route to the Store runs through that one door.

The evidence is in this repo — `package.json` → `build.appx.publisher`:

```
CN=F9AECB56-B63C-4BD8-BAF1-B8CDA4A8B0BC
```

A bare GUID is the individual-account form. A company account's publisher is a distinguished
name carrying the verified business name (`CN=Khayt, O=Khayt, L=…, C=SA`). Confirm in Partner
Center under **Account settings** → **Account details**.

This is why **Account settings** → **Tenants** → *Create Microsoft Entra ID* leads to a company
registration wizard rather than a tenant: it is offering an account upgrade, not a directory.
Completing it means supplying a legal business name, address and a registration ID such as a
D-U-N-S number, and converting the account type. **That is a business decision, not a
configuration step — do not click through it to unblock CI.**

Until that decision is made, the Store is updated **by hand**, and the tooling below exists to
make that quick and safe rather than to pretend otherwise:

| Step | Automated? |
|---|---|
| Build the MSIX | yes, every release |
| Keep the MSIX retrievable | yes — 90-day artifact |
| Generate the listing copy, validated | yes — `npm run store:manual` |
| Generate Store-spec screenshots | yes — `npm run capture:store-screenshots` |
| Catch a listing that breaks a Store limit | yes — on every PR |
| **Upload package, listing and screenshots** | **no — Partner Center UI** |

### Releasing to the Store by hand

1. `npm run store:manual` — writes `store/microsoft/partner-center.md`, a paste sheet with
   every field already validated and its character count shown. It is generated and
   git-ignored on purpose: it is stamped with the version it was built for, so a committed
   copy would be stale the moment the version bumps. Regenerate it per release.
2. `npm run capture:store-screenshots` — only if the UI changed since the last release.
3. Download the `windows-store-msix` artifact from that version's **Build & Release** run.
4. In Partner Center, upload the package, then paste the listing fields from the sheet.

Step 4 is the slow part: eight fields pasted one at a time and ten screenshots uploaded
individually, about twenty minutes. There is a documented way to collapse it — see below.

The `submit-store` job stays in `release.yml` and stays inert — it is gated on credentials
that do not exist, so it posts a notice and passes. It costs nothing to leave in place, and it
is the whole of the work needed on the day the account becomes a company account.

### NEXT IMPROVEMENT: bulk-import the listing as a CSV + folder

**Partner Center can import an entire Store listing — text fields *and* screenshots — from a
single folder, with no Entra tenant and no API.** It is UI-driven, so the account-type block
above does not apply. This is the biggest remaining win in the manual process, and it is not
yet built.

How it works ([docs](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/import-and-export-store-listings)):

- App overview → **Store listings** → **Export listing** gives a UTF-8 CSV with columns
  `Field`, `ID`, `Type`, `default`, and one row per listing item — `Description`,
  `Feature1`…`Feature20`, `ReleaseNotes`, `DesktopScreenshot1`…N, and the rest.
- Image rows have Type `Relative path (or URL to file in Partner Center)`. Put the CSV and the
  images in **one folder**, write `folder/images/shot.png` into the field, then
  **Import listings → Import folder**.
- Errors come back as a list to fix in the file. Nothing is saved until the import is clean.

So `npm run store:csv` could emit `store/microsoft/import/` — one CSV filled from
`listing.json` plus the ten screenshots already in place — turning step 4 into one file
picker.

**What is needed to build it:** a real `Export listing` CSV from this product. The `Field`,
`ID` and `Type` columns must be passed through byte-for-byte (the `ID` values are Partner
Center's own numbering), so the generator has to fill a genuine export rather than invent one.

**Export is unavailable while a submission is in certification** — the Store listings section
goes read-only, and the button is simply absent. Confirmed 2026-08-13. Wait for the
in-flight submission to be approved, then export.

Two traps the generator must respect:

- Deleting a **trailer** row permanently deletes that file from Partner Center. Never emit a
  row the generator does not own.
- Clearing an **image** field does *not* remove the image — the previous one is kept. Removing
  a screenshot has to be done in the Partner Center UI.

## One-time setup — only once the account is a company account

Everything below applies **after** an Entra tenant exists, which today it does not. It is
recorded now so the path is ready rather than rediscovered later.

### 1. Create the application — entirely inside Partner Center

**Do not start at [entra.microsoft.com](https://entra.microsoft.com/).** Signing up for Entra
or Azure from the outside drops you into the Azure subscription flow, which asks for company
details, a VAT number and a payment card. None of that is needed here, and that flow is not
the one this requires.

Partner Center creates both the directory and the application for you, free, and shows you
every value. You never have to open the Entra portal.

**1a. Make sure a tenant exists.** [Partner Center](https://partner.microsoft.com/dashboard) →
gear icon → **Account settings** → **Tenants**. If one is listed, skip to 1b. If not, select
**Create Microsoft Entra ID** and complete the wizard: it asks for directory information (which
becomes a `something.onmicrosoft.com` domain) and a global admin username and password. It does
not ask for company registration, VAT or a card, and it costs nothing. You become the global
administrator of the directory it creates, which is the permission step 1b requires.

**1b. Create the application.** **Account settings** → **User management** → the **Microsoft
Entra applications** tab → **Add Microsoft Entra application** → choose **Create Microsoft
Entra application** (the other option, *Add*, is for an app that already exists in a directory).

- **Display name** — something like `khayt-store-ci`.
- **Reply URL** — **required in this flow**, unlike the Entra portal, where it can be left
  blank. It is never used for anything: this is a daemon that signs in with a client secret and
  never redirects a browser. Any unique valid URL under 256 characters is fine —
  `https://khaytapp.com/store-ci` works.
- **Roles applicable to developer programs** → **Manager**. Assign it here, at creation.
  Anything less authenticates successfully and then fails on every submission call.

**1c. Collect the values.** Back on **User management**, click the application's name. That
page shows the **Tenant ID** and **Client ID**. Then select **Add new key**, which reveals the
**Key** — copy it before leaving the page, because it is never shown again.

You must be signed in as a Manager who is also a global administrator of that tenant, which you
will be if Partner Center created it in 1a.

### 2. Add the repository secrets

**Settings** → **Secrets and variables** → **Actions**. Every value comes from Partner Center:

| Secret | Where exactly |
|---|---|
| `AZURE_AD_TENANT_ID` | **User management** → **Microsoft Entra applications** → your app → *Tenant ID* |
| `AZURE_AD_APPLICATION_CLIENT_ID` | same page → *Client ID* |
| `AZURE_AD_APPLICATION_SECRET` | same page → **Add new key** → the *Key* value (shown once) |
| `SELLER_ID` | **Account settings** → **Identifiers** (or **Organization profile** → **Legal info**) → *Seller ID* / *Publisher ID* |

Note the key's expiry when you create it. When it lapses, releases start failing at the
sign-in step with nothing else obviously wrong.

**Do not go looking for API permissions.** There is no Store submission scope to grant in
Entra; an empty permissions list is correct. Authorisation comes from the **Manager** role in
1b. This is the most common wrong turn.

Portal labels move around. If a path above has drifted, the four values have not: a tenant ID,
an application client ID, a key for that application, and the Partner Center seller ID.

### Doing it from the Entra portal instead

Only relevant if the organisation already has a directory and prefers to manage app
registrations centrally. Register the app at
[App registrations](https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade)
→ **+ New registration**, single tenant, redirect URI left **empty** (the opposite of the
Partner Center flow); take *Application (client) ID* and *Directory (tenant) ID* from its
Overview blade and a secret from **Certificates & secrets** (copy the **Value** column, not the
Secret ID). Then you still have to add that app in Partner Center under **User management** →
**Microsoft Entra applications** → **Add Microsoft Entra application** and give it **Manager** —
the Entra half alone grants nothing.

And one **variable** (not a secret — it is public in the Store URL):

| Variable | Value |
|---|---|
| `STORE_PRODUCT_ID` | `9P4GR79Z84ZG` |

## Khayt's Store identity

Recorded here so it is not hunted for in Partner Center each time. All of it is public — the
Store ID is literally in the listing URL — so none of it is a secret. Partner Center shows it
under the product's **View product identity** page.

| | |
|---|---|
| Store ID | `9P4GR79Z84ZG` |
| Web listing | https://apps.microsoft.com/detail/9P4GR79Z84ZG |
| Deep link | `ms-windows-store://pdp/?productid=9P4GR79Z84ZG` |
| Package Family Name | `Khayt.Khayt_7x6ymsf84xmn6` |
| `Package/Identity/Name` | `Khayt.Khayt` |
| `Package/Identity/Publisher` | `CN=F9AECB56-B63C-4BD8-BAF1-B8CDA4A8B0BC` |
| `Package/Properties/PublisherDisplayName` | `Khayt` |

The publisher must match `build.appx.publisher` in `package.json` exactly or the package is
rejected at submission — it is the same GUID in both places, and it is also the evidence that
this is an individual account (see the status section above).

### 3. The bootstrap run

Run the **Store bootstrap** workflow once from the Actions tab. It is read-only — it never
creates or commits a submission. It fetches:

- `baseline.json` — the account's current submission JSON. **Commit this to
  `store/microsoft/baseline.json`.** With it present, `build-store-metadata.mjs` merges our
  fields into the real shape and passes everything else through untouched, so an automated
  metadata update cannot reset age ratings, pricing or markets. Without it the script emits a
  flat listing object, which is enough to bootstrap but not to trust.
- `listing-assets.json` — the answer to the screenshot question above.

Re-run it whenever Partner Center changes the submission shape; `build-store-metadata.mjs`
fails loudly (rather than submitting something empty) if the baseline no longer contains any
field it owns.

## If the submission job fails

**Do not re-run the whole workflow.** By the time `submit-store` runs, the GitHub release is
already published, and re-running a completed *Build & Release* forks it into a duplicate
draft and breaks the published update manifests — see [VERSIONING.md](../VERSIONING.md).

Re-run **that job alone** from the Actions UI (*Re-run failed jobs*), or finish the submission
in Partner Center by hand. The MSIX is still attached to the run as the `windows-store-msix`
artifact for 30 days, and the metadata it would have sent can be regenerated locally with
`npm run store:metadata -- --version <the released version>`.

## Why stable only

The job is gated on `needs.create-release.outputs.prerelease == 'false'`. Betas and release
candidates reach their audience through the GitHub pre-release channel that `electron-updater`
reads. The Store has no equivalent channel, every submission costs a certification pass, and
`v3.6.0-rc.1` is by definition not what Store users should be given. Package flights exist for
this and are not wired up.

## Store limits, enforced before submission

`build-store-metadata.mjs` fails the build rather than the certification queue. Current limits
(sources below):

| Field | Limit |
|---|---|
| Description | 10,000 characters, **required** |
| Short description | 255 characters |
| What's new | 1,500 characters (generated from `CHANGELOG.md`) |
| Product features | 20, at 200 characters each |
| Search terms | 7, at 40 characters each, and 21 words across all of them |
| Screenshot caption | 200 characters |
| Screenshots | up to 10 desktop, PNG, at least 1366x768, at most 50 MB |

Run it locally with `npm run store:check`. CI runs the same check on every PR, so an over-long
feature bullet is caught in review.

## Free products only

Microsoft's GitHub Actions update path is documented as
*"currently supported for free products only."* Khayt is free, so this applies cleanly. If the
Store listing ever becomes paid, this automation stops working and the note in Microsoft's
[GitHub Actions guide](https://learn.microsoft.com/en-us/windows/apps/publish/msstore-dev-cli/github-actions)
is the thing to re-check.

## The package is still unsigned

Store packages are signed by Partner Center during certification, so the MSIX lane is
unaffected by the decision in [WINDOWS-SIGNING.md](./WINDOWS-SIGNING.md) to ship the NSIS and
portable builds unsigned. Store users get a signed, SmartScreen-clean install; direct
downloaders do not.

## Sources

- [Publish app updates to Microsoft Store with GitHub Actions](https://learn.microsoft.com/en-us/windows/apps/publish/msstore-dev-cli/github-actions)
- [Microsoft Store Developer CLI commands (MSIX)](https://learn.microsoft.com/en-us/windows/apps/publish/msstore-dev-cli/commands)
- [App screenshots, images, and trailers for MSIX apps](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/screenshots-and-images)
- [Add and edit Store listing info for MSIX apps](https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/add-and-edit-store-listing-info)
- [Create and manage submissions (legacy submission API)](https://learn.microsoft.com/en-us/windows/uwp/monetize/create-and-manage-submissions-using-windows-store-services)
