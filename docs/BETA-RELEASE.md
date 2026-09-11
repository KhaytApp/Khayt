# Beta releases

Khayt publishes **two release channels** on GitHub:

| Channel | Latest | GitHub | Auto-update |
|---------|--------|--------|-------------|
| **Stable** | `v3.7.0` (published 2026-09-11, all three platforms) | [Latest release](https://github.com/khaytapp/Khayt/releases/latest) | Default (beta off) |
| **Beta / RC** | **line closed** — `v3.7.0-beta.25` (published 2026-09-03, promoted to stable as `v3.7.0` on 2026-09-11; **do not recommend anything before it to a shop that does not write English or Arabic**: its own name, its clients' names and its ZATCA seller address came out blank) | [Pre-releases](https://github.com/khaytapp/Khayt/releases) (filter *Pre-release*) | Opt-in via Settings |

> Verified 2026-08-27 after the publish, against published tags and fetched
> manifests: `latest.yml` and `latest-linux.yml` read `3.7.0-beta.10`,
> `latest-mac.yml` reads `3.7.0-beta.8` in the relative carry form, and every
> asset they name serves 200. These rot fast — check with
> `gh release list --repo KhaytApp/Khayt` rather than trusting the table. **A
> version in `package.json` is evidence the cut landed, never that it shipped.**
>
> Every version above is written out in full on purpose:
> `scripts/check-release-claims.js` looks for the exact string in
> `package.json`, and a shorthand `beta.10` is invisible to it — and to anyone
> grepping these files at cut time, for the same reason.

> **`beta.4` sat bumped-but-untagged on `main` for most of a day** — `package.json`
> said `3.7.0-beta.4` while the newest installer a beta user could get was
> `beta.3`. It was tagged from `11ef165` and published on 2026-08-23. The check
> that would have caught it in seconds is `git ls-remote --tags origin`; the one
> that cannot is reading `package.json`, which records that the *cut* landed and
> says nothing about whether it *shipped*.
>
> **macOS is deliberately a cut or two behind.** A mac build bills at roughly
> 10× the others, so `BUILD_MAC` is set only for the cuts that bring it current.
> `beta.8` (2026-08-27) was such a cut and was built for all three platforms,
> ending a three-cut drift; `v3.7.0-beta.9` and `v3.7.0-beta.10` are Windows +
> Linux only, so
> macOS sits on `beta.8` and `carry-mac-manifest` carries that release's
> `latest-mac.yml` forward under each newer tag. Verified rather than assumed:
> the carried manifest uses the **relative** `../v3.7.0-beta.8/` form, not a
> verbatim copy, so both mac assets resolve 200 from the newer feed — a verbatim
> copy would name a file the newer release does not contain and 404 for exactly
> the users furthest behind.

## What beta includes

The open line is **`3.7.0-beta.x`**, and it is about the print library outgrowing
the disk it lives on.

**Your print library can be bigger than the machine it is on.** Khayt moves
models you have not opened in a while into cloud storage and takes them off this
computer, then downloads them again automatically the first time you open one.
The library looks unchanged — every model still listed, still at its real size,
marked as being in the cloud. Thumbnails never leave your disk, so browsing works
with no internet at all.

This is not the object-storage *backup* Khayt already had, and the difference is
the point: a backup is a second copy and frees nothing, so a 50 GB library became
50 GB here and 50 GB there. Tiering moves the file. Run both if you like — one
answers "the workshop burned down", the other "the laptop is full".

**Nothing is deleted until the cloud has provably received it.** Each file is
uploaded, then checked in a *separate* request against a checksum of the file on
your disk — not just its size, which a half-finished upload can match. Anything
that cannot be verified is left where it is and named in the result. **Bring
everything back** downloads the whole library again, which is the way out.

It also carries the things that make that usable: a provider dropdown covering
fifteen S3 hosts so the endpoint is built for you rather than typed from memory
(and, since `beta.4`, a link to each provider's signup page — because every other
field on that form is copied off a dashboard you need an account to see), Google
Drive as a backend if you already pay Google for storage, and cloud sync that
writes only what changed instead of the whole store.

It is a beta rather than stable because eviction is the only deliberately
destructive thing in the print library, and the delta write path had never run
against production before `beta.1`.

Shop data stays backward compatible across a beta line — backup/restore works
between channels, and new fields are additive and absent-safe.

Earlier lines are closed and their features are in stable: the `3.6.0-beta.x` /
`rc.x` line carried measured print costs, self-calibrating estimates, tax outside
the Gulf and four security fixes, all stable since **v3.6.0**; the `3.2.0-beta.x`
line carried QC / reprint / RMA, shipping & fulfillment, BOM assemblies, privacy
(PDPL) tooling, the scoped-token public API with a webhook event bus, opt-in
telemetry and per-printer cameras, all stable since **v3.2.0**. You do not need a
beta for any of them.

## Your quotes changed on the way to v3.6.0 — read this if you are on 3.5.x

**These are `3.6.0-beta.9` and `beta.10`, on the closed 3.6.0 line — not the open
`3.7.0-beta.x` one.** They have been in **stable v3.6.0** since 2026-08-21, so
this section is here for anyone still coming from 3.5.x, on either channel. If
you are already on 3.6.0 or any 3.7.0 beta, the change is behind you and nothing
below is pending.

If you price unsliced models and you are coming from `3.6.0-beta.8` or earlier,
the numbers moved — twice, for two different reasons. Re-check any quote you have
not yet sent. **Neither `beta.11` nor `beta.12` changed an estimate you had
already seen** — though from `beta.12`, **Slice for exact quote** fills in a
weight where it used to leave the box empty, so a quote made that way is fuller
than it was rather than different.

**`3.6.0-beta.9` — the estimate started using your own numbers.** Print time now comes
from jobs your printer measured rather than a shipped constant of about 35.7
g/hour, and material weight follows your **Default infill %** rather than a fixed
20%. Until then the customer intake form used your real settings while the
calculator did not, so the same file could come back from the two with different
answers.

**`3.6.0-beta.10` — a model you have printed before is priced from its own prints.**
One rate for the whole shop is the wrong shape for the number: measured across 67
finished jobs on one printer it ran from 1.9 to 48.6 g/hour, because it follows
the part's geometry, layer height and colour changes far more than the machine.
Name the model under **From your print library** and Khayt uses that model's own
finished prints instead — and the settings you printed it with, if you name those
too. The note also says how much of a number you are holding: *"26.4 g/h — the
middle of 3 finished prints of this model, give or take 1%"* rather than a bare
rate.

Figures that came from a slicer are unaffected. Those were never estimates, and
nothing recalculates them.

## Download beta

1. Open [GitHub Releases](https://github.com/khaytapp/Khayt/releases).
2. Enable **Pre-release**, or open the newest `-beta` tag directly.
3. Download the installer for your platform.

Settings → About shows a **Beta** badge on `-beta` builds.

## Opt-in beta updates (stable or beta)

**Settings → Data & Locale → Include beta pre-releases when checking for updates**

- **Off (default)** — stable releases only.
- **On** — beta pre-releases in in-app update checks.

Stored as `settings.betaUpdates`; synced on boot and save.

## Maintainer: when to cut, and what gets built

**Batch the line. Do not cut a beta per merge.** Each release is roughly 65
billable GitHub Actions minutes, and the account has already run past its 3,000
included minutes in a month where betas went out two days apart. A beta is worth
cutting when it carries something a shop can act on — a fix they are waiting for,
or a feature worth testing — not merely because `main` moved.

Rough guide: **one beta a week**, or sooner when a release is unblocking a
specific person (v3.6.0-beta.16 went out early because issue #364 was waiting on
four features it contained — that is the shape of a good exception).

**macOS is opt-in, and it is the reason a release costs what it does.** GitHub
bills macOS at **10×**; Windows at 2×, Linux at 1×. So one mac build costs more
than the other two platforms and the release PR's CI put together.

A tag builds **Windows + Linux only** unless you ask for macOS:

```bash
gh variable set BUILD_MAC --repo KhaytApp/Khayt --body true
# …push the tag, wait for the release…
gh variable delete BUILD_MAC --repo KhaytApp/Khayt      # it is sticky — unset it
```

macOS users are not stranded by a Windows/Linux-only release: the
`carry-mac-manifest` job copies `latest-mac.yml` forward from the last release
that **shipped a mac build**, so their update check resolves to the newest
version a mac binary actually exists for and reports "up to date" instead of
failing. Without that they would see **"Update check failed"** — a missing
`latest-mac.yml` 404s, which is the same fault the `bedready-v*` tag used to
cause.

It rewrites the file rather than copying it verbatim, and the difference is not
cosmetic. electron-updater builds the download URL from the tag the *feed*
pointed at, not from the version written inside the manifest, so a verbatim copy
names a file the release it now sits in does not contain:

    url: Khayt-<prev>-arm64-mac.zip
      -> /releases/download/<this tag>/Khayt-<prev>-arm64-mac.zip     404

The job therefore writes `../<prev>/<file>`, which the URL parser normalises back
onto the release that holds the binaries. The blockmap follows for free, being
derived from the already-resolved URL.

That bug shipped in five releases before it was found, and it hides unusually
well: a mac user already on the carried version compares it to what they are
running, is told they are up to date, and downloads nothing. Only a user further
back resolves it as an update and hits the 404. So "mac update checks still
work" is not evidence the carry is correct — the check that settles it is
whether the URL in the newest release's `latest-mac.yml` actually serves.

**So cut a mac build when the beta is one you want mac users on** — anything
touching the mac build itself, or a release you intend to promote to stable.

## Maintainer: cut the tag from GitHub instead of a laptop

Everything below still works and is the reference path. But the tag itself can
now be created from the Actions tab — **Cut release tag** → *Run workflow* —
which is what you want when whoever finished the release PR does not have a
checkout in front of them, or cannot push to `refs/tags/*` at all. That is not
hypothetical: `3.7.0-beta.4` was merged and left untagged for exactly that
reason.

Give it the version exactly as `package.json` spells it (`3.7.0-beta.4`, no
leading `v`) and, optionally, the commit — blank means the tip of `main`. **Name
the commit when anything landed on top of the release PR**, or you will tag a
tree whose `package.json` is right but whose contents are not what you tested.

It refuses rather than guesses. The commit must be on `main` (the only ref whose
required checks are enforced), `package.json` at that commit must say exactly the
version you asked for, `CHANGELOG.md` must already have a `## [version]` section,
and the tag must not exist. Then it pushes the tag and stops — `release.yml`
takes over on the tag push, unchanged.

**It needs the `RELEASE_TAG_TOKEN` secret** (a PAT or App token with
`contents: write`), and **that secret is configured** — added 2026-08-23 and
exercised against the live API, so this path is ready to use rather than
pending. It is not optional and not a preference: a tag pushed with the default
`GITHUB_TOKEN` **does not trigger other workflows**, so the obvious version of
this — tag with `GITHUB_TOKEN`, let `release.yml` notice — creates the tag and
then builds nothing, with every job green and no error anywhere. The workflow
refuses to start without the secret rather than hand you that.

The preflight asks GitHub whether the token still works, not merely whether the
secret is non-empty, because those are different questions and the gap between
them is a confusing failure later: an expired or revoked PAT is not empty, so it
would clear a presence check and then die inside `actions/checkout` as a git
credentials error naming neither the secret nor the reason. **If the token
carries an expiry date, that failure has a date too.** What you get instead:

| | |
|---|---|
| `401` | expired, revoked or malformed — mint a replacement and update the secret |
| `404` | a real token that cannot see this repo: wrong resource owner, repo missing from its list, or an org approval still pending |
| anything else | reported as "could not verify" — an unreachable API is not a bad token |

One thing preflight cannot tell you is whether the token has `contents: write`.
There is no read-only way to prove a write permission, so it says so rather than
showing a green check that means less than it looks. If the permission is
missing, the push at the end fails and no tag is created.

`BUILD_MAC` is unchanged: still a repository variable, still set before the tag
and unset after. The run's summary tells you which way it went.

## Maintainer: publish beta

```bash
npm run check                        # lint + unit suite
npm run check:changelog              # every shipped change carries a note
npm run check:globals                # nothing wired up but silently inert
npm run test:e2e:themes              # theme shells
# plus the feature smokes — `npm run` lists them all as test:e2e:*; the ones
# covering what THIS line (3.7.0) changed are:
#   :cloudstorage   — the provider dropdown, signup links and tiering controls
# the 3.6.0 line's, still worth running since that code is now stable:
#   :intake :intakequote :estimator :actuals :setups :filelink :dedupe
# and the standing set:
#   :qc :shipping :bom :privacy :assembly :apitokens :webhooks :webhookretry
#   :telemetry :printers :discovery :screens :a11y :quitflush :pollcache
#   :help :3mfworker
# Move CHANGELOG → ## [X.Y.Z-beta.N]
npm run version:beta
# Tag the version that command produced — never a literal from this file.
V=v$(node -p "require('./package.json').version")
git tag -a "$V" -m "$V" && git push upstream "$V"   # release CI runs on KhaytApp/Khayt
```

CI treats `-(beta|rc|alpha)` tags as GitHub **pre-releases**.
