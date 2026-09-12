#!/usr/bin/env bash
# Re-copy Khayt's pure business modules into the Mac app's bundle.
#
# lib/ is the one source of truth. These copies exist only because SPM resources
# must live inside the package. BundledLogicIsNotAForkTests fails if they drift,
# and this is how you fix that — never by editing the copy.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="mac/KhaytCore/Sources/KhaytCore/JS"
mkdir -p "$DEST"
# The range ends at the closing bracket ON ITS OWN LINE, not at the first `]`
# anywhere. A comment inside the list that mentions `settings.slicers[]` ended
# the range early and silently synced a SHORTER list — the modules below the
# comment simply stopped being copied, which is drift that reports itself as
# nothing at all. Found the day such a comment was written.
MODULES=$(sed -n '/static let modules = \[/,/^    \]$/p' mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift \
          | grep -oE '^\s*"[a-z-]+",' | grep -oE '"[a-z-]+"' | tr -d '"')
[ -z "$MODULES" ] && { echo "could not read the module list from KhaytEngine.swift" >&2; exit 1; }
for m in $MODULES; do
  cp "lib/$m.js" "$DEST/$m.js"
  echo "  synced $m.js"
done

# A module taken OFF the list leaves its copy behind, and a copy nobody loads is
# dead weight the drift guards then fail on — which is the right outcome arriving
# at the wrong moment, after a commit rather than during a sync. Left behind once
# already, by a module bundled and then split in two.
#
# Locales are copied further down and are not in $MODULES, so they are spared by
# name rather than by luck.
# $MODULES is NEWLINE separated — it comes out of grep — so it is flattened
# first. Matching against it unflattened makes every pattern miss and every file
# an orphan, which is how the first version of this deleted 62 of the 64.
MODULE_LIST=" $(echo $MODULES | tr '\n' ' ') "
for f in "$DEST"/*.js; do
  b="$(basename "$f" .js)"
  case "$b" in locale-*) continue;; esac
  case "$MODULE_LIST" in
    *" $b "*) ;;
    *) rm -f "$f"; echo "  removed $b.js (no longer bundled)";;
  esac
done

# Khayt's own translations, from renderer/locales/. Not lib/, and not named the
# way modules are — nine files all assigning onto one global — so they are copied
# by their own list rather than bent into the rule above.
LOCALES=$(sed -n '/static let locales = \[/,/\]/p' mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift \
          | grep -oE '"[a-zA-Z-]+"' | tr -d '"')
for l in $LOCALES; do
  cp "renderer/locales/$l.js" "$DEST/locale-$l.js"
  echo "  synced locale $l"
done

# The invoice's stylesheet. The html is a bundled module; this is what it looks
# like, and two copies would be two documents that agree until one is edited.
cp renderer/invoice.css "mac/KhaytCore/Sources/KhaytApp/Resources/invoice.css"
echo "  synced invoice.css"

# The filament catalogue. A data file rather than a rule, so it sits beside the
# sample book in Resources rather than in JS/ — but it is synced here for the
# same reason everything else is: one copy, and a drifted one is a Mac app
# offering a shop filaments the other app does not have.
cp assets/filament-catalog.json "mac/KhaytCore/Sources/KhaytApp/Resources/filament-catalog.json"
echo "  synced filament-catalog.json"

echo "$(echo "$MODULES" | wc -w | tr -d ' ') modules and $(echo "$LOCALES" | wc -w | tr -d ' ') locales synced"
