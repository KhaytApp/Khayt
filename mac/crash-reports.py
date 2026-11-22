#!/usr/bin/env python3
"""Print the crashed thread of every test-process crash report newer than a stamp.

    python3 mac/crash-reports.py <stamp-file>

A test process that dies of a Swift trap (`signal code 5`) or a segfault
(`signal code 11`) takes its own explanation with it: the trap's message, when
there is one, often never reaches the log, and the shard runner's output stops
mid-line. macOS's ReportCrash still writes an `.ips` report for it under
~/Library/Logs/DiagnosticReports, with the faulting thread symbolicated to
file and line, because the test bundle is a debug build. This prints that
part, so a red CI run names the line that trapped instead of the test that
happened to print last.

Reports older than the stamp are left out: a Mac that ran the tests before
keeps its old reports, and they are not this run's.
"""
import glob
import json
import os
import sys

FRAMES = 25


def summarise(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    _, _, body = text.partition("\n")
    report = json.loads(body)
    exc = report.get("exception", {})
    print(f"== {os.path.basename(path)}")
    print(f"   {exc.get('type', '?')} ({exc.get('signal', '?')}) {exc.get('subtype', '')}".rstrip())
    asi = report.get("asi")
    if asi:
        for owner, lines in asi.items():
            for line in lines:
                print(f"   {owner}: {line}")
    images = report.get("usedImages", [])
    threads = report.get("threads", [])
    index = report.get("faultingThread", 0)
    if index >= len(threads):
        print("   (no faulting thread in the report)")
        return
    thread = threads[index]
    label = thread.get("name") or thread.get("queue") or f"thread {index}"
    print(f"   crashed on {label}")
    for frame in thread.get("frames", [])[:FRAMES]:
        image = images[frame["imageIndex"]].get("name", "?") if frame.get("imageIndex", -1) < len(images) else "?"
        where = ""
        if frame.get("sourceFile"):
            where = f"  {frame['sourceFile']}:{frame.get('sourceLine', '?')}"
        print(f"     {image}  {frame.get('symbol', '?')}{where}")


def main():
    stamp = os.path.getmtime(sys.argv[1]) if len(sys.argv) > 1 and os.path.exists(sys.argv[1]) else 0
    folder = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    found = sorted(
        p for pattern in ("swiftpm-testing-helper*.ips", "KhaytCorePackageTests*.ips", "xctest*.ips")
        for p in glob.glob(os.path.join(folder, pattern))
        if os.path.getmtime(p) >= stamp
    )
    if not found:
        print("(no crash report from this run under ~/Library/Logs/DiagnosticReports)")
        return
    for path in found:
        try:
            summarise(path)
        except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
            print(f"== {os.path.basename(path)}: unreadable ({error})")


if __name__ == "__main__":
    main()
