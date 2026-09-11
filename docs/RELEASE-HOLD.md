# Release hold (maintainer)

## Status: no hold active

The hold that stood over the 3.1 line **ended when v3.2.0 shipped stable on
2026-07-22**, closing the `3.2.0-beta.x` line at beta.61. `CHANGELOG.md` records
that release as "the 3.2.0 beta line, released as stable" — the deliberate
stable release the hold was waiting for, not a breach of it. Several stable
lines have shipped since; the current `releases/latest` pointer is in the table
below, not v3.2.0.

Nothing currently blocks a stable tag. To impose a new hold, replace this
section with the channel it covers, the reason, and the condition for lifting.

A tag can now be cut from the Actions tab — **Cut release tag**, see
[docs/BETA-RELEASE.md](./BETA-RELEASE.md) — so "whoever merged the release PR
cannot push a tag" has stopped being a reason a release stalls. It refuses a
commit that is not on `main`, a `package.json` that disagrees with the version
asked for, notes still sitting in `[Unreleased]`, and a tag that already exists.
A hold is still a decision recorded here, not something that workflow enforces.

| Channel | Last published | Notes |
|---------|----------------|-------|
| **Stable** | **v3.7.0** (2026-09-11) | [Latest release](https://github.com/khaytapp/Khayt/releases/latest) — **the 3.7.0 line, cut from `main` rather than promoted from `v3.7.0-beta.25` unchanged**, because 225 commits had landed since that cut, including the money corrections and three dependency security fixes. Khayt stops guessing what a print cost and reads it: a completed job is offered the time and filament the PRINTER measured rather than the estimate under a second name, that figure is what comes off the shelf, and cost-against-quote is reported per model and per machine. **It moves money figures** — revenue no longer counts VAT you collect, and VAT you PAY on stock is recordable — so it carries a `### Before you update` section and the update gates on it. It also brings the Electron floor current: three unapplied Chromium/V8/ANGLE/WebRTC patch releases and two dependency advisories, one held open by this repo's own version pin. The 3.7.0 promotion gate and the one condition WAIVED are recorded below. |
| **Previous stable** | **v3.6.0** (2026-08-21) | [Latest release](https://github.com/khaytapp/Khayt/releases/latest) — **the 3.6.0 line, promoted from `v3.6.0-rc.4` unchanged.** Khayt learns what prints actually cost: a model becomes a quote, the printer reports the real filament and duration on completion, the settings that worked are remembered against the file, and the estimator calibrates itself from finished jobs. It changes **what customers are quoted** and how every geometry-based time estimate is computed, which is why the line soaked for three weeks in beta and seven days as a candidate. It also opens the app outside the Gulf (sales tax added to a price rather than included in it, thirty country presets, documents printed in the shop's chosen language rather than that language and Arabic), closes four security holes — a portal link that exposed a whole message thread, a printer address written as a number that could point at your own network, an arbitrary file write in the converter, and a brute-force lockout that never locked — and stops a restore performed *while the app is running* from pushing rolled-back data over newer data on other devices. The 3.5.1 note still applies: the cross-branch view needs the org branch-read routes in khayt-cloud (b3556a5), which ARE deployed — confirm with `curl -s -o /dev/null -w '%{http_code}' https://cloud.khaytapp.com/v1/shops/probe/org/keysets` (401 = present, 404 = not) |
| **Beta / RC** | **The 3.7.0 line is CLOSED** — promoted to stable as `v3.7.0` on 2026-09-11. Newest published pre-release remains **v3.7.0-beta.25** (2026-09-03, all three platforms), which was the promotion candidate and is superseded by the stable tag rather than withdrawn. `beta.25` is the review cut: twenty-two passes over the app and the cloud, and the money and data-safety fixes they turned up — a payment plan that billed a deposit twice, a VAT return declaring no VAT, two tablets overwriting each other, and an invoice QR that scanned and was invalid. It carries a `### Before you update` section for the Folder-to-Group rename. `beta.24` was the first release to carry one: it MOVES DATA — model previews leave the store for the folders beside the models — so the update asks the shop to accept that before it will download. `beta.23` is the cut a shop with large models needs: a print file over about 50 MB used to join the library holding no print time, no weight, no material and no picture, and say nothing about it. `beta.18` carries a security fix — a printer camera's content-type header could escape the image tag and run script in the app. It is named `-beta.N` rather than `-rc` because an `-rc` is invisible to existing beta installs (see VERSIONING.md). The line carries the content-language work — a shop writes in one or two of nine languages — and the eighteen readers that had been treating a shop's own text as an English-or-Arabic pair: two put a blank name into messages sent to customers, two submitted ZATCA e-invoices with no seller street, and one (the server's catalogue whitelist, silently dropping every field the app sent) made the storefront feature inert in production. `beta.17` adds the storefront syncing the catalogue's own prices and photos, a print markable as not business, live printer state on the machines page, and hover descriptions that actually appear. **Do not recommend anything before `beta.17` to a shop that does not write English or Arabic**: its own name, its clients' names and the seller address on its ZATCA e-invoices all came out blank. |


Last verified 2026-09-11 (after the v3.7.0 publish; the beta.25 verification it replaces was 2026-09-03) against `gh release list`, `git ls-remote --tags origin`, and a fetch of every published manifest and every asset it names: all three manifests fetch 200 and all three read `version: 3.7.0-beta.25` — `latest-mac.yml` is a REAL manifest this time, not a carry-forward, because `BUILD_MAC` was set for this cut — and the five binaries they name (the Windows setup, the mac zip and dmg, the AppImage and the deb) each serve 200. These rot fast — confirm with
`gh release list --repo KhaytApp/Khayt` rather than trusting the table.

## The 3.7.0 promotion gate — how it was settled (2026-09-11)

`v3.7.0` was tagged stable on 2026-09-11 from `main`. Two of the three
conditions below were met and **the third was waived deliberately**, by the
maintainer, on the day. Recorded here rather than left as a step that quietly
did not happen.

- **Seven consecutive days with no new cut: MET on the line, NOT on the
  artifact.** `v3.7.0-beta.25` was published 2026-09-03 and nothing was cut for
  eight days, and it was the build installed on the shop's Mac throughout. But
  `3.7.0` was NOT promoted from that commit: 225 commits had landed on `main`
  since, including the money corrections (revenue net of tax, the VAT paid on
  stock), the measured-actuals chain, and three dependency security fixes. The
  soak applies to the code people ran; the tag carries code they did not. That
  is the honest reading and it is why this entry says met-on-the-line rather
  than met.
- **macOS current at promotion: MET.** `BUILD_MAC` was set for the `v3.7.0` run,
  so `latest-mac.yml` is a real manifest and not a carry-forward.
- **Eviction exercised on a real library and brought back: WAIVED.** It still
  has never been done. It needs cloud-storage credentials the shop has not
  configured — the `s3` block in the store is development leftover, not a live
  backup — so there is no real library to evict to. The waiver is defensible
  only because **eviction is off until a shop sets it up**: no shop is running
  tiering, so the destructive path this condition was written to protect is one
  nobody can currently reach. **The condition is not retired.** It transfers to
  the first release that ships tiering ON, or to the first shop that configures
  a provider, whichever comes first. Do not read this waiver as a precedent for
  promoting a line whose destructive feature is live.

## The gate as it was written, and why

**Not a hold.** Nothing blocked a stable tag. This recorded the condition for
promoting the `3.7.0` line, because it had been implicit and the numbers said it
was not being met by accident. Kept for the next line, which gets the same test.

`v3.6.0` shipped stable on 2026-08-21. Between 2026-08-22 and 2026-08-27 the
`3.7.0` line ran **ten cuts in six days**. The gate this repo has always stated
for promotion is *real shop use*, and at that cadence no cut on this line has
ever had any: each one is superseded within hours by the next. `beta.9` and
`beta.10` were tagged on the same day.

That is a reasonable way to deliver fixes and a bad way to earn a stable tag,
and the difference matters more on this line than on the last one. `3.7.0`'s
headline feature is print-library tiering, and eviction is — in this file's own
words elsewhere — the only deliberately destructive thing in the print library.
It moves a shop's files off its disk. A line carrying that should not be
promoted on a soak that never happened.

**The condition, stated so it can be checked rather than felt:**

- **Seven consecutive days with no new cut on the line**, and the newest cut
  installed and used on a real shop for that whole window. Not seven days since
  the line opened — seven days in which the thing being promoted is the thing
  people are running.
- **macOS current at promotion.** Running two cuts behind is fine mid-line and
  is not fine for the build that becomes stable, so the promotion candidate is
  built with `BUILD_MAC` set.
- **Eviction exercised on a real library and brought back.** "Bring everything
  back" is the way out and it has never been the subject of a stated test.

Check the first with `git log` on the tags, not from memory:

```bash
gh release list --repo KhaytApp/Khayt --limit 5
```

Promotion was `node scripts/bump-version.js set 3.7.0` — `version:minor` would
have turned `3.7.0-beta.25` into `3.8.0`. See [VERSIONING.md](../VERSIONING.md).

**Replace-vs-promote is still decided on the day**, with
`git rev-list --count <tag>..origin/main` and an empty `[Unreleased]`. This
section says when the question may be asked, not what its answer is.

## While a hold is active

Beta tags (`v*-beta.*`) remain allowed. They publish as GitHub **pre-releases**
and do not move the stable latest pointer. `main` may still receive merges;
**stable** installers and auto-update feeds stay on the last published stable
tag until a deliberate stable release.

## Shipping a stable release

1. `npm run check`
2. Move `[Unreleased]` in `CHANGELOG.md` into `## [X.Y.Z]`
3. `node scripts/bump-version.js set X.Y.Z` — name the version explicitly.

   **Do not use `npm run version:minor` to promote a prerelease.** It increments
   the minor unconditionally, so promoting `3.6.0-rc.3` yields **3.7.0** — it
   skips the very version being promoted, and the number it lands on has no
   candidate behind it. `version:minor` is for opening a new line from a stable
   version, not for closing one. Same trap in the other direction: `version:beta`
   from an `rc` rolls the minor too. See [VERSIONING.md](../VERSIONING.md).
4. Commit, and tag `vX.Y.Z` on `main` — no prerelease suffix. Set `BUILD_MAC`
   for a stable tag and unset it afterwards: anything intended for stable should
   carry a mac build, and the variable is sticky at 10x the minutes.
5. Push the tag only then; that is what triggers the release build. Push it to
   the remote pointing at **KhaytApp/Khayt** (`git remote -v` — `origin` in a
   direct clone, usually `upstream` from a fork). A tag pushed to a fork builds
   nothing and fails silently, because there is no workflow there to fail.
