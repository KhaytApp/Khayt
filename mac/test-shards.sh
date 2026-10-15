#!/usr/bin/env bash
# Run KhaytCore's tests as three processes at once, from one build.
#
#   bash mac/test-shards.sh            # after: swift build --package-path mac/KhaytCore --build-tests
#   bash mac/test-shards.sh --skip X   # any further arguments go to every shard
#
# ── WHY THREE PROCESSES ─────────────────────────────────────────────────────
#
# Nearly every app test is `@MainActor`, and a process has ONE main thread. In
# one `swift test` the whole suite queued on it: on CI (Oct 2026) every
# main-actor test finished ~1,560 s in, whatever its own cost, while the
# runner's other cores sat mostly idle — and only THEN did the serialised
# `LibraryEditPerfTests` (10,000-model books, a 9,800-model drive scan) get the
# main thread to itself, for another ~300 s that nothing ran beside. Three
# processes are three main threads:
#
#   perf  LibraryEditPerfTests alone. Its budgets time how long the MAIN THREAD
#         stalls, so a main thread that is not also a queue of 3,000 other
#         tests is a better measurement, not only a faster one. It is also the
#         one suite that points the whole process at a temp support folder
#         (`StoreReader.Build.supportFolderForTests`) — alone in its process,
#         no other test can read the book through that seam meanwhile.
#   a     KhaytAppTests suites A–N.
#   b     everything else: KhaytAppTests O–Z, KhaytCoreTests, KhaytMcpTests,
#         KhaytPreviewTests.
#
# NOTHING CAN FALL BETWEEN THEM: `a` is `--filter SPLIT`, `b` is `--skip SPLIT`
# — the same expression, so every test is in exactly one — and both skip PERF,
# which is the only thing `perf` runs. A new suite lands in `a` or `b` by its
# name; nothing here has to be told about it. The split point only balances
# the two halves (serial time on an M-series Mac, Oct 2026: ~270 s of app
# suites in `a`; ~265 s in `b`, plus KhaytCoreTests' ~95 s).
#
# `--ignore-lock`: three `swift test`s on one `.build` would otherwise wait for
# each other's lock on it, and run one after another. `--skip-build` means
# none of them writes there.
set -uo pipefail
cd "$(dirname "$0")/.."

PKG="mac/KhaytCore"
PERF='LibraryEditPerfTests'
SPLIT='^KhaytAppTests\.[A-N]'
OUT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/khayt-test-shards"
rm -rf "$OUT" && mkdir -p "$OUT"

shard() {
  local name=$1; shift
  local start=$SECONDS
  swift test --package-path "$PKG" --skip-build --ignore-lock "$@" >"$OUT/$name.log" 2>&1
  echo $? >"$OUT/$name.status"
  echo "$((SECONDS - start))" >"$OUT/$name.seconds"
}

shard perf --filter "$PERF" "$@" &
shard a --filter "$SPLIT" --skip "$PERF" "$@" &
shard b --skip "$SPLIT" --skip "$PERF" "$@" &
wait

failed=0
for name in perf a b; do
  status=$(cat "$OUT/$name.status" 2>/dev/null || echo 1)
  [ "$status" = 0 ] || failed=1
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::shard $name — exit $status, $(cat "$OUT/$name.seconds")s"; fi
  cat "$OUT/$name.log"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi
done

# The summary, outside the folded logs: each shard's count and time, and every
# failure, so a red run says what failed without opening a group.
echo
for name in perf a b; do
  echo "shard $name: exit $(cat "$OUT/$name.status"), $(cat "$OUT/$name.seconds") s"
  grep -E "Test run with [0-9]+ tests" "$OUT/$name.log" | sed 's/^/  /'
done
if [ "$failed" != 0 ]; then
  echo
  echo "FAILED:"
  grep -hE "✘|error:|fatal|Fatal|crashed|signal" "$OUT"/*.log | grep -v "^$" | head -200
  exit 1
fi
