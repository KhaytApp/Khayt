#!/bin/bash
# Release the Mac app from THIS Mac: the same steps as
# .github/workflows/mac-release.yml, in about fifteen minutes instead of two
# hours on a hosted runner.
#
#   ./mac/release-local.sh            a prerelease (every 4.0 alpha)
#   ./mac/release-local.sh --final    a full release
#
# It builds whatever `main` on GitHub holds, in its own worktree
# (~/Khayt-release), so the checkout you work in is never switched, and never
# edited under a ten-minute build. Cut the version first (bump-mac-version.js +
# its CHANGELOG section, merged), then run this.
#
# Needs, once per Mac:
#   xcrun notarytool store-credentials khayt     (Apple ID, team, app password)
#   the Sparkle EdDSA key in the login Keychain  (generate_keys put it there)
# Neither ever leaves the Keychain. Run it in Terminal.app: the Keychain may ask
# to let sign_update use the key, and "Always Allow" makes that a one-off.
set -euo pipefail

PRERELEASE=1
[ "${1:-}" = "--final" ] && PRERELEASE=0
PROFILE="${NOTARY_PROFILE:-khayt}"
FEED_URL="https://khaytapp.com/mac/appcast.xml"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WT="${KHAYT_RELEASE_DIR:-$HOME/Khayt-release}"

say()  { printf '\n== %s\n' "$*"; }
fail() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }

# ── BEFORE TEN MINUTES OF BUILDING, EVERYTHING THAT CAN REFUSE ──────────
say "checking what this needs"
command -v gh >/dev/null   || fail "needs the gh CLI, signed in"
command -v node >/dev/null || fail "needs node"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "no notarytool profile '$PROFILE'. Run once:  xcrun notarytool store-credentials $PROFILE"

# Two releases racing would let the older feed land last and walk every
# install backwards, so a CI release in flight is a hard stop.
if gh run list -R KhaytApp/Khayt --workflow mac-release.yml --status in_progress \
     --json databaseId --jq '.[].databaseId' | grep -q .; then
  fail "a mac-release.yml run is still in progress on GitHub — let it finish first"
fi

git -C "$REPO_DIR" fetch -q origin main
if [ -d "$WT/.git" ] || [ -f "$WT/.git" ]; then
  git -C "$WT" checkout -q --detach origin/main
  git -C "$WT" reset -q --hard origin/main
else
  git -C "$REPO_DIR" worktree add -q --detach "$WT" origin/main
fi
cd "$WT"

V="$(node -p "require('./mac/version.json').version")"
B="$(node -p "require('./mac/version.json').build")"
TAG="v$V"
echo "  Khayt for macOS $V (build $B), from $(git rev-parse --short HEAD)"
if gh release view "$TAG" -R KhaytApp/khayt-mac >/dev/null 2>&1; then
  fail "$TAG is already published — cut the next version before releasing"
fi
node scripts/changelog-section.js "$V" >/dev/null 2>&1 \
  || fail "CHANGELOG.md has no section for $V — the release would ship without notes"

# sign_update ships inside the Sparkle package; the first build fetches it.
find_sign() { find mac/KhaytCore/.build/artifacts/sparkle -name sign_update -type f 2>/dev/null | head -1; }
SIGN="$(find_sign)"
if [ -z "$SIGN" ]; then
  (cd mac/KhaytCore && swift package resolve >/dev/null)
  SIGN="$(find_sign)"
fi
[ -x "$SIGN" ] || fail "sign_update not found in the Sparkle artifacts"
# Prove the key is reachable NOW, not after the build and notarisation.
PROBE="$(mktemp)"; echo probe > "$PROBE"
"$SIGN" -p "$PROBE" >/dev/null 2>&1 || { rm -f "$PROBE"; fail "sign_update cannot reach the Sparkle key in the login Keychain"; }
rm -f "$PROBE"
echo "  notary profile, Sparkle key, version: ok"

# ── BUILD, NOTARISE, STAPLE ─────────────────────────────────────────────
say "building (about ten minutes, silent for most of it)"
KHAYT_APPCAST="$FEED_URL" ./mac/make-app.sh
say "notarising"
NOTARY_PROFILE="$PROFILE" ./mac/make-app.sh --notarize

# ── THE CHECKS THE CI LANE MAKES, BEFORE ANYTHING IS PUBLISHED ──────────
say "checking the bundle"
A=mac/dist/Khayt.app
BUILT="$(plutil -extract CFBundleVersion raw "$A/Contents/Info.plist")"
[ "$BUILT" = "$B" ] || fail "the bundle says build $BUILT, version.json says $B — not the build just made"
FEED="$(plutil -extract SUFeedURL raw "$A/Contents/Info.plist" 2>/dev/null || true)"
KEY="$(plutil -extract SUPublicEDKey raw "$A/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$FEED" ] || fail "no SUFeedURL — it would ship unable to update itself"
[ -n "$KEY" ]  || fail "no SUPublicEDKey"
[ -d "$A/Contents/Frameworks/Sparkle.framework" ] || fail "Sparkle is not embedded"
xcrun stapler validate "$A" >/dev/null 2>&1 || fail "the notarisation ticket is not stapled"
"$A/Contents/MacOS/Khayt" --check-resources || fail "the bundle reaches outside itself for resources"

# ── PACK AND SIGN ───────────────────────────────────────────────────────
say "packing and signing"
ARCHIVE="mac/dist/Khayt-$V.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$A" "$ARCHIVE"
SIG="$("$SIGN" -p "$ARCHIVE")"
[ -n "$SIG" ] || fail "sign_update produced no signature"
echo "  $ARCHIVE ($(stat -f%z "$ARCHIVE") bytes), signed"

# ── PUBLISH: THE RELEASE FIRST, THE FEED AFTER ──────────────────────────
# A feed naming an asset that is not uploaded yet sends every install that
# checks in between to a 404.
say "publishing $TAG to KhaytApp/khayt-mac"
NOTES="$(mktemp)"
node scripts/changelog-section.js "$V" > "$NOTES"
FLAGS=()
[ "$PRERELEASE" = 1 ] && FLAGS=(--prerelease)
gh release create "$TAG" "$ARCHIVE" --repo KhaytApp/khayt-mac \
  --title "Khayt for macOS $V" --notes-file "$NOTES" ${FLAGS[@]+"${FLAGS[@]}"}
rm -f "$NOTES"

say "publishing the Sparkle feed"
SITE="$(mktemp -d)"
gh repo clone KhaytApp/khayt-website "$SITE/site" -- --depth 1 -q
node scripts/mac-appcast.js --archive "$ARCHIVE" --signature "$SIG" \
  --url "https://github.com/KhaytApp/khayt-mac/releases/download/$TAG/$(basename "$ARCHIVE")" \
  --notes-url "https://github.com/KhaytApp/khayt-mac/releases/tag/$TAG" \
  --out "$SITE/site/mac/appcast.xml"
node scripts/mac-site-version.js "$SITE/site/index.html" \
  || echo "  (could not update the version line on the site; the download link still resolves)"
git -C "$SITE/site" add mac/appcast.xml index.html
git -C "$SITE/site" commit -q -m "Khayt for macOS $V: the Sparkle feed" \
  || echo "  nothing to commit — the feed already names this build"
git -C "$SITE/site" push -q
rm -rf "$SITE"

say "done"
echo "  Release: https://github.com/KhaytApp/khayt-mac/releases/tag/$TAG"
echo "  Feed:    $FEED_URL  (GitHub Pages + the CDN take a few minutes to serve it)"
echo "  Build $B is what Sparkle compares."
