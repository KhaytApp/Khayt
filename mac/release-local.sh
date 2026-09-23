#!/bin/bash
# Release the Mac app with the build made on THIS Mac: the same checks as
# .github/workflows/mac-release.yml, in about fifteen minutes instead of two
# hours on a hosted runner, nearly all of which was compiling.
#
#   ./mac/release-local.sh            a prerelease (every 4.0 alpha)
#   ./mac/release-local.sh --final    a full release
#
# It builds whatever `main` on GitHub holds, in its own worktree
# (~/Khayt-release), so the checkout you work in is never switched, and never
# edited under a ten-minute build. Cut the version first (bump-mac-version.js +
# its CHANGELOG section, merged), then run this.
#
# It builds, notarises and checks here, uploads the archive as a DRAFT release,
# and hands the rest to .github/workflows/mac-publish.yml: the Sparkle key
# lives only in the SPARKLE_PRIVATE_KEY secret, so the signature, the release
# going public and the feed happen there, in a few minutes, compiling nothing.
#
# Needs, once per Mac:
#   xcrun notarytool store-credentials khayt     (Apple ID, team, app password)
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
for wf in mac-release.yml mac-publish.yml; do
  for st in in_progress queued; do
    if gh run list -R KhaytApp/Khayt --workflow "$wf" --status "$st" \
         --json databaseId --jq '.[].databaseId' | grep -q .; then
      fail "a $wf run is still $st on GitHub — let it finish first"
    fi
  done
done

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
DRAFT="$(gh release view "$TAG" -R KhaytApp/khayt-mac --json isDraft --jq .isDraft 2>/dev/null || true)"
[ "$DRAFT" = "false" ] && fail "$TAG is already published — cut the next version before releasing"
node scripts/changelog-section.js "$V" >/dev/null 2>&1 \
  || fail "CHANGELOG.md has no section for $V — the release would ship without notes"

echo "  notary profile, version: ok"

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

# ── PACK, AND HAND IT TO GITHUB TO SIGN AND PUBLISH ─────────────────────
say "packing"
ARCHIVE="mac/dist/Khayt-$V.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$A" "$ARCHIVE"
echo "  $ARCHIVE ($(stat -f%z "$ARCHIVE") bytes)"

say "uploading $TAG as a draft to KhaytApp/khayt-mac"
NOTES="$(mktemp)"
node scripts/changelog-section.js "$V" > "$NOTES"
if [ "$DRAFT" = "true" ]; then
  # A draft left by a run that stopped after uploading: replace its archive.
  gh release upload "$TAG" "$ARCHIVE" -R KhaytApp/khayt-mac --clobber
else
  gh release create "$TAG" "$ARCHIVE" --repo KhaytApp/khayt-mac --draft \
    --title "Khayt for macOS $V" --notes-file "$NOTES"
fi
rm -f "$NOTES"

say "signing and publishing on GitHub (a few minutes)"
PRE=true; [ "$PRERELEASE" = 1 ] || PRE=false
BEFORE="$(gh run list -R KhaytApp/Khayt --workflow mac-publish.yml --limit 1 --json databaseId --jq '.[0].databaseId // 0')"
gh workflow run mac-publish.yml -R KhaytApp/Khayt --ref main -f tag="$TAG" -f prerelease="$PRE" -f publish_appcast=true
RUN=""
for _ in $(seq 1 30); do
  sleep 5
  RUN="$(gh run list -R KhaytApp/Khayt --workflow mac-publish.yml --limit 1 --json databaseId --jq '.[0].databaseId // 0')"
  [ "$RUN" != "$BEFORE" ] && break
done
[ -n "$RUN" ] && [ "$RUN" != "$BEFORE" ] || fail "the publish run did not start — the draft is uploaded; start mac-publish.yml with tag=$TAG"
gh run watch "$RUN" -R KhaytApp/Khayt --exit-status >/dev/null \
  || fail "the publish run failed: https://github.com/KhaytApp/Khayt/actions/runs/$RUN (the draft is still there; re-run it)"

say "done"
echo "  Release: https://github.com/KhaytApp/khayt-mac/releases/tag/$TAG"
echo "  Feed:    $FEED_URL  (GitHub Pages + the CDN take a few minutes to serve it)"
echo "  Build $B is what Sparkle compares."
