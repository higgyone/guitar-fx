"""Build JLCPCB assembly files from KiCad's position export and the master BOM.

  preamp-pos.csv (kicad-cli pcb export pos) -> preamp_jlcpcb_cpl.csv
  ../bom/bom.csv (refs, values, MPNs)       -> preamp_jlcpcb_bom.csv

Run from hardware/preamp/fab:  python make_jlc_assembly.py
Fails if a placed part is missing from the BOM, or the other way round.
"""
import csv

POS, BOM = "preamp-pos.csv", "../bom/bom.csv"

# Fitted by hand, so left out of both JLCPCB files.
# J2 (Neutrik NMJ4HCD2): not stocked at LCSC.
HAND_FIT = {"J2"}

# Rotation added to KiCad's, where JLCPCB's part library has a different zero
# angle (checked in JLCPCB's placement preview).
# SOIC-8: KiCad's zero has pin 1 top left, JLCPCB's is a quarter turn round.
ROT_FIX = {"U1": 270}

with open(POS, newline="") as f:
    pos = list(csv.DictReader(f))
placed = {p["Ref"] for p in pos}

# CPL: JLCPCB's column names, rotation as 0..359, layer Top / Bottom
with open("preamp_jlcpcb_cpl.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
    for p in sorted(pos, key=lambda p: (p["Ref"].rstrip("0123456789"), int(p["Ref"].lstrip("ABCDEFGHIJKLMNOPQRSTUVWXYZ")))):
        if p["Ref"] in HAND_FIT:
            continue
        w.writerow([p["Ref"], f'{float(p["PosX"]):.4f}mm', f'{float(p["PosY"]):.4f}mm',
                    p["Side"].capitalize(), f'{(float(p["Rot"]) + ROT_FIX.get(p["Ref"], 0)) % 360:g}'])

def jlc_comment(ref, value, mpn):
    """The value as JLCPCB writes it, so their comment check matches:
    '2M2 1%' -> '2.2MΩ', '100R 1%' -> '100Ω', '3u3 25V' -> '3.3uF'.
    Anything that isn't an R or C gets its part number."""
    v = value.split()[0]                       # drop tolerance / voltage / dielectric
    if ref[0] == "R" and not ref.startswith("RV"):
        unit = "Ω"
    elif ref[0] == "C":
        unit = "F"
    else:
        return mpn
    for m in "RkMpnu":                         # 2M2 -> 2.2M, 100R -> 100, 3u3 -> 3.3u
        if m in v:
            a, b = v.split(m)
            v = a + ("." + b if b else "") + ("" if m == "R" else m)
    return v + unit


# Parts JLCPCB doesn't stock: an LCSC equivalent (same value, voltage and case
# size, so the footprint fits). Ref -> (manufacturer, part number, LCSC #).
# J2 (Neutrik NMJ4HCD2) has no LCSC equivalent: untick it and fit it by hand.
JLC_SUBSTITUTE = {
    "C1": ("ROQANG", "RVT1E101M0607", "C72477"),   # 100uF 25V, 6.3 x 7.7 mm, 105 °C
    "C3": ("ROQANG", "RVT1E100M0405", "C72484"),   # 10uF 25V, 4 x 5.4 mm, 105 °C
}

# BOM: one line per part number, designators comma-separated
rows, in_bom = [], set()
with open(BOM, newline="") as f:
    for b in csv.DictReader(f):
        refs = b["Ref"].split()
        if refs == ["-"]:
            continue                      # not on the PCB (Pmod I2S2)
        in_bom |= set(refs)
        refs = [r for r in refs if r not in HAND_FIT]
        if not refs:
            continue
        maker, mpn, lcsc = JLC_SUBSTITUTE.get(refs[0], (b["Manufacturer"], b["MPN"], ""))
        rows.append([jlc_comment(refs[0], b["Value"], mpn), ",".join(refs), b["Footprint"], maker, mpn, lcsc])

missing, extra = placed - in_bom, in_bom - placed
assert not missing and not extra, f"placed but not in BOM: {missing}; in BOM but not placed: {extra}"

with open("preamp_jlcpcb_bom.csv", "w", newline="", encoding="utf-8-sig") as f:
    w = csv.writer(f)
    w.writerow(["Comment", "Designator", "Footprint", "Manufacturer", "Manufacturer Part", "LCSC Part #"])
    w.writerows(rows)

print(f"CPL: {len(placed - HAND_FIT)} parts; BOM: {len(rows)} lines; hand-fit: {sorted(HAND_FIT)}")
