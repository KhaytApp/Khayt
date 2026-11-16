# What Khayt learned from OrcaSlicer's source: facts, in our own words

For engine A ("Khayt built-in", `~/Khayt-proposals/orca-cli-library-engine.md`, approved Nov 16 2026).

## The rules for this file

OrcaSlicer is **AGPL-3.0**. Facts about file formats and arithmetic are nobody's property; the
expression of Orca's code is Orca's. So:

1. **Facts only, in our own words.** What a 3MF field is called and means, how a value is laid out,
   which inputs a calculation takes and what it produces. **No code, no quoted comments, no
   line-by-line paraphrase** of a function.
2. **Every fact cites its source**: the Orca file and the commit it was read at, with line numbers,
   so a reviewer can check the note against it and see that nothing was copied.
3. **Khayt code is written from these notes**, never from Orca's files. A PR cites the section here.
   Its reviewer compares the diff with the cited Orca file: no shared identifiers beyond the
   format's own key names, no shared comments, no same-shaped functions.
4. Where a value can be checked, the shared vectors take their expected figures from RUNNING a
   slicer (engine B), never from reading its code.

Source commit for everything below: `OrcaSlicer/OrcaSlicer@59acdedd065e5213445163a581947353d3208ccd`
(main, Nov 16 2026), read through raw.githubusercontent.com. Files: `src/libslic3r/Format/bbs_3mf.cpp`,
`src/libslic3r/GCode/ToolOrdering.cpp`, `src/libslic3r/PrintConfig.cpp`.

## 1. Where a 3MF project keeps what (`bbs_3mf.cpp` lines 219–254)

A Bambu/Orca project 3MF has a `Metadata/` folder beside the model. The members Khayt cares about:

| Member | What it holds |
|---|---|
| `Metadata/project_settings.config` | the project's settings as JSON: printer, process, and per-slot filament lists |
| `Metadata/model_settings.config` | per object and per part: names, slot (extruder) assignments, and the plates |
| `Metadata/slice_info.config` | written when the project was sliced: per plate, what the slice used |
| `Metadata/plate_N.png` | the plate's picture (`plate_1.png` is the project thumbnail) |
| `Metadata/filament_sequence.json` | the order filaments are used in, when it was set |
| `Metadata/layer_heights_profile.txt`, `layer_config_ranges.xml`, `custom_gcode_per_layer.xml` | variable layer heights, per-height setting ranges, colour changes at a height |
| `Metadata/print_profile.config` | an older name for a project's print settings |

Orca also writes its own CAD recipe as `Metadata/orca_cad.bin`; Snapmaker Orca's older name for the
same is `Metadata/SnapOrca_cad.bin` (lines 240–243). Neither is needed for figures.

## 2. Objects, parts, slots and plates in `model_settings.config` (lines 264–443)

- The file is XML. An `object` element (attribute `id`) holds `metadata` elements, each a `key` /
  `value` pair, and `part` elements (with their own `id` and a `subtype`, so a part can be a model
  part, a modifier, a support blocker or enforcer) that hold metadata of their own.
- The slot a thing prints with is the metadata key **`extruder`**, a 1-based slot number, on the
  object and optionally on each part (a part's own value wins over its object's).
- A **plate** is a `plate` element. Its metadata includes **`plater_id`** (the plate number), and it
  lists its objects as **`model_instance`** children, each naming an `object_id` and an `instance_id`.
  So "which objects print on plate N" is read from here, not guessed from positions.
- Source-file bookkeeping lives in the keys `source_file` and `source_object_id`.

**How Orca cleans the slot numbers when it loads a project** (lines 2396–2422):
- the number of slots is the length of the project's `filament_settings_id` list;
- an object with no slot, slot 0, or a slot past that count prints with **slot 1**;
- an object with a single part keeps no slot on the part: the object's slot is the one used;
- in an object with several parts, a part with slot 0 has its own slot removed (it follows its
  object), and a part whose slot is past the count prints with **slot 1**.

Khayt consequence: "which slots does this plate use" = the slots of its objects' printing parts
after applying those rules, plus the slots any painted facets name (section 4).

## 3. Purge between filaments (`PrintConfig.cpp` 8266–8502; `ToolOrdering.cpp` 1483–1537, 2920–2950)

The settings involved (in `project_settings.config`):

| Key | Meaning | Unit / default (Orca) |
|---|---|---|
| `flush_volumes_matrix` | for every pair of slots, the volume purged when going FROM one TO the other, flattened row by row (row = the filament being left, column = the one coming in) | mm³; diagonal 0, other cells 280 by default |
| `flush_volumes_vector` | an older per-slot load/unload pair, kept for compatibility | mm³; 140 each |
| `flush_multiplier` | a factor applied to every matrix cell | default 0.3 |
| `flush_multiplier_fast` | the factor used instead in the "fast" purge mode (`prime_volume_mode`) | default 1.2 |
| `prime_volume` | the volume primed on the tower per change when the matrix is not used | mm³; default 45 |
| `enable_prime_tower`, `prime_tower_width` | whether a tower is printed, and its width | — |
| `flush_into_infill`, `flush_into_objects`, `flush_into_support` | purge sent into the print instead of wasted | — |

**How the purge is worked out:**
- Orca builds one purge table per nozzle. When a single nozzle is fed several filaments (an AMS-style
  machine, "single extruder multi material" with purging on the tower), the table is the
  `flush_volumes_matrix` for that nozzle. **Otherwise each change costs a flat `prime_volume`**,
  whichever filaments meet. A toolchanger such as the Snapmaker U1, with a nozzle per tool, is in
  this second case.
- Every cell is then multiplied by `flush_multiplier` (or `flush_multiplier_fast` in fast mode).
- The total purge for a run of filaments on one nozzle is the sum of the table cell for each
  consecutive pair in the order they are used: from the first to the second, the second to the
  third, and so on.

Khayt consequence (engine A's purge estimate): grams of purge ≈ Σ over the colour changes of
(table cell × multiplier) mm³ ÷ 1000 × the incoming filament's density. That needs the number and
order of changes per layer, which a 3MF does not store; A estimates it from which slots each layer
height range uses, and says it is an estimate. The figure is checked against real slices (engine B).

## 4. Painted colours (already Khayt's own)

The per-triangle paint string is the `paint_color` attribute (`bbs_3mf.cpp` line 363); Orca's internal
name for it is MMU segmentation. Khayt's decoder (`lib/mf-mesh.js`) was written from Khayt's own
bedready `paint.ts`, before this file existed, and is not derived from Orca. The facts it relies on
(the string is a recursive split of the triangle, read as 4-bit digits, a state of 0 meaning "the
object's own slot") are recorded here so the two stay independent; the decoder is not to be changed
from Orca's `TriangleSelector.cpp`.

## Not yet learned (next sections)

- How a plate's per-slot grams are reported in `slice_info.config` (for a project that WAS sliced).
- The overhang/support decision (angle threshold and the settings that switch it).
- Wall, top/bottom and infill volume from settings, for grams from geometry.
