# Preamp BOM and order lists

Checked 2026-11-01 (UK sites, prices ex VAT). Order quantities = one board plus
spares (passives come in cut tape / packs, so 10 or the pack size).

| File | Use |
|------|-----|
| `bom.csv` | Master BOM: refs, values, chosen manufacturer part numbers |
| `order_mouser.csv` | Mouser BOM import. **Covers everything, all in stock** |
| `order_digikey.csv` | DigiKey BOM Manager (by manufacturer part number) |
| `order_rs.csv` | RS "upload a parts list" (stock no, quantity in units). **Incomplete** |

## Recommendation

Order from **Mouser**: one order covers the whole board and the Pmod I2S2
(≈ £50 ex VAT with the op-amp; Mouser UK's page says free shipping on most orders over £65).

## Substitutions vs the schematic values

- **C1**: Panasonic EEE-FK1E101P is out of stock at Mouser and DigiKey; Nichicon
  UCD1E101MCL1GS is the same 6.3 × 7.7 mm, 100 µF 25 V (RS does stock the FK).
- **C5 C6**: EEE-1EA3R3NR (Panasonic S series, 4 × 5.4 mm, 3.3 µF 25 V).
- **C4**: GRM1555C1H103JE01D (10 nF C0G 50 V 0402); the JA01D variant is not
  listed at Mouser/DigiKey.
- **C7 (DigiKey)**: GRM1555C1H101JA01D shows 0 stock there; JA01J is the same
  part on a different reel.

## Not available at RS

| Part | Status at RS | Get from |
|------|--------------|----------|
| J1 PJ-102AH | no longer stocked | Mouser 490-PJ-102AH / DigiKey CP-102AH-ND |
| J2 NMJ4HCD2 | not listed | Mouser 550-12202 / DigiKey 6473-NMJ4HCD2-ND |
| C2 100n X7R 0603 | only a reel of 4000 | Mouser / DigiKey |
| C4 10n C0G 0402 | not listed | Mouser / DigiKey |
| C5 C6 3u3 25V 4×5.4 | not listed | Mouser / DigiKey |
| U1 OPA1642AID | 812-2518 temporarily out of stock (back-order, in the list) | Mouser 595-OPA1642AID / DigiKey |

RS doesn't show stock levels outside the basket for several lines (resistors,
C7, C8): check them when uploading. C8 at RS is KEMET C0603C101J5GACTU
("last RS stock").
