#!/usr/bin/env bash
# Build Khayt.app — a real, double-clickable Mac application.
#
# `swift run` is fine for working on the app and useless for testing it: no
# bundle, so no icon, no name in the menu bar, no Dock entry that survives a
# relaunch, and an activation policy the code has to set by hand. This assembles
# the same binary into the bundle macOS expects, signed so it opens.
#
#   ./mac/make-app.sh            # build, put it in mac/dist/Khayt.app
#   ./mac/make-app.sh --open     # …and launch it
#   ./mac/make-app.sh --install  # …and copy it to /Applications
#
# NOT the shipping build. It signs with whatever stable identity this Mac has
# (see the signing block below) and falls back to ad hoc, but it is not
# notarised and has no hardened runtime — those are what make it something a
# shop can download, and neither is here yet.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
PKG="$REPO/mac/KhaytCore"
DIST="$REPO/mac/dist"
APP="$DIST/Khayt.app"

VERSION="$(node -p "require('$REPO/package.json').version" 2>/dev/null || echo "0.0.0")"
# CFBundleVersion must be digits and dots only — "3.7.0-beta.25" is rejected and
# the app silently refuses to launch. The marketing string keeps the real name.
BUILD_VERSION="$(printf '%s' "$VERSION" | sed 's/[^0-9.].*$//' | sed 's/\.$//')"
[ -n "$BUILD_VERSION" ] || BUILD_VERSION="0.0.0"

# ── APP INTENTS ───────────────────────────────────────────────────────────
#
# Xcode discovers `AppIntent` types by running two steps SwiftPM does not: the
# compiler emits per-file CONST VALUES describing which types conform to which
# protocols, and `appintentsmetadataprocessor` turns those into the
# `Metadata.appintents` bundle the system reads. Without that bundle the intents
# compile, link, and are never seen by Shortcuts, Spotlight or Siri — the app
# would ship a verb nothing can call.
#
# So the const values are asked for here, and the processor is run below. The
# protocol list is ours because the SDK does not ship one; anything App Intents
# looks for has to be named in it or the type is not gathered.
AI_PROTOCOLS="$PKG/.build/appintents-protocols.json"
mkdir -p "$PKG/.build"
cat > "$AI_PROTOCOLS" <<'AIP'
["AppIntent","AppShortcutsProvider","AppEntity","AppEnum","EntityQuery",
 "EntityStringQuery","DynamicOptionsProvider","TransientAppEntity",
 "PersistentlyIdentifiable","SetValueIntent","AppIntentsPackage"]
AIP

echo "Building Khayt $VERSION (release)…"
swift build -c release --product Khayt --package-path "$PKG" \
  -Xswiftc -emit-const-values \
  -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
  -Xswiftc -Xfrontend -Xswiftc "$AI_PROTOCOLS"
BIN="$PKG/.build/release/Khayt"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Khayt"

# SwiftPM's resource bundles. `Bundle.module` looks in Bundle.main.resourceURL
# first, so Contents/Resources is where they have to be — left beside the binary
# they are found in a `swift run` and not in the app, which fails as a missing
# module at the first call into the engine.
for b in "$PKG"/.build/release/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

cp "$REPO/assets/icon.icns" "$APP/Contents/Resources/Khayt.icns"

# The App Intents metadata, into Resources BEFORE signing — it is part of what
# is signed, and a bundle whose metadata arrives afterwards fails verification.
AI_TOOL="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor"
if [ -x "$AI_TOOL" ]; then
  find "$PKG/Sources/KhaytApp" -name '*.swift' > "$PKG/.build/ai-sources.txt"
  find "$PKG/.build/release/KhaytApp.build" -name '*.swiftconstvalues' \
    > "$PKG/.build/ai-const.txt" 2>/dev/null || true
  if [ -s "$PKG/.build/ai-const.txt" ]; then
    "$AI_TOOL" \
      --output "$APP/Contents/Resources" \
      --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
      --module-name KhaytApp \
      --sdk-root "$(xcrun --show-sdk-path)" \
      --xcode-version "$(xcodebuild -version | tail -1 | awk '{print $3}')" \
      --platform-family macOS --deployment-target 14.0 \
      --target-triple arm64-apple-macosx14.0 \
      --source-file-list "$PKG/.build/ai-sources.txt" \
      --swift-const-vals-list "$PKG/.build/ai-const.txt" >/dev/null 2>&1 \
      && echo "  app intents: $(python3 -c "import json,sys;d=json.load(open('$APP/Contents/Resources/Metadata.appintents/extract.actionsdata'));print(len(d.get('actions',{})))" 2>/dev/null || echo '?') actions"
  else
    echo "  app intents: no const values — Shortcuts and Siri will not see them"
  fi
else
  echo "  app intents: no Xcode toolchain — skipped"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Khayt</string>
  <key>CFBundleDisplayName</key><string>Khayt</string>
  <key>CFBundleExecutable</key><string>Khayt</string>
  <!-- NOT app.khayt.hub. That is the Electron app, and two applications
       sharing an identifier confuses Launch Services, the defaults domain and
       the Keychain's idea of who is asking. -->
  <key>CFBundleIdentifier</key><string>app.khayt.mac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>CFBundleIconFile</key><string>Khayt</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Khayt</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <!-- A job being dragged across the board. Declared so the drag is this app's
       own: a board that accepted any dragged text would move a job because
       someone dropped a word on it. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>app.khayt.mac.job</string>
      <key>UTTypeDescription</key><string>Khayt job</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# SIGN WITH A STABLE IDENTITY IF THIS MAC HAS ONE.
#
# An ad-hoc signature — `--sign -` — carries no identity: what macOS remembers
# about the app is its own content hash, so every rebuild is a DIFFERENT
# APPLICATION and everything granted to the last one is granted to nothing.
#
# The bill is the Keychain. Khayt keeps the cloud token and the printer API keys
# there, and the first read by an unrecognised application raises a permission
# dialog. Ad hoc means every single build raises it again — the app sat at 0%
# CPU behind one for twenty minutes, twice in a day, before this was understood.
#
# A real certificate fixes the identity. Signed with a Developer ID the
# requirement becomes the Team ID:
#
#   designated => identifier "Khayt" and anchor apple generic
#                 and certificate leaf[subject.OU] = "<team>"
#
# — which is the same on the next build, and the next. A grant given once holds.
#
# Order: an explicit override, then Developer ID (also valid on other Macs, and
# the identity a notarised build would use), then Apple Development, then ad hoc.
# `find-identity -v` lists only identities whose certificate is valid and whose
# private key is present, so anything it prints can actually sign.
#
# Matched by SHA-1, not by name: the names contain parentheses and a substring
# match on two identities is an error rather than a choice.
pick_identity() {
  if [ -n "${KHAYT_SIGN_IDENTITY:-}" ]; then echo "$KHAYT_SIGN_IDENTITY"; return; fi
  local list; list="$(security find-identity -v 2>/dev/null || true)"
  local kind
  for kind in "Developer ID Application:" "Apple Development:"; do
    local line; line="$(printf '%s\n' "$list" | grep -F "$kind" | head -1)"
    [ -n "$line" ] && { printf '%s\n' "$line" | awk '{print $2}'; return; }
  done
  echo "-"
}
IDENTITY="$(pick_identity)"

codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1 \
  || { echo "codesign failed (identity: $IDENTITY)"; exit 1; }
codesign --verify --deep --strict "$APP" 2>&1 | sed 's/^/  /' || true

# Print what it was signed as, because the difference is invisible in the bundle
# and it is the thing that decides whether the Keychain asks again.
if [ "$IDENTITY" = "-" ]; then
  echo "  signed: ad hoc — no stable identity on this Mac, so the Keychain will"
  echo "          ask again after every build. A Developer ID or an Apple"
  echo "          Development certificate in the login keychain stops that."
else
  echo "  signed: $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
fi

echo "Built $APP"
du -sh "$APP" | sed 's/^/  /'

# Installing over a RUNNING app is not safe, and it is quiet about it.
#
# `rm -rf` deletes the bundle a running process is still reading from. The
# executable itself survives — the kernel holds the inode — so the app carries
# on, and every resource it has not paged in yet is simply gone: the bundled
# business rules, the locale catalogues, the sample shop, the invoice
# stylesheet. What that produces is not a clean failure, it is whatever the
# first missing file happens to break, and it looks exactly like a bug in
# whatever the shop was doing at the time.
#
# It also does not do what the person running it thinks. A running app keeps
# the build it launched with; replacing the bundle changes what the NEXT launch
# gets and nothing about the one on screen.
installed="/Applications/Khayt Native.app"
install_app() {
  if pgrep -f "Khayt Native.app/Contents/MacOS/Khayt" >/dev/null 2>&1; then
    if [ "${2:-}" = "--force" ]; then
      echo "Khayt Native is running — installing over it anyway, as asked." >&2
    else
      echo "Khayt Native is RUNNING. Not installing over it." >&2
      echo "  Quit it first, then run this again. The running app would keep the" >&2
      echo "  build it launched with in any case, and replacing the bundle under" >&2
      echo "  it can break it in ways that look like something else." >&2
      echo "  ./mac/make-app.sh --install --force  overrides this." >&2
      exit 1
    fi
  fi
  rm -rf "$installed"
  cp -R "$APP" "$installed"
  echo "Installed to $installed"
  echo "If it was open, quit and reopen it — a running app keeps the build it started with."
}

case "${1:-}" in
  --open)    open "$APP" ;;
  --install) install_app "$@" ;;
esac
