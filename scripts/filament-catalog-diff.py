#!/usr/bin/env python3
"""Say what changed between the committed filament catalogue and the new one.

Used by `.github/workflows/filament-catalog.yml` to write the body of the
monthly refresh PR. A 0.78 MB single-line JSON diff is unreadable — GitHub will
show it as one changed line — so the reviewer needs the summary or they are
approving a file they cannot see.

Reads the previous version from git rather than taking two paths, because that
is the comparison that matters: what a reviewer is being asked to accept.

    python3 scripts/filament-catalog-diff.py            # markdown summary
    python3 scripts/filament-catalog-diff.py --pr-body  # …plus where it came from
    python3 scripts/filament-catalog-diff.py --check    # exit 1 if unusable
"""
import json
import subprocess
import sys

PATH = "assets/filament-catalog.json"

# Kept here rather than in the workflow: a multi-line string inside a YAML block
# scalar has to be indented to match, and getting that wrong makes the whole
# file unparseable — which it did, twice, before this moved.
PROVENANCE = (
    "Opened by `.github/workflows/filament-catalog.yml`, which rebuilds the "
    "snapshot with `scripts/fetch-filament-catalog.py` from the "
    "[Open Filament Database](https://github.com/OpenFilamentCollective/open-filament-database)"
    " (MIT).\n\n"
    "The build is deterministic, so this diff is real change rather than churn. "
    "Nothing here touches a rule — only the data the lookup searches."
)
SHOWN = 25

# Below this the download was truncated or the upstream shape changed. The
# rule's own tests run against a fixture and would pass on an empty catalogue,
# so this is the only thing checking the DATA is usable.
MIN_FILAMENTS = 1500


def committed():
    """The catalogue as `HEAD` has it, or None on the first ever run."""
    out = subprocess.run(["git", "show", f"HEAD:{PATH}"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def names(catalog):
    return {f"{f.get('b', '')} {f.get('n', '')}".strip()
            for f in (catalog or {}).get("filaments", [])}


def colours(catalog):
    return sum(len(f.get("c", [])) for f in (catalog or {}).get("filaments", []))


def check(catalog):
    """Refuse a catalogue that would make the lookup worse than no lookup."""
    n = len(catalog.get("filaments", []))
    if n < MIN_FILAMENTS:
        return f"only {n} filaments — the download looks truncated"
    if not catalog.get("generatedAt"):
        return "no generatedAt, so the app cannot say how old the list is"
    if not colours(catalog):
        return "no colours at all — the upstream shape has changed"
    return None


def summary(before, after):
    was, now = names(before), names(after)
    added, gone = sorted(now - was), sorted(was - now)

    # The COUNT comes from the list, not from the name set. Two products share a
    # brand-and-name with another ("3DE Premium", FormFutura's glow-in-the-dark
    # EasyFil PLA), so the set is smaller than the catalogue and reporting its
    # size understated the file by two.
    #
    # Added and removed are still by name, because that is what a reviewer can
    # read. A product whose name already exists twice will not show up as added,
    # which is a summary being approximate rather than a count being wrong.
    lines = [
        f"{len(after.get('filaments', []))} filaments "
        f"({len(added)} added, {len(gone)} removed by name), "
        f"{colours(after)} colours, generated {after.get('generatedAt', '?')}."
    ]
    for title, rows in (("Added", added),
                        ("No longer listed (discontinued upstream, or renamed)", gone)):
        if not rows:
            continue
        lines += ["", f"**{title}**", ""]
        lines += [f"- {r}" for r in rows[:SHOWN]]
        if len(rows) > SHOWN:
            lines.append(f"- …and {len(rows) - SHOWN} more")
    return "\n".join(lines)


def main():
    after = json.load(open(PATH))

    problem = check(after)
    if problem:
        print(f"filament catalogue rejected: {problem}", file=sys.stderr)
        return 1
    if "--check" in sys.argv:
        print(f"{len(after['filaments'])} filaments, {colours(after)} colours, "
              f"generated {after['generatedAt']}")
        return 0

    print(summary(committed(), after))
    if "--pr-body" in sys.argv:
        print()
        print(PROVENANCE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
