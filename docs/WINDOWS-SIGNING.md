# Windows code signing (Bed Ready + Khayt)

Right now the Windows installers (`*-Setup.exe`, `*-portable.exe`) ship **unsigned**.
On a clean machine that means a **SmartScreen "Windows protected your PC"** warning and,
in some enterprise/AV setups, the download being quarantined. Signing removes the warning
and (after enough installs, or immediately with an EV cert) builds SmartScreen reputation.

This doc explains the options and exactly how to turn signing on. The build configs and CI
are already wired so that **once the signing secrets exist, signing activates
automatically** — no code change needed. Until then builds stay unsigned.

---

## STATUS: Windows stays UNSIGNED, and this is settled, not pending

Two independent reasons, either of which is enough on its own:

**1. We are not eligible for the cheap option.** Azure Trusted Signing — since renamed
**Azure Artifact Signing** — restricts Public Trust certificates by country, and Saudi
Arabia is on neither list. From
[Microsoft's prerequisites](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)
(checked 2026-08-04):

> Public Trust certificates are available to organizations in the United States, Canada, the
> European Union, the United Kingdom, Australia, New Zealand, Japan, South Korea, Singapore,
> Switzerland, Norway, and Israel. Individual developers must be located in the United States
> or Canada.

Private Trust has no geographic restriction and is **not a workaround**: those certificates
are not publicly trusted, so they do nothing for SmartScreen on a public download. Also worth
knowing before anyone tries: Artifact Signing rejects free, trial and sponsored Azure
subscriptions.

**2. Everything we ARE eligible for was priced and declined.** Cloud-HSM signing from a
global CA (DigiCert KeyLocker, SSL.com eSigner) runs ~$400+/yr; an EV token is ~$300–500/yr
*and* cannot work on a GitHub-hosted runner. Decision on 2026-08-04: **too expensive.** This
is the second deferral — the first (2026-07-11) was against EV tokens, before the $10/mo
option looked available. Do not re-propose either tier; wait to be asked.

**What to do instead:** nothing. Windows installers ship unsigned, SmartScreen warns, and the
bedready README already tells users *More info → Run anyway*. Revisit only if Microsoft adds
Saudi Arabia to the eligible list, or if the business is ever incorporated somewhere on it.

**The CI wiring is done and costs nothing to leave in place** — see
[What is already built](#what-is-already-built). It is CA-agnostic: anything that signs via
`signtool` drops into the same slot.

---

## What is already built

Merged 2026-08-04 (KhaytApp/Khayt#622, KhaytApp/bedready#2), inert without secrets:

- The Bed Ready release workflow has a signing step and a feed re-hash step, both gated on
  `env.AZURE_CLIENT_ID != ''`. With no secrets they skip and the build is byte-identical to
  an unsigned one.
- `scripts/repatch-update-feed.mjs` recomputes `sha512` + `size` in `latest*.yml` after
  anything rewrites an artifact. **This is required for ANY post-build signing, not just
  Azure's** — see the warning in [Path A](#path-a--azure-artifact-signing-not-available-to-us).
  It also replaces the by-hand `latest-mac.yml` edit after every macOS `stapler staple`.

Neither has ever run against a real certificate. The first signed release must be verified by
hand — see [How to verify a signed build](#how-to-verify-a-signed-build).

| Option | Cost | Eligible for us? | CI-friendly | SmartScreen |
|---|---|---|---|---|
| **Azure Artifact Signing** | ~$10/mo | ❌ **no — country** | ✅ yes | reputation-based |
| DigiCert KeyLocker / SSL.com eSigner | ~$400+/yr | likely, unverified | ✅ yes | reputation or instant (EV) |
| EV cert on USB token | ~$300–500/yr | likely, unverified | ❌ no (physical token) | ✅ instant |
| Legacy `.pfx` (pre-2023 OV or eSigner PFX) | varies | only if already held | ✅ yes | reputation-based |

> **Why not "just buy an OV cert and use the .pfx"?** Since June 2023 the CA/Browser Forum
> requires the private key of a **newly issued** OV (and EV) code-signing cert to live on a
> FIPS-140 HSM or hardware token. CAs no longer hand you an exportable `.pfx`. So a brand-new
> OV cert can't be used as a bare file in CI — it needs a cloud-HSM signing service or a
> physical EV token.

---

## Path A — Azure Artifact Signing (NOT available to us)

Kept for completeness and in case the country list changes. **Read the status section above
before starting any of this** — a paid Azure subscription is required to reach the identity
validation form, and Saudi Arabia does not appear in its country dropdown.

1. **Azure setup** (one-time):
   - Create/enter an Azure subscription.
   - Create a **Trusted Signing account** and a **Certificate Profile** (Public Trust).
   - Complete **identity validation** (individual or organization). This is the gating step;
     it can take a few days for orgs.
   - Create a service principal (App Registration) with the **Trusted Signing Certificate
     Profile Signer** role on the account, and note: tenant ID, client ID, client secret,
     the account endpoint (e.g. `https://weu.codesigning.azure.net`), account name, and
     profile name.

2. **Add repo secrets** (in `KhaytApp/bedready` → Settings → Secrets → Actions):
   - `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`
   - `AZURE_TS_ENDPOINT`, `AZURE_TS_ACCOUNT`, `AZURE_TS_PROFILE`

3. **Nothing to uncomment — the workflow is live.** The Bed Ready release workflow signs the
   Windows `.exe`s with `azure/trusted-signing-action` and then re-hashes the update feed,
   and both steps are **gated on `AZURE_CLIENT_ID` being set**. With no secrets they skip and
   the build is byte-identical to today's unsigned one; the moment the six secrets exist,
   signing turns on with no code change.

   > ⚠️ Order matters, and this is the part that bites. Signing changes the file bytes, so a
   > `latest.yml` hash computed *before* signing makes `electron-updater` reject the download
   > with a "sha512 mismatch" — and that failure reaches users mid-update, not CI. Because the
   > Azure action signs *after* electron-builder has already written the feed, the feed must be
   > re-hashed afterward. That is what `scripts/repatch-update-feed.mjs` does, and the workflow
   > runs it immediately after the signing step:
   >
   > ```bash
   > node scripts/repatch-update-feed.mjs build-bedready/latest.yml
   > ```
   >
   > It rewrites the `sha512` and `size` of every artifact it finds on disk, including the
   > **top-level `sha512`** that mirrors `path:` — the field a hand-edit forgets. If it matches
   > nothing it exits non-zero rather than reporting success over a stale feed.

   The same script replaces the manual macOS step: after `xcrun stapler staple` changes the
   `.dmg` bytes, run it against `latest-mac.yml` instead of editing the hash by hand.

A tighter alternative is an electron-builder `win.sign` hook so hashing is always post-signing
by construction. It needs the Trusted Signing dlib present at build time, which the GitHub
action handles for us — not worth the extra moving part unless signing moves off CI.

## Path B — `.pfx` file (legacy / eSigner)

Only viable if you have a `.pfx` whose private key you can export (pre-2023 OV cert, or an
SSL.com eSigner credential exported to PFX).

1. Base64-encode the `.pfx`: `base64 -i cert.pfx | pbcopy` (macOS).
2. Add secrets to `KhaytApp/bedready`:
   - `WIN_CSC_LINK` = the base64 string
   - `WIN_CSC_KEY_PASSWORD` = the PFX password
3. That's it. The Windows build already forwards these env vars to electron-builder (they are
   a **no-op when the secrets are absent**, so current unsigned builds are unaffected).
   electron-builder signs the `.exe`s and computes the update-feed hashes over the signed
   bytes automatically.

---

## Khayt (business app) note

The Khayt release workflow (`.github/workflows/release.yml`, `build-windows` job) has the same
`WIN_CSC_LINK` / `WIN_CSC_KEY_PASSWORD` lines pre-staged (commented, "uncomment when HARICA cert
is ready"). Khayt additionally ships an **MSIX/appx** to the Microsoft Store, which Partner
Center signs during certification — so the Store package needs no cert from us.

## How to verify a signed build

On Windows: right-click the `.exe` → Properties → **Digital Signatures** tab should list the
signer. Or in PowerShell:

```powershell
Get-AuthenticodeSignature .\BedReady-<ver>-win-x64-Setup.exe | Format-List Status, SignerCertificate
```

`Status` should be `Valid`. Then re-download via the app's auto-updater on a second machine to
confirm `electron-updater` accepts the (signed) payload — i.e. the `latest.yml` `sha512` matches.
