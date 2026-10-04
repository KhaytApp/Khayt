#!/usr/bin/env python3
"""Rebuild `assets/filament-catalog.json` from every open filament list we can use.

A shop adding a spool types a brand, a material, a colour, a weight and a
diameter that somebody else already wrote down. This is that list, merged from:

  o  Open Filament Database — https://github.com/OpenFilamentCollective/open-filament-database
     MIT. The base: the most products, spool and empty-reel weights, temperatures.
  b  Bambu Lab's colour list — filaments_color_codes.json in Bambu Studio.
     The repository is AGPL-3.0, so only FACTS are taken from it — the product
     line, the colour's English name and its hex, which Bambu publishes on its
     own store — never the file, its codes or its translations. It is the brand's
     own word, so for Bambu it renames and recolours what the others say.
  s  SpoolmanDB — https://github.com/Donkie/SpoolmanDB
     MIT. Fills the brands and colours the OFD lacks (eSUN, R3D, ZIRO, …).
  k  scripts/filament-catalog-overrides.json — Khayt's own corrections, last.

Not used: OrcaSlicer / Bambu Studio filament PROFILES (AGPL-3.0, and they carry
temperatures and flow, not colours), and retailer pages (no licence to copy).
THIRD-PARTY-NOTICES.md lists every source and its licence.

── WHY A SNAPSHOT RATHER THAN A LIVE QUERY ─────────────────────────────────

Khayt is local-first. A shop in a workshop with no signal must still be able to
add a spool, and asking a third party "what is 123-3D PLA" tells that third
party what the shop buys. The data is static and openly licensed, so there is
nothing to gain by fetching it per keystroke and something to lose.

The cost of a snapshot is that it goes stale. `generatedAt` is carried into the
file so the app can say how old it is rather than implying the list is current,
and re-running this is the whole update.

── WHY IT IS TRIMMED ───────────────────────────────────────────────────────

The OFD's `json/all.json` alone is 14 MB — brands, materials, filaments,
variants, sizes, stores, purchase links, GTINs. A spool record needs nine of
those fields. Nesting the colours under their filament (rather than one flat row
per colour-and-size, which is how the OFD stores it) matches how somebody picks:
brand, then filament, then colour, then weight. Discontinued products and
colours are dropped: a shop cannot buy them.

── HOW THE SOURCES BECOME ONE LIST ─────────────────────────────────────────

One row per brand and product line, one colour per name within it. A brand is
spelled as the OFD spells it. A line is matched by its words, not their order or
punctuation ("PLA Silk" is "Silk PLA", "PLA+" is "PLA Plus"); a line named only
by its material ("PLA") is matched by the colours it shares (see `pick`). A
colour is matched by name, ignoring case and Grey/Gray, and keeps the spelling
of whichever source added it. Every row says which sources it came from (`s`).

── AND WHY IT IS CORRECTED ─────────────────────────────────────────────────

The upstreams are community-typed, and a manufacturer's own list beats them
where they disagree: Bambu Lab's PLA Matte had "Nardo Grey" for Nardo Gray, four
hexes that were not Bambu's, and a GTIN typed into an empty-spool weight. A
tester printing mostly in Bambu matte read that as "the Bambu profiles are
dated". `finish()` applies `scripts/filament-catalog-overrides.json` (and a
plausibility check on empty-spool weights) after every build, so the monthly
refresh cannot quietly undo a correction.

    python3 scripts/fetch-filament-catalog.py                    # rebuild from upstream
    python3 scripts/fetch-filament-catalog.py --overrides-only   # re-apply corrections
                                                                 # to the committed file
    KHAYT_CATALOG_CACHE=/tmp/fc python3 scripts/fetch-filament-catalog.py
                                                                 # keep the downloads

`--overrides-only` touches nothing but what the overrides say, so a correction
can ship without dragging a month of unrelated upstream change in with it. It is
idempotent: applying it to its own output changes nothing.
"""
import io
import json
import os
import re
import sys
import tarfile
import urllib.request

OUT = os.environ.get("KHAYT_CATALOG_OUT") or os.path.join(
    os.path.dirname(__file__), "..", "assets", "filament-catalog.json")
OVERRIDES = os.path.join(os.path.dirname(__file__), "filament-catalog-overrides.json")

# Heavier than any real empty spool (cardboard or plastic, 1–3 kg reels are
# 150–1000 g). Above it the figure is a typo — Bambu's PLA Matte Grass Green
# carried 6975337030119, a barcode — and a scale reading minus a barcode is a
# negative spool.
MAX_EMPTY_SPOOL_G = 2000

SOURCES = {
    # One letter per source, carried on every row as `s` so a wrong figure can
    # be traced to where it came from without re-running the build.
    "o": {
        "name": "Open Filament Database",
        "url": "https://github.com/OpenFilamentCollective/open-filament-database",
        "licence": "MIT",
        "copyright": "Copyright (c) 2025 OpenFilamentCollective",
    },
    "s": {
        "name": "SpoolmanDB",
        "url": "https://github.com/Donkie/SpoolmanDB",
        "licence": "MIT",
        "copyright": "Copyright (c) 2024 Donkie",
    },
    "b": {
        "name": "Bambu Lab colour list (facts only: product line, English colour name, hex)",
        "url": "https://github.com/bambulab/BambuStudio/blob/master/resources/profiles/BBL/filament/filaments_color_codes.json",
        "licence": "Facts only. The file sits in an AGPL-3.0 repository; it is not "
                   "redistributed, and nothing of it but those three facts is kept.",
    },
    "k": {
        "name": "Khayt corrections",
        "url": "https://github.com/KhaytApp/Khayt/blob/main/scripts/filament-catalog-overrides.json",
        "licence": "Khayt's own",
    },
}

# The MIT licence asks for its notice to travel with every copy, and this file
# is copied into two app bundles that ship no NOTICES file of their own — so the
# notice is IN the file, once, for both MIT sources.
MIT_NOTICE = (
    "Permission is hereby granted, free of charge, to any person obtaining a copy of this "
    "software and associated documentation files (the \"Software\"), to deal in the Software "
    "without restriction, including without limitation the rights to use, copy, modify, merge, "
    "publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons "
    "to whom the Software is furnished to do so, subject to the following conditions: The above "
    "copyright notice and this permission notice shall be included in all copies or substantial "
    "portions of the Software. THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, "
    "EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS "
    "FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT "
    "HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF "
    "CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE "
    "USE OR OTHER DEALINGS IN THE SOFTWARE."
)

OFD_URL = "https://api.openfilamentdatabase.org/json/all.json"
SPOOLMAN_URL = "https://codeload.github.com/Donkie/SpoolmanDB/tar.gz/refs/heads/main"
BAMBU_URL = ("https://raw.githubusercontent.com/bambulab/BambuStudio/master/"
             "resources/profiles/BBL/filament/filaments_color_codes.json")

# A directory to keep the raw downloads in, so a build can be re-run offline
# and two runs can be compared on the same inputs. Unset: always download.
CACHE = os.environ.get("KHAYT_CATALOG_CACHE")


def fetch_bytes(url, name):
    path = os.path.join(CACHE, name) if CACHE else None
    if path and os.path.exists(path):
        with open(path, "rb") as fh:
            return fh.read()
    print(f"fetching {url} …", file=sys.stderr)
    # A User-Agent is required, not polite: the default `Python-urllib/3.x`
    # gets a 403 from the CDN in front of the OFD, while curl's does not.
    req = urllib.request.Request(url, headers={
        "User-Agent": "Khayt/filament-catalog (+https://khaytapp.com)",
    })
    with urllib.request.urlopen(req, timeout=120) as r:
        blob = r.read()
    if path:
        os.makedirs(CACHE, exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(blob)
    return blob


# ── NORMALISING ────────────────────────────────────────────────────────────

_HEX = re.compile(r"^#?([0-9A-Fa-f]{6})(?:[0-9A-Fa-f]{2})?$")
_SPACES = re.compile(r"[   \s]+")
_FORMERLY = re.compile(r"\((?:formerly|was|ex)[^)]*\)", re.I)


def clean(text):
    """A display name: trademark signs, 'formerly' notes and odd spaces gone."""
    s = _FORMERLY.sub(" ", str(text or ""))
    s = re.sub(r"[™®©]", "", s)
    # "FLEX - - Medium" and "grillon3 |": separators left where a placeholder
    # was cut out of the middle or the end of a name.
    s = re.sub(r"(?:\s+[-–|])+\s+", " ", " " + s + " ")
    return _SPACES.sub(" ", s).strip(" -–|")


def hexof(value):
    """`#RRGGBB`, upper case, or '' — an alpha byte and a second stop dropped.

    A multi-colour filament has several stops and a spool record has room for
    one; the first is the colour at the start of the spool.
    """
    if isinstance(value, list):
        value = value[0] if value else ""
    m = _HEX.match(str(value or "").strip())
    return "#" + m.group(1).upper() if m else ""


def ckey(name):
    """Colour identity: case, spacing and Grey/Gray do not make a new colour.

    Only the KEY folds the spelling. The row keeps the name as its source wrote
    it — and Bambu's list, being the brand's own, wins for Bambu.
    """
    s = _SPACES.sub(" ", str(name or "")).strip().lower()
    return re.sub(r"\bgrey\b", "gray", s)


def rkey(name, line_tokens):
    """Colour identity within one product line: the line's own words do not
    count, so Bambu's "Iron Gray Metallic" and the community's "Iron Gray" are
    one colour of PLA Metal rather than two."""
    k = ckey(name)
    words = [w for w in k.split() if _SYNONYMS.get(w, w) not in line_tokens]
    return " ".join(words) or k


def bkey(brand):
    return re.sub(r"[^a-z0-9]", "", str(brand or "").lower())


_SYNONYMS = {"metallic": "metal", "matt": "matte"}

MATERIALS = {"pla", "petg", "pet", "pctg", "abs", "asa", "tpu", "tpe", "pc", "pa",
             "pa6", "pa12", "paht", "ppa", "pps", "nylon", "pva", "pvb", "hips",
             "pp", "cpe", "peek", "pei", "pekk", "pcl", "wood"}


def words(name, brand=""):
    """A product line's words, in order. The brand's own name is not one."""
    s = clean(name).lower()
    s = re.sub(r"\+(?=[a-z])", " ", s)          # "PC+ABS", "PLA+WOOD": a join
    s = s.replace("+", " plus ")                # "PLA+", "Silk+": a grade
    for word, same in _SYNONYMS.items():
        s = re.sub(rf"\b{word}\b", same, s)
    drop = set(re.split(r"[\s\-_/,.]+", clean(brand).lower())) | {"filament", ""}
    return [t for t in re.split(r"[\s\-_/,.()]+", s) if t not in drop]


def tokens(name, brand=""):
    """A product line as a set of words, so word order and punctuation do not
    make two names for one line: "PLA Silk" is "Silk PLA", "PLA+" is "PLA Plus",
    "PLA-CF" is "PLA CF"."""
    return frozenset(words(name, brand))


def family(material):
    """The base polymer: "PC" for "PC+ABS", "PA6" for "PA6-CF". By position, not
    by set order — a set's order changes from run to run, and so did the build
    until this read the words in order."""
    w = words(material)
    return next((t for t in w if t in MATERIALS), w[0] if w else "")


# ── SOURCES → ROWS ─────────────────────────────────────────────────────────

def colour(name, hex_, weights=(), empty=None, diameter=None):
    return [clean(name), hexof(hex_), sorted(set(weights)), empty, diameter]


def from_ofd(d):
    brands = {b["id"]: b.get("name", "") for b in d["brands"]}
    sizes_by_variant = {}
    for s in d["sizes"]:
        sizes_by_variant.setdefault(s["variant_id"], []).append(s)
    variants_by_filament = {}
    for v in d["variants"]:
        variants_by_filament.setdefault(v["filament_id"], []).append(v)

    out = []
    for f in d["filaments"]:
        # Discontinued products and colours are dropped: a shop cannot buy them.
        # (A third of the file in 2025; 5 products and 22 colours by Oct 2026.)
        if f.get("discontinued"):
            continue
        colours = []
        for v in variants_by_filament.get(f["id"], []):
            if v.get("discontinued"):
                continue
            sizes = [s for s in sizes_by_variant.get(v["id"], []) if not s.get("discontinued")]
            # The weight of the spool with no filament on it. This is the one
            # field here Khayt cannot get any other way and genuinely needs: a
            # shop measuring what is left puts the spool on a scale, and the
            # reading is filament plus spool until this is known.
            empty = next((s["empty_spool_weight"] for s in sizes if s.get("empty_spool_weight")), None)
            diameters = sorted({s["diameter"] for s in sizes if s.get("diameter")})
            colours.append(colour(v.get("name", ""), v.get("color_hex", ""),
                                  [s["filament_weight"] for s in sizes if s.get("filament_weight")],
                                  empty, diameters[0] if diameters else None))
        if not colours:
            continue
        row = {
            "b": brands.get(f["brand_id"], ""),
            "n": f.get("name", ""),
            "m": f.get("material", ""),
            "d": f.get("density"),
            "t": [f.get("min_print_temperature"), f.get("max_print_temperature")],
            "c": colours,
        }
        bed = [f.get("min_bed_temperature"), f.get("max_bed_temperature")]
        if any(bed):
            row["bt"] = bed
        out.append(row)
    return out


def from_spoolman(tar_bytes):
    """SpoolmanDB's source files: one per manufacturer, a product name with a
    `{color_name}` placeholder in it, and the colours as a list."""
    out = []
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:gz") as tar:
        members = sorted((m for m in tar.getmembers()
                          if re.search(r"/filaments/[^/]+\.json$", m.name)),
                         key=lambda m: m.name.lower())
        for m in members:
            d = json.load(tar.extractfile(m))
            brand = d.get("manufacturer", "")
            for f in d.get("filaments", []):
                material = clean(f.get("material", ""))
                line = clean(str(f.get("name", "")).replace("{color_name}", " "))
                if not line:
                    line = material
                elif not any(t in MATERIALS or family(material) in t
                             for t in tokens(line, brand)):
                    line = f"{line} {material}"
                weights = [w["weight"] for w in f.get("weights", []) if w.get("weight")]
                # One empty-spool figure per colour: the 1 kg reel's if sold in
                # several sizes, since that is the reel a shop most often has.
                ws = sorted(f.get("weights", []), key=lambda w: abs((w.get("weight") or 0) - 1000))
                empty = next((w["spool_weight"] for w in ws if w.get("spool_weight")), None)
                ds = sorted(f.get("diameters", []))
                diameter = 1.75 if 1.75 in ds else (ds[0] if ds else None)
                colours = [colour(c.get("name", ""), c.get("hex") or c.get("hexes"),
                                  weights, empty, diameter)
                           for c in f.get("colors", []) if c.get("name")]
                if not colours:
                    continue
                et, bt = f.get("extruder_temp"), f.get("bed_temp")
                row = {"b": brand, "n": line, "m": material, "d": f.get("density"),
                       "t": [et, et] if et else [None, None], "c": colours}
                if bt:
                    row["bt"] = [bt, bt]
                out.append(row)
    return out


def from_bambu(d):
    """Bambu Lab's own colour list: line, English name, hex — and nothing else.

    This file lives in Bambu Studio (AGPL-3.0). What is taken from it is three
    facts per colour that Bambu prints on its own store — the product line, the
    colour's English name and its colour — not the file, its structure, its
    codes or its translations.
    """
    lines = {}
    for e in d.get("data", []):
        name = (e.get("fila_color_name") or {}).get("en")
        line = clean(e.get("fila_type", ""))
        if not name or not line:
            continue
        lines.setdefault(line, []).append(colour(name, e.get("fila_color")))
    out = []
    for line, colours in lines.items():
        material = next((t.upper() for t in sorted(tokens(line)) if t in MATERIALS), line)
        out.append({"b": "Bambu Lab", "n": line, "m": material, "d": None,
                    "t": [None, None], "c": colours})
    return out


# ── MERGING ────────────────────────────────────────────────────────────────

def _uniform(values):
    vals = [json.dumps(v) for v in values if v not in (None, [])]
    return json.loads(vals[0]) if vals and len(set(vals)) == 1 else None


def pick(rows, line):
    """The existing row a source's product line is, or None for a new line.

    Same brand only. A line named only by its material ("PLA") says nothing
    about WHICH of the brand's PLAs it is, so its colours decide: the row
    sharing at least half of them. A line with a name ("Matte", "Silk+") must
    match a row carrying those words — sharing "Black" with PLA Basic does not
    make PETG-CF PLA Basic.
    """
    brand = line["b"]
    lt = tokens(line["n"], brand)
    extra = lt - MATERIALS
    fam = family(line["m"])
    def overlap(r):
        rt_ = tokens(r["n"], brand)
        names = {rkey(c[0], rt_) for c in line["c"]}
        return len(names & {rkey(c[0], rt_) for c in r["c"]}) / max(1, len(names))

    def rt(r):
        return tokens(r["n"], brand)

    exact = [r for r in rows if rt(r) == lt]
    if exact:
        return max(exact, key=overlap)
    same = [r for r in rows if family(r["m"]) == fam or fam in rt(r)]
    if extra:
        same = [r for r in same if extra <= rt(r)]
    good = [r for r in same if overlap(r) >= 0.5]
    if good:
        return max(good, key=lambda r: (overlap(r), -len(rt(r) - MATERIALS)))
    return None


def merge(rows, incoming, code, manufacturer=False):
    """Fold one source's rows into the catalogue.

    `manufacturer` says whose word wins where both have a colour: the brand's
    own list renames and recolours; a community list only fills what is
    missing. Returns (lines added, colours added, colours changed).
    """
    by_brand = {}
    for r in rows:
        by_brand.setdefault(bkey(r["b"]), []).append(r)
    canon = {bkey(r["b"]): r["b"] for r in rows}
    added_lines = added = changed = 0
    for line in incoming:
        k = bkey(line["b"])
        # The base source's spelling of a brand wins ("Sunlu" is "SUNLU"); a
        # brand it writes with a trailing "3D" is still that brand ("eSun").
        if k not in canon and k + "3d" in canon:
            k += "3d"
        line["b"] = canon.setdefault(k, line["b"])
        brand_rows = by_brand.setdefault(k, [])
        target = pick(brand_rows, line)
        if target is None:
            line["s"] = code
            line["c"] = dedupe_colours(line["c"], tokens(line["n"], line["b"]))
            brand_rows.append(line)
            rows.append(line)
            added_lines += 1
            added += len(line["c"])
            continue
        if code not in target.get("s", ""):
            target["s"] = "".join(sorted(target.get("s", "") + code))
        if target.get("d") is None and line.get("d"):
            target["d"] = line["d"]
        if not any(target.get("t") or []) and any(line.get("t") or []):
            target["t"] = line["t"]
        if "bt" not in target and line.get("bt"):
            target["bt"] = line["bt"]
        toks = tokens(target["n"], target["b"])
        have = {rkey(c[0], toks): c for c in target["c"]}
        # A colour new to the row takes the row's spool facts when every colour
        # already there agrees on them — Bambu's list says nothing about reels.
        fill = [_uniform([c[i] for c in target["c"]]) for i in (2, 3, 4)]
        for c in line["c"]:
            h = have.get(rkey(c[0], toks))
            if h is None:
                c = list(c)
                for i, v in zip((2, 3, 4), fill):
                    if c[i] in (None, []) and v is not None:
                        c[i] = v
                target["c"].append(c)
                have[rkey(c[0], toks)] = c
                added += 1
                continue
            before = list(h)
            if manufacturer:
                h[0] = c[0] or h[0]
                h[1] = c[1] or h[1]
            elif not h[1]:
                h[1] = c[1]
            if not h[2] and c[2]:
                h[2] = list(c[2])
            if h[3] is None and c[3]:
                h[3] = c[3]
            if h[4] is None and c[4]:
                h[4] = c[4]
            if h != before:
                changed += 1
    return added_lines, added, changed


def dedupe_colours(colours, line_tokens=frozenset()):
    """One row per colour: a source listing a colour twice (a refill and a
    reel, say) becomes one, with both weights."""
    out, seen = [], {}
    for c in colours:
        k = rkey(c[0], line_tokens)
        if k in seen:
            h = seen[k]
            h[1] = h[1] or c[1]
            h[2] = sorted(set(h[2]) | set(c[2]))
            h[3] = h[3] if h[3] is not None else c[3]
            h[4] = h[4] if h[4] is not None else c[4]
            continue
        c = list(c)
        seen[k] = c
        out.append(c)
    return out


def dedupe_rows(rows):
    """One row per brand and product: the OFD lists a few twice."""
    out, seen = [], {}
    for r in rows:
        k = (bkey(r["b"]), clean(r["n"]).lower())
        if k in seen:
            seen[k]["c"] = dedupe_colours(seen[k]["c"] + r["c"], tokens(r["n"], r["b"]))
            continue
        r["c"] = dedupe_colours(r["c"], tokens(r["n"], r["b"]))
        seen[k] = r
        out.append(r)
    return out


def build(ofd, spoolman, bambu):
    rows = dedupe_rows(from_ofd(ofd))
    for r in rows:
        r["s"] = "o"
    # Bambu's own list before the community's, so that the community fills
    # gaps around the manufacturer's figures rather than the other way round.
    for code, incoming, manufacturer in (("b", from_bambu(bambu), True),
                                         ("s", from_spoolman(spoolman), False)):
        lines, colours, changed = merge(rows, incoming, code, manufacturer)
        print(f"  {SOURCES[code]['name'].split(' (')[0]}: {lines} new lines, "
              f"{colours} new colours, {changed} colours updated", file=sys.stderr)
    rows.sort(key=lambda r: (r["b"].lower(), r["n"].lower()))
    return rows


def _key(name):
    return " ".join(str(name or "").split()).lower()


def apply_overrides(rows, overrides):
    """Put the manufacturer's own names and hexes over the upstream's.

    Rows are changed in place. Returns a list of what changed, for the log.
    """
    log = []
    for o in overrides.get("filaments", []):
        brand, name = o["brand"], o["filament"]
        target = next((r for r in rows if r["b"] == brand and r["n"] == name), None)
        if target is None:
            log.append(f"override target missing upstream: {brand} {name}")
            continue
        wanted = o.get("colours", [])
        names = set()
        for w in wanted:
            names.add(_key(w["name"]))
            names.update(_key(a) for a in w.get("aka", []))

        # A colour misfiled under a sibling line is removed from it. The row is
        # not moved across: its name and hex are the wrong line's, and the
        # entry below already says what the right one is.
        for sib in o.get("notIn", []):
            for r in rows:
                if r["b"] != brand or r["n"] != sib:
                    continue
                kept = [c for c in r["c"] if _key(c[0]) not in names]
                for c in r["c"]:
                    if _key(c[0]) in names:
                        log.append(f"{brand} {sib}: removed misfiled {c[0]!r}")
                r["c"] = kept

        if "k" not in target.get("s", "k"):
            target["s"] = "".join(sorted(target["s"] + "k"))
        added = o.get("added", {})
        for w in wanted:
            keys = {_key(w["name"])} | {_key(a) for a in w.get("aka", [])}
            row = next((c for c in target["c"] if _key(c[0]) in keys), None)
            if row is None:
                target["c"].append([w["name"], w["hex"], list(added.get("weights", [])),
                                    None, added.get("diameter")])
                log.append(f"{brand} {name}: added {w['name']!r}")
                continue
            if row[0] != w["name"]:
                log.append(f"{brand} {name}: renamed {row[0]!r} -> {w['name']!r}")
                row[0] = w["name"]
            if row[1].upper() != w["hex"].upper():
                log.append(f"{brand} {name} {w['name']}: hex {row[1]} -> {w['hex']}")
                row[1] = w["hex"]
    return log


def finish(rows):
    """Everything applied after the upstream rows are built, in both modes."""
    log = []
    for r in rows:
        for c in r["c"]:
            if c[3] is not None and c[3] > MAX_EMPTY_SPOOL_G:
                log.append(f"{r['b']} {r['n']} {c[0]}: dropped empty spool weight {c[3]}")
                c[3] = None
    with open(OVERRIDES) as fh:
        log += apply_overrides(rows, json.load(fh))
    for line in log:
        print(f"  {line}", file=sys.stderr)
    return rows


def write(catalog):
    blob = json.dumps(catalog, separators=(",", ":"), ensure_ascii=False)
    with open(OUT, "w") as fh:
        fh.write(blob + "\n")
    return blob


def overrides_only():
    with open(OUT) as fh:
        catalog = json.load(fh)
    finish(catalog["filaments"])
    write(catalog)
    print("overrides applied -> assets/filament-catalog.json", file=sys.stderr)


def main():
    if "--overrides-only" in sys.argv:
        overrides_only()
        return
    ofd = json.loads(fetch_bytes(OFD_URL, "ofd-all.json"))
    spoolman = fetch_bytes(SPOOLMAN_URL, "spoolmandb.tar.gz")
    bambu = json.loads(fetch_bytes(BAMBU_URL, "bambu-filaments_color_codes.json"))
    rows = finish(build(ofd, spoolman, bambu))
    catalog = {
        # `source` and `licence` predate `sources` and name the base list; the
        # app reads neither, but older tooling did.
        "source": SOURCES["o"]["url"],
        "licence": "MIT (Open Filament Database, SpoolmanDB); see sources",
        "generatedAt": ofd.get("generated_at", ""),
        "version": ofd.get("version", ""),
        "sources": SOURCES,
        "mitNotice": MIT_NOTICE,
        # Positional rows keep the file small; this says what the positions are,
        # so the shape is readable without reading the parser.
        "fields": {
            "filament": ["b brand", "n name", "m material", "d density",
                         "t [minTemp, maxTemp]", "bt [minBedTemp, maxBedTemp] (when known)",
                         "s sources (letters of `sources`)", "c colours"],
            "colour": ["name", "hex", "[weights]", "emptySpoolWeight", "diameter"],
        },
        "filaments": rows,
    }
    blob = write(catalog)
    colours = sum(len(r["c"]) for r in rows)
    print(f"{len(rows)} filaments, {len({r['b'] for r in rows})} brands, {colours} colours, "
          f"{round(len(blob.encode()) / 1e6, 2)} MB -> assets/filament-catalog.json",
          file=sys.stderr)


if __name__ == "__main__":
    main()
