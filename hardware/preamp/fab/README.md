# Preamp board: fab files (JLCPCB)

`preamp_jlcpcb_gerbers.zip` is the file to upload. `gerbers/` holds the same
files unzipped. Generated 2026-11-07 from `preamp.kicad_pcb` (DRC clean,
footprints checked against the datasheets, J3 slots widened to 1.5 × 0.8 mm).

| File | Contents |
|------|----------|
| `preamp-F_Cu.gtl` | L1, top copper |
| `preamp-GND.g1` | L2, GND plane |
| `preamp-PWR.g2` | L3, also a GND plane (layer name kept from the first draft) |
| `preamp-B_Cu.gbl` | L4, bottom copper (VCC pour + GND) |
| `preamp-F_Mask.gts` / `preamp-B_Mask.gbs` | Solder mask (vias tented) |
| `preamp-F_Silkscreen.gto` / `preamp-B_Silkscreen.gbo` | Silkscreen (logo on top) |
| `preamp-Edge_Cuts.gm1` | Board outline, including J3's notch |
| `preamp-PTH.drl` / `preamp-NPTH.drl` | Plated / non-plated holes, mm, J3's slots as G85 |
| `*-drl_map.gbr` | Drill maps (for checking, not needed by the fab) |
| `preamp-job.gbrjob` | Gerber job file: layer order, thickness, finish, stackup |

## JLCPCB order settings

Change these from the defaults after uploading the zip:

| Setting | Value |
|---------|-------|
| Layers | 4 (auto-detected) |
| Dimensions | 72.11 × 54.10 mm (auto-detected) |
| PCB thickness | 1.6 mm |
| Surface finish | **ENIG** |
| Outer copper weight | 1 oz |
| Inner copper weight | 0.5 oz |
| Specify stackup | **Yes: JLC04161H-3313** (the board was designed for its 0.1 mm prepreg) |
| Impedance control | No |
| Via covering | Tented |
| Min via hole / diameter | 0.3 mm / 0.6 mm (the board's only via size) |
| Mark on PCB (order number) | Remove, or let JLCPCB place it (see below) |
| Colour / silkscreen | Any (green + white is the cheapest and fastest) |

Everything else can stay at the defaults (FR-4, no castellated holes, no edge
plating, no gold fingers).

**Order number.** JLCPCB prints an order number on the silkscreen unless you
pay to remove it, or place the text `JLCJLCJLCJLC` on the silkscreen where
you want it. The board has no such text, so either pay for removal or accept a
location of their choice.

**Before paying:** check the board in JLCPCB's online Gerber viewer: four
copper layers in the right order (L2 and L3 solid GND with clearances round
the holes), the logo on the top silkscreen, the J3 notch in the outline, and
the three J3 slots.

## Assembly files (only if JLCPCB assembles the board)

| File | Contents |
|------|----------|
| `preamp_jlcpcb_bom.csv` | BOM: Comment, Designator, Footprint, Manufacturer, Manufacturer Part, LCSC Part # |
| `preamp_jlcpcb_cpl.csv` | Pick and place (CPL): Designator, Mid X, Mid Y, Layer, Rotation. 23 parts (all but J2), top side |
| `preamp-pos.csv` | KiCad's own position export, the CPL's source |
| `make_jlc_assembly.py` | Builds the two JLCPCB files from `preamp-pos.csv` and `../bom/bom.csv` |

- **C1 and C3 are LCSC substitutes** (ROQANG C72477 / C72484, same value,
  voltage and case size) because JLCPCB doesn't stock the Nichicon /
  Panasonic parts.
- **J2 (Neutrik NMJ4HCD2) is left out of both files** (`HAND_FIT` in the
  script): LCSC doesn't stock it, so it is soldered by hand.
- **LCSC Part # is otherwise empty.** JLCPCB matches lines by manufacturer part number
  when you upload; check each match, and pick an LCSC equivalent where the
  exact part isn't stocked. "Basic" parts avoid the extended-part setup fee.
- **Check rotations in JLCPCB's placement preview.** KiCad's and JLCPCB's
  footprint zero orientations differ for some packages (SOIC-8, SMA diode,
  electrolytics, trimmer). Fix pin 1 / polarity there before ordering.
- J1, J2, J3 and RV1 are through-hole. JLCPCB can fit them (extra cost), or
  untick them in the BOM step and solder them by hand.
- Coordinates are KiCad's absolute positions (Y negative), the same origin as
  the Gerbers, which JLCPCB's tool accepts.

## Silkscreen note

The footprint outlines (0.12 mm lines) and reference designators (0.8 mm
high, 0.12 mm stroke) are KiCad's library defaults, slightly below JLCPCB's
recommended 0.15 mm line and 1.0 mm text. They print, but the references may
be faint. Assembly can follow the KiCad layout on screen if any are hard to read.

## Regenerating

From `hardware/preamp`, with KiCad 10 (`kicad-cli` in `C:\Program Files\KiCad\10.0\bin`):

```bash
kicad-cli pcb export gerbers --layers F.Cu,In1.Cu,In2.Cu,B.Cu,F.Mask,B.Mask,F.SilkS,B.SilkS,Edge.Cuts --subtract-soldermask --no-x2 --check-zones --precision 6 -o fab/gerbers preamp.kicad_pcb
```

```bash
kicad-cli pcb export drill --format excellon --excellon-units mm --excellon-zeros-format decimal --excellon-oval-format alternate --excellon-separate-th --generate-map --map-format gerberx2 -o fab/gerbers/ preamp.kicad_pcb
```

Assembly files (after any BOM or placement change):

```bash
kicad-cli pcb export pos --format csv --units mm --side both -o fab/preamp-pos.csv preamp.kicad_pcb
```

```bash
cd fab && python make_jlc_assembly.py
```

Then zip the contents of `fab/gerbers` (files at the top level of the zip,
no folder) as `fab/preamp_jlcpcb_gerbers.zip`.
