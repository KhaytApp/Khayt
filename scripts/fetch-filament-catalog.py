#!/usr/bin/env python3
"""Rebuild `assets/filament-catalog.json` from the Open Filament Database.

A shop adding a spool types a brand, a material, a colour, a weight and a
diameter that somebody else already wrote down. This is that list: 1,945
filaments across 166 brands, community-maintained, MIT-licensed, rebuilt daily
as static JSON.

    https://api.openfilamentdatabase.org/
    https://github.com/OpenFilamentCollective/open-filament-database

── WHY A SNAPSHOT RATHER THAN A LIVE QUERY ─────────────────────────────────

Khayt is local-first. A shop in a workshop with no signal must still be able to
add a spool, and asking a third party "what is 123-3D PLA" tells that third
party what the shop buys. The data is static and openly licensed, so there is
nothing to gain by fetching it per keystroke and something to lose.

The cost of a snapshot is that it goes stale. `generatedAt` is carried into the
file so the app can say how old it is rather than implying the list is current,
and re-running this is the whole update.

── AND WHY IT IS TRIMMED ───────────────────────────────────────────────────

`json/all.json` is 14 MB — brands, materials, filaments, variants, sizes,
stores, purchase links, GTINs. A spool record needs nine of those fields.
Nesting the colours under their filament (rather than one flat row per
colour-and-size, which is how the source stores it) takes 22,256 rows down to
1,945 and 1.65 MB down to 0.68 MB, and it matches how somebody picks: brand,
then filament, then colour, then weight.

Discontinued filaments and colours are dropped. A shop cannot buy them, and
they are a third of the file.

    python3 scripts/fetch-filament-catalog.py
"""
import json
import os
import sys
import urllib.request

SOURCE = "https://api.openfilamentdatabase.org/json/all.json"
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "filament-catalog.json")


def fetch(url):
    # A User-Agent is required, not polite: the default `Python-urllib/3.x`
    # gets a 403 from the CDN in front of this, while curl's does not.
    req = urllib.request.Request(url, headers={
        "User-Agent": "Khayt/filament-catalog (+https://khaytapp.com)",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def build(d):
    brands = {b["id"]: b.get("name", "") for b in d["brands"]}
    sizes_by_variant = {}
    for s in d["sizes"]:
        sizes_by_variant.setdefault(s["variant_id"], []).append(s)
    variants_by_filament = {}
    for v in d["variants"]:
        variants_by_filament.setdefault(v["filament_id"], []).append(v)

    out = []
    for f in d["filaments"]:
        if f.get("discontinued"):
            continue
        colours = []
        for v in variants_by_filament.get(f["id"], []):
            if v.get("discontinued"):
                continue
            sizes = [s for s in sizes_by_variant.get(v["id"], []) if not s.get("discontinued")]
            weights = sorted({s["filament_weight"] for s in sizes if s.get("filament_weight")})
            # The weight of the spool with no filament on it. This is the one
            # field here Khayt cannot get any other way and genuinely needs: a
            # shop measuring what is left puts the spool on a scale, and the
            # reading is filament plus spool until this is known.
            empty = next((s["empty_spool_weight"] for s in sizes if s.get("empty_spool_weight")), None)
            diameters = sorted({s["diameter"] for s in sizes if s.get("diameter")})
            colours.append([v.get("name", ""), v.get("color_hex", ""), weights, empty,
                            diameters[0] if diameters else None])
        if not colours:
            continue
        out.append({
            "b": brands.get(f["brand_id"], ""),
            "n": f.get("name", ""),
            "m": f.get("material", ""),
            "d": f.get("density"),
            "t": [f.get("min_print_temperature"), f.get("max_print_temperature")],
            "c": colours,
        })
    out.sort(key=lambda r: (r["b"].lower(), r["n"].lower()))
    return out


def main():
    print(f"fetching {SOURCE} …", file=sys.stderr)
    d = fetch(SOURCE)
    rows = build(d)
    catalog = {
        "source": "https://github.com/OpenFilamentCollective/open-filament-database",
        "licence": "MIT",
        "generatedAt": d.get("generated_at", ""),
        "version": d.get("version", ""),
        # Positional rows keep the file small; this says what the positions are,
        # so the shape is readable without reading the parser.
        "fields": {
            "filament": ["b brand", "n name", "m material", "d density",
                         "t [minTemp, maxTemp]", "c colours"],
            "colour": ["name", "hex", "[weights]", "emptySpoolWeight", "diameter"],
        },
        "filaments": rows,
    }
    blob = json.dumps(catalog, separators=(",", ":"), ensure_ascii=False)
    with open(OUT, "w") as fh:
        fh.write(blob + "\n")
    colours = sum(len(r["c"]) for r in rows)
    print(f"{len(rows)} filaments, {colours} colours, "
          f"{round(len(blob.encode()) / 1e6, 2)} MB -> assets/filament-catalog.json",
          file=sys.stderr)


if __name__ == "__main__":
    main()
