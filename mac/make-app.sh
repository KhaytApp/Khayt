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

swift build -c release --product KhaytThumbnail --package-path "$PKG"
swift build -c release --product KhaytPreview --package-path "$PKG"
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

# ── THE QUICK LOOK EXTENSION ──────────────────────────────────────────────
#
# What Finder shows for a .3mf. A .appex is a bundle like the .app is a bundle,
# so it is assembled the same way: a binary, an Info.plist and a signature of
# its own, signed before the app so the app's signature seals it in.
#
# TWO THINGS ARE LOAD-BEARING AND NEITHER IS OBVIOUS.
#
# The binary must have no Swift entry point. macOS 14+ launches a thumbnail
# extension through ExtensionKit, which looks for one in the binary FIRST and
# only falls back to NSExtensionPrincipalClass when it finds none. See
# `Package.swift`, which is where that is arranged, and `EntryPointTests`.
#
# The extension must be sandboxed. The extension point declares
# `EXSandboxProfileName = quicklook-thumbnail` (visible in `lsregister -dump`),
# and an .appex signed without `com.apple.security.app-sandbox` is registered,
# is matched, and then fails every request with QLThumbnailErrorDomain 102.
# The read entitlement is what lets it open the file it was handed.
EXT="$APP/Contents/PlugIns/KhaytThumbnail.appex"
mkdir -p "$EXT/Contents/MacOS"
cp "$PKG/.build/release/KhaytThumbnail" "$EXT/Contents/MacOS/KhaytThumbnail"
cat > "$EXT/Contents/Info.plist" <<EXTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>KhaytThumbnail</string>
  <key>CFBundleDisplayName</key><string>Khayt 3MF previews</string>
  <key>CFBundleExecutable</key><string>KhaytThumbnail</string>
  <key>CFBundleIdentifier</key><string>app.khayt.mac.thumbnail</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.quicklook.thumbnail</string>
    <key>NSExtensionPrincipalClass</key><string>KhaytThumbnailProvider</string>
    <key>NSExtensionAttributes</key>
    <dict>
      <key>QLSupportedContentTypes</key>
      <array><string>app.khayt.mac.three-mf</string></array>
      <key>QLThumbnailMinimumDimension</key><integer>32</integer>
    </dict>
  </dict>
</dict>
</plist>
EXTPLIST
# OUTSIDE the bundle. Written into it — even into the bundle root — codesign
# refuses the whole appex with "unsealed contents present in the bundle root",
# because anything inside a bundle has to be part of what is sealed.
EXT_ENTS="$PKG/.build/thumbnail.entitlements"
# ── THE QUICK LOOK PREVIEW ────────────────────────────────────────────────
#
# What the SPACE BAR shows, as opposed to what the icon shows. Assembled exactly
# like the thumbnail extension above and subject to both of the same rules: no
# Swift entry point in the binary, and sandboxed. One extension point per .appex
# is why this is a second bundle rather than a second class in the first.
PRV="$APP/Contents/PlugIns/KhaytPreview.appex"
mkdir -p "$PRV/Contents/MacOS" "$PRV/Contents/Resources"
cp "$PKG/.build/release/KhaytPreview" "$PRV/Contents/MacOS/KhaytPreview"

# IT NEEDS ITS OWN COPY OF THE RULES. This extension reads the print settings
# through the shared engine, and `Bundle.module` resolves against the bundle it
# is running in — which for an extension is the .appex, not the app around it.
# Without this it launches, finds its extension point, and dies on
# `Fatal error: could not load resource bundle` the moment a preview is asked
# for; Quick Look then falls back to scaling the thumbnail, so what a person
# sees is a preview that looks almost right and has no facts under it.
#
# The thumbnail extension does NOT need this and does not get it: it reads the
# zip and picks a member, and never builds an engine. 1.4 MB is worth carrying
# once, not twice.
for b in "$PKG"/.build/release/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$PRV/Contents/Resources/"
done
cat > "$PRV/Contents/Info.plist" <<PRVPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>KhaytPreview</string>
  <key>CFBundleDisplayName</key><string>Khayt 3MF preview</string>
  <key>CFBundleExecutable</key><string>KhaytPreview</string>
  <key>CFBundleIdentifier</key><string>app.khayt.mac.preview</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.quicklook.preview</string>
    <key>NSExtensionPrincipalClass</key><string>KhaytPreviewController</string>
    <key>NSExtensionAttributes</key>
    <dict>
      <key>QLSupportedContentTypes</key>
      <array><string>app.khayt.mac.three-mf</string></array>
      <key>QLSupportsSearchableItems</key><false/>
    </dict>
  </dict>
</dict>
</plist>
PRVPLIST

cat > "$EXT_ENTS" <<'EXTENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.files.user-selected.read-only</key><true/>
</dict>
</plist>
EXTENTS

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
    <!-- WHAT A .3mf IS. macOS does not know: mdls on one of this shop's
         models reports a dyn.* placeholder, which is what a type nobody has
         declared looks like. No icon, no preview, no kind.

         NO BACKTICKS IN THIS HEREDOC. It is unquoted so that $VERSION expands,
         which means the shell also runs anything in backticks — a prose comment
         mentioning a command substituted that command's help text into the
         plist, silently, and it took a lint to notice.

         EXPORTED rather than imported, which is the uncomfortable half. An
         imported declaration says "somebody else owns this type and here is
         what I know about it", and that would be the honest shape — except
         nobody has declared one. The 3MF Consortium publishes the format and
         not a UTI, and neither OrcaSlicer nor Bambu Studio declares one, which
         is why a Mac with both installed still shows a blank page. So this
         declares its own, in this app's namespace rather than in Microsoft's
         or the consortium's, and it will sit quietly beside a real one if a
         real one ever arrives. -->
    <dict>
      <key>UTTypeIdentifier</key><string>app.khayt.mac.three-mf</string>
      <key>UTTypeDescription</key><string>3D Manufacturing Format</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>3mf</string></array>
        <key>public.mime-type</key><array><string>model/3mf</string></array>
      </dict>
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

# INSIDE OUT: a bundle's signature covers what is within it, so the extension is
# signed first and the app's signature seals that in.
# The output is captured rather than thrown away, because codesign's refusals
# are specific and the reason is the whole message: an entitlements file written
# INSIDE the bundle gets "unsealed contents present in the bundle root", which
# says exactly what is wrong and says nothing at all down /dev/null.
for BUNDLE in "$EXT" "$PRV"; do
  if ! EXT_SIGN_ERR="$(codesign --force --sign "$IDENTITY" --timestamp=none \
        --entitlements "$EXT_ENTS" "$BUNDLE" 2>&1)"; then
    echo "codesign failed for $(basename "$BUNDLE"):"
    echo "$EXT_SIGN_ERR" | sed 's/^/  /'
    exit 1
  fi
done

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
