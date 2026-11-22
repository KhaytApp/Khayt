#!/usr/bin/env bash
# Confirms that the native app can read the secrets the Electron app wrote.
#
# SafeStorage.swift is held to Electron's byte format by tests, but one link in
# the chain cannot be tested: that the Keychain item really holds the PBKDF2
# password. Checking it means reading a live secret, so it is not in the suite —
# it is this, run by you, on your own machine, printing no secret.
#
#   ./mac/verify-safestorage.sh            # dev store   (~/…/khayt)
#   ./mac/verify-safestorage.sh Khayt      # packaged app store
set -euo pipefail

APP="${1:-khayt}"
STORE="$HOME/Library/Application Support/$APP/khayt-store.json"
[ -f "$STORE" ] || { echo "no store at $STORE"; exit 1; }

echo "store   : $STORE"
echo "keychain: \"$APP Safe Storage\" / \"$APP Key\""
echo
echo "macOS may ask you to allow access. That prompt is the point: a native"
echo "binary has a different code signature from Electron's, so the Keychain"
echo "treats it as a different application and asks once per binary."
echo

# Getting the password and checking the store are two steps on purpose.
#
# They used to be one pipeline, and that had the script telling you the exact
# opposite of the truth. `security` writes nothing when the grant is declined or
# the item is missing, so node derived a key from an empty password, every field
# failed to decrypt, and the report read "0 of 3 encrypted fields round-trip"
# with "do NOT write this store" beside each one. A permission problem, printed
# as your secrets being corrupt, by the one script that exists to tell you they
# are not. If the Keychain does not answer, this now says so and checks nothing.
# Long enough to find the prompt and answer it, short enough that an
# unanswered one is reported rather than sat through.
WAIT="${KEYCHAIN_WAIT:-60}"

# A FIFO rather than a temp file: the password crosses a kernel buffer and is
# never written to disk. `read -t` is what puts a limit on the wait — `security`
# blocks on that permission prompt indefinitely, so an unanswered prompt (it can
# open behind another window) or a shell with no window server session — ssh, CI,
# a git hook — would otherwise hang here until someone thought to press ^C.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkfifo -m 600 "$work/pw"

security find-generic-password -w -s "$APP Safe Storage" -a "$APP Key" \
  >"$work/pw" 2>"$work/err" &
sec=$!

pw=""
if IFS= read -r -t "$WAIT" pw <"$work/pw"; then
  wait "$sec" 2>/dev/null || true
elif kill -0 "$sec" 2>/dev/null; then
  kill "$sec" 2>/dev/null || true
  wait "$sec" 2>/dev/null || true
  echo "Gave up after ${WAIT}s waiting for the Keychain." >&2
  echo >&2
  echo "If no prompt appeared it is probably behind another window, or this" >&2
  echo "shell has no window server session. Answer it and run this again, or" >&2
  echo "allow longer:  KEYCHAIN_WAIT=120 $0${1:+ $1}" >&2
  echo >&2
  echo "Nothing was read, and nothing is claimed about the store." >&2
  exit 1
fi

if [ -z "$pw" ]; then
  echo "The Keychain returned no password for \"$APP Safe Storage\" / \"$APP Key\"." >&2
  [ -s "$work/err" ] && sed 's/^/  /' "$work/err" >&2
  echo >&2
  echo "That is about this Keychain item or its grant — not about your store," >&2
  echo "whose encrypted fields have not been touched. Two usual causes: access" >&2
  echo "was declined, or \"$APP\" is the wrong name (a development run writes" >&2
  echo "\"khayt\", the packaged app writes \"Khayt\" — try:  $0 Khayt)." >&2
  exit 1
fi

printf '%s' "$pw" \
| node -e '
  const c = require("crypto"), fs = require("fs");
  let pw = ""; process.stdin.on("data", d => pw += d).on("end", () => {
    // Never report on a store using a key we did not really get. An empty
    // password decrypts nothing, and "nothing decrypts" reads as corruption.
    if (!pw.trim()) {
      console.error("no keychain password on stdin — checked nothing");
      process.exit(1);
    }
    const key = c.pbkdf2Sync(pw.trim(), "saltysalt", 1003, 16, "sha1");
    const store = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    let n = 0, ok = 0;
    (function walk(o, path) {
      if (o && typeof o === "object") for (const [k, v] of Object.entries(o)) walk(v, path + "." + k);
      else if (typeof o === "string" && o.startsWith("__enc__")) {
        n++;
        const raw = Buffer.from(o.slice(7), "base64");
        try {
          const d = c.createDecipheriv("aes-128-cbc", key, Buffer.alloc(16, 0x20));
          const out = Buffer.concat([d.update(raw.subarray(3)), d.final()]);
          // Re-encrypting must reproduce the file byte for byte, or writing
          // would corrupt what Electron stored.
          const e = c.createCipheriv("aes-128-cbc", key, Buffer.alloc(16, 0x20));
          const back = Buffer.concat([Buffer.from("v10"), e.update(out), e.final()]);
          const same = back.equals(raw);
          if (same) ok++;
          console.log("  %s %s (%d bytes, not shown)%s", same ? "OK  " : "BAD ",
            path.slice(1), out.length, same ? "" : "  ← re-encrypt differs; do NOT write this store");
        } catch (err) { console.log("  BAD  %s — %s", path.slice(1), err.message); }
      }
    })(store, "");
    console.log("\n%d of %d encrypted fields round-trip.", ok, n);
    process.exit(ok === n && n > 0 ? 0 : 1);
  });
' "$STORE"
