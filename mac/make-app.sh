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

# ── THE MAC APP'S OWN VERSION, NOT ELECTRON'S ────────────────────────────
#
# This read `package.json`, which numbers the ELECTRON app. The two ship on
# their own schedules now, and a Mac build calling itself `3.7.0` because that
# is where Electron happened to be was lying about which app it is.
# `mac/version.json` is the one source; see mac/VERSION.md.
VERSION="$(node -p "require('$REPO/mac/version.json').version" 2>/dev/null || echo "")"
BUILD_VERSION="$(node -p "require('$REPO/mac/version.json').build" 2>/dev/null || echo "")"
if [ -z "$VERSION" ] || [ -z "$BUILD_VERSION" ]; then
  echo "cannot read mac/version.json — refusing to build an app with no version." >&2
  exit 1
fi

# ── CFBundleVersion IS AN INTEGER THAT ONLY GOES UP ──────────────────────
#
# It used to be the marketing string with the suffix stripped, which is fine
# until two releases share a prefix:
#
#     4.0.0-alpha.1 → 4.0.0
#     4.0.0-alpha.2 → 4.0.0     ← the same number
#
# SPARKLE COMPARES THIS FIELD. Two consecutive alphas carrying the same
# CFBundleVersion means every tester is told they are up to date, and nothing
# anywhere reports an error — the build is fine and the feed is fine. So the
# build number is its own integer, bumped by scripts/bump-mac-version.js, and
# a release that forgot to move it fails test/mac-version.test.js.

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
  <key>LSMinimumSystemVersion</key><string>26.0</string>
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

# ── THE APP'S OWN ENTITLEMENTS, AND WHY THERE IS EXACTLY ONE ──────────────
#
# The app is NOT sandboxed — it reads a shop's print library from wherever the
# shop keeps it, spawns the slicer the shop chose, and polls printers on the
# LAN. Sandboxing it is a real piece of work (security-scoped bookmarks for
# every library folder) and is not what this entitlement is for.
#
# `allow-jit` is, and it is not optional for this app. Apple's own
# documentation for `com.apple.security.cs.allow-jit` lists, as its FIRST
# example of something that needs it, "the fast-path of the JavaScriptCore
# framework" — and says that without it "frameworks that rely on just-in-time
# (JIT) compilation may fall back to an interpreter".
#
# Khayt's Mac app runs 29,000 lines of tax, pricing, payment-plan and estimator
# rules in JavaScriptCore, unchanged, because reimplementing them in Swift
# would earn the right to be wrong a second way. Dropping all of that to the
# interpreter to save one line is not a trade worth making.
APP_ENTS="$PKG/.build/khayt.entitlements"
cat > "$APP_ENTS" <<'APPENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict>
</plist>
APPENTS
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
  <key>LSMinimumSystemVersion</key><string>26.0</string>
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

# ── SPARKLE, EMBEDDED AND POINTED AT ──────────────────────────────────────
#
# SwiftPM links `@rpath/Sparkle.framework/Versions/B/Sparkle` and gives the
# binary one rpath: `@loader_path`. Inside a bundle the executable is at
# `Contents/MacOS/Khayt` and the framework at `Contents/Frameworks/`, so
# without the rpath below the app links fine, builds fine, and dies at launch
# with "Library not loaded" — the failure arrives at the one moment nothing is
# watching.
SPARKLE_FW="$(find "$PKG/.build/artifacts/sparkle" -maxdepth 5 -name Sparkle.framework -path '*macos*' 2>/dev/null | head -1)"
if [ -n "$SPARKLE_FW" ] && [ -d "$SPARKLE_FW" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  # -R keeps the symlink farm a versioned framework is made of. Flattening it
  # gives a bundle codesign rejects.
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/Khayt" 2>/dev/null || true
  SPARKLE_EMBEDDED=1
else
  # Not fatal: the app checks for a feed before starting the updater, so a
  # build without Sparkle is one whose Check for Updates is greyed out.
  echo "  sparkle: framework not found — this build cannot update itself"
  SPARKLE_EMBEDDED=0
fi

# ── THE FEED, AND WHY IT IS NOT ALWAYS WRITTEN ────────────────────────────
#
# `SUFeedURL` only goes in when this build is one that will actually be
# published — `KHAYT_APPCAST` is set by the release workflow. A local build
# with a feed URL would check for updates against releases it is not, and
# offer to "update" a developer's working copy to the last published alpha.
#
# `SUPublicEDKey` is the PUBLIC half of the EdDSA key pair. Public: it is in
# every shipped copy of the app by design. The private half signs the archive
# and lives in a Keychain and in one CI secret; an attacker who replaces the
# download cannot produce a signature this key accepts.
SPARKLE_KEYS=""
if [ -n "${KHAYT_APPCAST:-}" ] && [ "$SPARKLE_EMBEDDED" = "1" ]; then
  SPARKLE_KEYS="  <key>SUFeedURL</key><string>${KHAYT_APPCAST}</string>
  <key>SUPublicEDKey</key><string>iXX6JdzKwbQCUdCd2kLwvUUVHNIE51LR01dYZa1uA6c=</string>
  <!-- Sparkle asks on first launch rather than deciding for the shop. -->
  <key>SUEnableAutomaticChecks</key><false/>"
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
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Khayt</string>
  <key>NSSupportsAutomaticTermination</key><false/>
$SPARKLE_KEYS
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
# ── HARDENED RUNTIME, AND A REAL TIMESTAMP ───────────────────────────────
#
# Both are REQUIRED for notarisation, and notarisation is what lets this app
# open on a Mac that did not build it. Without them the notary service refuses
# the submission outright, so an unnotarised build is not "a build that warns
# on first launch" — on any other Mac it is a build Gatekeeper will not run.
#
# It was `--timestamp=none` and no `--options runtime`, and the signature said
# so: `codesign -dvvv` printed `flags=0x0(none)` where a hardened build prints
# `flags=0x10000(runtime)`. That was correct while this was a local build
# nobody else ran; it is the first thing in the way of shipping one.
#
# A timestamp needs the network (Apple's TSA). `KHAYT_NO_TIMESTAMP=1` drops it
# for an offline build — which then cannot be notarised, and says so below
# rather than failing three steps later at `notarytool`.
STAMP="--timestamp"
[ -n "${KHAYT_NO_TIMESTAMP:-}" ] && STAMP="--timestamp=none"
# Ad-hoc signing and the hardened runtime do not go together: an ad-hoc
# signature cannot carry restricted entitlements, and `allow-jit` is one.
RUNTIME="--options runtime"
if [ "$IDENTITY" = "-" ]; then RUNTIME=""; fi

# ── SPARKLE'S OWN BINARIES, EACH ONE SIGNED ──────────────────────────────
#
# A framework is not one binary. Sparkle ships an updater app, a background
# installer and two XPC services inside itself, and every one is code that has
# to carry a signature — `codesign --deep` on the app does NOT reach them in a
# way notarisation accepts, which is why they are listed rather than swept.
#
# INNERMOST FIRST, for the reason the extensions are signed before the app: a
# signature covers what is inside it, so anything signed afterwards invalidates
# the thing that sealed it.
if [ "$SPARKLE_EMBEDDED" = "1" ]; then
  SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
  for PART in \
    "$SPARKLE_IN_APP/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE_IN_APP/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE_IN_APP/Versions/B/Updater.app" \
    "$SPARKLE_IN_APP/Versions/B/Autoupdate" \
    "$SPARKLE_IN_APP"; do
    [ -e "$PART" ] || continue
    if ! SP_ERR="$(codesign --force --sign "$IDENTITY" $STAMP $RUNTIME "$PART" 2>&1)"; then
      echo "codesign failed for $(basename "$PART"):"
      echo "$SP_ERR" | sed 's/^/  /'
      exit 1
    fi
  done
fi

for BUNDLE in "$EXT" "$PRV"; do
  if ! EXT_SIGN_ERR="$(codesign --force --sign "$IDENTITY" $STAMP $RUNTIME \
        --entitlements "$EXT_ENTS" "$BUNDLE" 2>&1)"; then
    echo "codesign failed for $(basename "$BUNDLE"):"
    echo "$EXT_SIGN_ERR" | sed 's/^/  /'
    exit 1
  fi
done

# The app LAST and with its own entitlements — `--entitlements` was missing
# here entirely, so whatever the app needed it did not get.
if ! APP_SIGN_ERR="$(codesign --force --sign "$IDENTITY" $STAMP $RUNTIME \
      --entitlements "$APP_ENTS" "$APP" 2>&1)"; then
  echo "codesign failed (identity: $IDENTITY):"
  echo "$APP_SIGN_ERR" | sed 's/^/  /'
  exit 1
fi
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

# ── NOTARISATION ──────────────────────────────────────────────────────────
#
# The step between "signed" and "a shop can open it". Gatekeeper on any Mac
# that did not build this app asks Apple whether Apple has seen it; without a
# notarisation ticket the answer is no and the app does not run.
#
# THE TICKET IS STAPLED INTO THE BUNDLE, which is what makes it work on a Mac
# that is offline or behind a filter that blocks Apple's check. Submitting and
# not stapling passes here and fails at a customer's desk, which is the worst
# place to find out.
#
# Credentials are the same three the Electron lane already uses. They are read
# from the environment, never written to disk, and never echoed.
notarize_app() {
  local missing=""
  [ -n "${APPLE_ID:-}" ]                    || missing="$missing APPLE_ID"
  [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] || missing="$missing APPLE_APP_SPECIFIC_PASSWORD"
  [ -n "${APPLE_TEAM_ID:-}" ]               || missing="$missing APPLE_TEAM_ID"
  if [ -n "$missing" ]; then
    echo "cannot notarise — missing:$missing" >&2
    echo "  These are the same credentials the Electron release uses." >&2
    return 1
  fi
  if [ "$IDENTITY" = "-" ]; then
    echo "cannot notarise an ad-hoc signed build — Apple requires a Developer ID." >&2
    return 1
  fi

  local zip="$DIST/Khayt-notarize.zip"
  rm -f "$zip"
  # `ditto`, not `zip`: a zip built by the shell tool loses the symlinks a
  # versioned framework is made of, and the notary service rejects what it is
  # handed rather than what was built.
  ditto -c -k --keepParent "$APP" "$zip"

  echo "  notarising (this waits on Apple, usually a few minutes)…"
  if ! xcrun notarytool submit "$zip" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait --timeout 30m; then
    echo "notarisation FAILED. The log above names the offending binary." >&2
    echo "  xcrun notarytool log <submission-id> --apple-id … for the detail." >&2
    rm -f "$zip"
    return 1
  fi
  rm -f "$zip"

  xcrun stapler staple "$APP" || { echo "stapling failed" >&2; return 1; }
  # And prove it took, rather than trusting that stapler said nothing.
  if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "the ticket did not staple — the app would fail on an offline Mac." >&2
    return 1
  fi
  # The real question, asked the way Gatekeeper asks it.
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
  echo "  notarised and stapled"
}

case "${1:-}" in
  --open)     open "$APP" ;;
  --install)  install_app "$@" ;;
  --notarize) notarize_app ;;
esac
