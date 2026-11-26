#!/bin/bash
# Release the Mac app with the build made on THIS Mac: the same checks as
# .github/workflows/mac-release.yml, in about fifteen minutes instead of two
# hours on a hosted runner, nearly all of which was compiling.
#
#   ./mac/release-local.sh            a prerelease (every 4.0 alpha)
#   ./mac/release-local.sh --final    a full release
#   RELEASE_SHA=<sha> ./mac/release-local.sh   the same, built from that commit
#                                     on main (the cut's merge), not main's tip
#
# IN TWO STEPS, so a person can install the build before anyone else can:
#   RELEASE_SHA=<sha> ./mac/release-local.sh --draft-only
#                         build, notarise, check and upload the DRAFT, then
#                         STOP: nothing is signed, nothing is public, no
#                         install is told. The draft can be downloaded by
#                         whoever may see drafts, and installed by hand.
#   RELEASE_SHA=<sha> ./mac/release-local.sh --publish
#                         later, once it has been seen to work: no build;
#                         the draft for this version must exist, and the
#                         rest happens as below (sign, the feed, public).
# Both take --final as well.
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

say()  { printf '\n== %s\n' "$*"; }
fail() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }

PRERELEASE=1
DRAFT_ONLY=0
PUBLISH_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --final) PRERELEASE=0 ;;
    --draft-only) DRAFT_ONLY=1 ;;
    --publish) PUBLISH_ONLY=1 ;;
    *) fail "unknown option '$arg' (--final, --draft-only, --publish)" ;;
  esac
done
[ "$DRAFT_ONLY" = 1 ] && [ "$PUBLISH_ONLY" = 1 ] && fail "--draft-only and --publish are the two halves: run one, then the other"
PROFILE="${NOTARY_PROFILE:-khayt}"
FEED_URL="https://khaytapp.com/mac/appcast.xml"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WT="${KHAYT_RELEASE_DIR:-$HOME/Khayt-release}"

# ── BEFORE TEN MINUTES OF BUILDING, EVERYTHING THAT CAN REFUSE ──────────
say "checking what this needs"
command -v gh >/dev/null   || fail "needs the gh CLI, signed in"
command -v node >/dev/null || fail "needs node"
# notarytool keeps its profile where only an UNLOCKED Mac can read it, so a
# run while the screen is locked reports "No Keychain password item found"
# for a profile that is there. Seen on the first overnight release attempt:
# the same profile had worked hours earlier with somebody at the machine.
# Say what Apple said: a 403 for an unsigned or expired developer agreement
# came out here as "unlock the screen" while somebody sat at the Mac (Nov 13).
# Not asked by --publish, which builds and notarises nothing.
[ "$PUBLISH_ONLY" = 1 ] || notary_err=$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1 >/dev/null) \
  || fail "cannot use the notarytool profile '$PROFILE'. Apple said:
  $(printf '%s' "$notary_err" | head -3)
  403 'required agreement': sign it at developer.apple.com/account (Agreements), then run this again.
  'No Keychain password item found': unlock the screen, or save it once with
    xcrun notarytool store-credentials $PROFILE"

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
# RELEASE_SHA pins the build to a commit already on main, normally the cut's
# merge, so main need not stay frozen while a locked Mac waits to release
# (beta.41 waited six hours for an unlock). Unset, it builds main as before.
WHAT="${RELEASE_SHA:-origin/main}"
git -C "$REPO_DIR" merge-base --is-ancestor "$WHAT" origin/main \
  || fail "$WHAT is not on main — release only what main holds"
if [ -d "$WT/.git" ] || [ -f "$WT/.git" ]; then
  git -C "$WT" checkout -q --detach "$WHAT"
  git -C "$WT" reset -q --hard "$WHAT"
else
  git -C "$REPO_DIR" worktree add -q --detach "$WT" "$WHAT"
fi
cd "$WT"

# ── THE "BEFORE YOU UPDATE" ITEMS SHIP INSIDE THE APP ────────────────────
# The first-launch sheet ("Khayt was updated") reads this release's items
# from lib/release-gates.json, generated from CHANGELOG.md. A cut whose file
# was not regenerated ships a sheet that says nothing about this release.
#
# HERE, in the release worktree, and not at the top of the script: what ships
# is origin/main as checked out in "$WT", not whatever checkout this was
# started from, and mac/sync-js.sh WRITES (harmless in a tree that is reset
# on every run, not in somebody's working copy).
node scripts/write-release-gates.js --check \
  || fail "lib/release-gates.json on origin/main is stale — run 'npm run release:gates', land it with the cut, and start again"
bash mac/sync-js.sh >/dev/null
git diff --quiet -- mac/KhaytCore/Sources/KhaytCore/JS/release-gates.json \
  || fail "the bundled release-gates.json on origin/main is not lib's — run mac/sync-js.sh, land what it writes, and start again"
# And everything else sync-js.sh writes: the bundled modules, the locales and
# the Resources copies. The build below compiles THIS tree, so a module that
# drifted from lib/ on main would otherwise ship lib's version silently, with
# no commit that says so (review Nov 26, L1). Untracked counts too: a module
# newly on the list but never copied in.
DRIFT="$(git status --porcelain -- mac/KhaytCore/Sources/KhaytCore/JS/ \
  mac/KhaytCore/Sources/KhaytApp/Resources/invoice.css \
  mac/KhaytCore/Sources/KhaytApp/Resources/filament-catalog.json)"
[ -z "$DRIFT" ] || fail "the bundled JS on origin/main is not lib's — run mac/sync-js.sh, land what it writes, and start again:
$DRIFT"

V="$(node -p "require('./mac/version.json').version")"
B="$(node -p "require('./mac/version.json').build")"
TAG="v$V"
echo "  Khayt for macOS $V (build $B), from $(git rev-parse --short HEAD)"
DRAFT="$(gh release view "$TAG" -R KhaytApp/khayt-mac --json isDraft --jq .isDraft 2>/dev/null || true)"
[ "$DRAFT" = "false" ] && fail "$TAG is already published — cut the next version before releasing"
node scripts/changelog-section.js "$V" >/dev/null 2>&1 \
  || fail "CHANGELOG.md has no section for $V — the release would ship without notes"
node scripts/changelog-fold.js --check >/dev/null 2>&1 \
  || fail "changelog.d/ still holds fragments — run npm run changelog:fold and land it, or those entries miss these notes"

echo "  notary profile, version: ok"

# ── SIGN, MAKE PUBLIC, TELL EVERY INSTALL: mac-publish.yml ──────────────
# The ONLY place this script dispatches anything. --draft-only never reaches
# it (test/mac-release-draft-only.test.js runs the script and proves it).
publish() {
  say "signing and publishing on GitHub (a few minutes)"
  PRE=true; [ "$PRERELEASE" = 1 ] || PRE=false
  BEFORE="$(gh run list -R KhaytApp/Khayt --workflow mac-publish.yml --limit 1 --json databaseId --jq '.[0].databaseId // 0')"
  # sha: the commit this build is from, so the publish checks and scripts
  # against IT and not against main's tip, which may have moved on (L2).
  gh workflow run mac-publish.yml -R KhaytApp/Khayt --ref main -f tag="$TAG" -f prerelease="$PRE" -f publish_appcast=true \
    -f sha="$(git rev-parse HEAD)"
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
}

# The second half: the draft must be there, and nothing is built.
if [ "$PUBLISH_ONLY" = 1 ]; then
  [ "$DRAFT" = "true" ] || fail "there is no draft of $TAG to publish — run --draft-only first"
  publish
  exit 0
fi

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
# The release carries its own "Before you update" items, in every language:
# a Mac on an OLDER version reads them from here before it downloads this one
# ("An update is ready", UpdateGate.swift). The same file the app bundles,
# checked fresh above. Without it that Mac offers the update as before and
# the new app's first-launch sheet shows the items instead.
gh release upload "$TAG" lib/release-gates.json -R KhaytApp/khayt-mac --clobber
rm -f "$NOTES"

if [ "$DRAFT_ONLY" = 1 ]; then
  say "stopped at the draft: nothing is signed, public or offered to any install"
  echo "  Draft:   https://github.com/KhaytApp/khayt-mac/releases/tag/$TAG  (visible to whoever may see drafts)"
  echo "  Archive: $ARCHIVE (build $B), here, to install by hand and try"
  echo "  When it has been seen to work, publish it (no build):"
  echo "    RELEASE_SHA=$(git rev-parse HEAD) ./mac/release-local.sh --publish$([ "$PRERELEASE" = 1 ] || printf ' --final')"
  exit 0
fi

publish
