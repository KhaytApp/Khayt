#!/usr/bin/env bash
# Prove the iOS companion can still read the desktop.
#
# Two halves that can drift apart silently:
#   lib/lan-server.js  — what the desktop sends
#   ios/…/KhaytModels.swift — what the phone requires
#
# The phone decodes with Swift `Codable`, which THROWS on a missing required
# field. So renaming one key is not a degraded screen on the phone, it is an
# empty one — and nothing else in the repo notices: `npm test` passes,
# `xcodebuild` passes, and neither one ever puts the two sides in a room.
#
# This boots the real server, captures the real bytes, and decodes them with the
# real structs. Verified by mutation: renaming `completed_today` to
# `completedToday` in lan-server.js makes it fail with keyNotFound, as it should.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "ios-contract: swiftc not found — this check needs macOS with Xcode." >&2
  echo "ios-contract: SKIPPED (loudly: a silent skip is how a guard stops guarding)." >&2
  # In CI the job runs on a Mac image on purpose: no swiftc there is a broken
  # runner, and a skip would pass the required check.
  if [ -n "${CI:-}" ]; then exit 1; fi
  exit 0
fi

CAPTURES="$(mktemp -d)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$CAPTURES" "$BUILD"' EXIT

echo "→ capturing live responses from lib/lan-server.js"
node scripts/ios-contract-capture.mjs "$CAPTURES" >/dev/null

echo "→ decoding them with ios/KhaytCompanion/Models/KhaytModels.swift"
swiftc -Onone \
  ios/KhaytCompanion/Models/KhaytModels.swift \
  scripts/ios-contract-decode.swift \
  -o "$BUILD/decoder"

"$BUILD/decoder" "$CAPTURES"
