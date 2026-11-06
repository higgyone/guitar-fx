# Guitar preamp / buffer

Status: **schematic first draft** —
[hardware/preamp/preamp.kicad_sch](../hardware/preamp/preamp.kicad_sch)
(KiCad 10). Op-amp: **TI OPA1642AID** (dual JFET-input, SOIC-8). KiCad
has no OPA1642 symbol, so U1 uses the OPA1656ID symbol with the value
OPA1642AID: same standard dual SOIC-8 pinout.

Schematic notes (additions / deviations from the text below):
- R4 2M2 input pull-down on the jack side of C_in (no click on plug-in).
- R8 100k on the jack side of C_out (holds it at 0 V when unplugged).
- C_in (C4) is a 10 nF **C0G** ceramic in 0402, not film (SMD film starts
  ~1206). 33 nF C0G is hard to get in 0603 and not made in 0402; with the
  2M2 bias resistor 10 nF still gives 7.2 Hz (−0.03 dB at 82 Hz).
- Small R/C are 0603 with KiCad's hand-solder pads. Electrolytics are SMD
  cans (C1 6.3x7.7, C3/C5/C6 4x5.4). C5/C6 carry audio, so they stay
  electrolytic rather than class-2 ceramic (distortion, microphonics).
- D1 is an SS14 (SMA), the SMD equivalent of the 1N5817.
- RV1 is a Bourns 3296W multi-turn trimmer, adjusted from the top.
- Prototype (no enclosure yet): all three jacks are PCB-mount.
  J1 CUI PJ-102AH (pad 1 = centre = GND; pad 3 switch unused),
  J2 Neutrik NMJ4HCD2 (switch contacts unused), J3 CUI SJ1-3523N.
  Revisit for the enclosure (panel-mount jacks wired to pads).
- 3D models: KiCad 10 ships without the J1 / J2 STEP files, so the project
  library `hardware/preamp/preamp.pretty` (table `fp-lib-table`) holds copies
  of those two footprints pointing at `3d/` (`${KIPRJMOD}`). Sources: CUI
  PJ-102AH (CUI's SolidWorks model, via github.com/KonevDN/Fork-Electronics-Library)
  and Neutrik NMJ4HCD2 (Neutrik's download). Alignment checked by rendering.
- Line out drives the 3.5 mm tip (left channel) only; ring not connected.
- **VBias ≈ 2.55–2.6 V, not mid-supply** (R2 220k / R3 100k). The OPA1642's
  input works only up to V+ − 3.5 V (datasheet p7) ≈ 4.65 V at 8.15 V. At
  mid-supply (4.08 V) that left just 0.58 V for guitar peaks above bias at the
  (+) input. See "Vbias" for why 2.6 V rather than the first draft's 2.2 V.
- **R5 = 2M2** (bias resistor). With the 2M2 pull-down R4 the guitar sees
  R4 ∥ R5 = 1.1 MΩ (was 690 kΩ with 1 MΩ, below R1). C_in corner 7.2 Hz.
- **Review fixes (2026-11-01, independent design review):**
  - **R6 = 0 Ω link** → G = 1 … 6 (was 1.47 … 6.47), so a hot pickup (up to
    the ADC's 1.875 V peak) can be run at unity without clipping. Fit a
    resistor in R6 to raise the minimum gain if the pot is too coarse.
  - **C7 100 pF C0G across R6 + RV1** (U1 pin 2 to pin 1): the input
    capacitance (~6 pF + pads) with Rf ∥ Rg (up to 8.5 kΩ) put a pole at
    ~1.8 MHz, right at the loop crossover at G = 6 (11 MHz / 6). C7 rolls the
    gain back to 1 above ~32 kHz (at max Rf), so the loop stays stable.
  - **R10 1k in series with U1 pin 3** (C4 → R10 → pin 3, R5 on the op-amp
    side) and **C8 100 pF C0G from the jack tip to GND**: RF filter (AM pickup
    by the JFET input) and current limit for ESD / overdrive into the input
    clamp diodes (datasheet: limit to 10 mA). 100 pF adds little to the
    cable's 300–1000 pF, so the pickup's resonance barely moves. R10 noise
    (4 nV/√Hz) is below the op-amp's.
  - Voltage ratings now on the schematic: C2 100n X7R 50 V, C4 C0G 50 V.
- **R9 100 Ω** in series after the feedback tap, before C_out: isolates the
  cable capacitance from the op-amp output and limits plug-in current.
  Costs ≈ 0.1 dB into the Pmod's 10.2 kΩ.

Purpose: turn a passive guitar pickup signal into a line-level signal for the
Pmod I2S2 line input, without loading the pickups.

## Requirements (draft)

| # | Requirement | Value | Why |
|---|-------------|-------|-----|
| R1 | Input impedance | ≥ 1 MΩ | Pickups are ~5–15 kΩ DC with high inductance; a low load forms a low-pass with the pickup and dulls the tone |
| R2 | Gain | ~2–5× (6–14 dB), trimmable | Bring guitar peaks (~0.1–1 V) close to the ADC full scale, leaving headroom |
| R3 | Max output | below I2S2 line-in full scale | Avoid clipping the ADC, protect the input |
| R4 | Low-frequency cutoff | < 20 Hz | Low E is 82 Hz; keep the fundamental |
| R5 | Noise | low (op-amp + 1 MΩ resistor noise) | Gain later in the chain amplifies it |
| R6 | Supply | ? (e.g. 9 V pedal supply) | Headroom; Pmod 3.3 V is too low for much swing |

## Known

- Guitar: passive single-coil pickups.
- Bench supply: variable, 0–30 V, 5 A. Fine for development; the final pedal
  will want a standard 9 V (or 12–18 V) adaptor input with filtering.
- Own schematic + PCB layout, soldering; SMD packages are fine.
- Test gear: multimeter, oscilloscope.
- No op-amps on hand. Want a modern part, not TL072 / NE5532.

## Open questions

- P2 Final pedal supply: 9 V single rail (pedal standard), or higher for
  headroom? Single supply needs a Vbias = Vsupply/2 reference.
- P6 ~~I2S2 line-in full-scale level?~~ Found — see "Converter levels".
- P8 ~~Pmod I2S2 input network~~ Found — see "Pmod I2S2 analog circuits".

## Converter levels (Pmod powered at VA = 3.3 V)

| Item | Spec | At 3.3 V | Source |
|------|------|----------|--------|
| ADC full-scale input (CS5343) | 0.568 × VA Vpp (typ) | 1.87 Vpp = 0.94 V peak | CS5343/44 datasheet p5 |
| ADC input impedance (chip) | 7.5 MΩ (typ) | — | CS5343/44 datasheet p5 |
| DAC full-scale output (CS4344) | 0.65 × VA Vpp (typ; 0.60–0.70) | 2.15 Vpp (1.98–2.31) | CS4344/45/48 datasheet p6 |
| DAC output impedance | 100 Ω (typ) | — | CS4344/45/48 datasheet p6 |
| DAC min AC load / max load C | 3 kΩ / 100 pF | — | CS4344/45/48 datasheet p6 |

CS5343/44 datasheet: p5 = commercial grade (-CZZ, assumed on the Pmod; confirm
from IC2 marking), p6 = automotive grade (-DZZ). Full scale is near-identical.
Specs hold for a **source impedance ≤ 2.5 kΩ** → the ADC must be driven by the
preamp's op-amp output, never directly by the pickup.

## Pmod I2S2 analog circuits (schematic Rev A.0, `pmodi2s2_sch.pdf`)

**Line in (J3, blue), per channel:**

    jack ── R7 5.1k ──┬── C14 1uF ──┬── AIN (CS5343, 7.5 MΩ)
                      R9 5.1k       C19 180pF
                      GND           GND

- R7/R9 = 2:1 divider. **Full scale at the jack ≈ 2 × 1.87 = 3.75 Vpp
  (1.87 V peak).** Use this, not the chip figure, for preamp gain.
- Input impedance at the jack ≈ 10.2 kΩ (R7 + R9). The preamp drives this.
- ADC source impedance = R7 ∥ R9 = 2.55 kΩ (meets datasheet ≤ 2.5 kΩ, near enough).
- No DC block before R7 → preamp needs its own output coupling cap.
- C19 + 2.55 kΩ: low-pass ≈ 350 kHz (RF / anti-alias guard).

**Line out (J2, green), per channel:** DAC → C4 3.3 µF (DC block) → R3 10 kΩ
to GND → R1 470 Ω series → jack; C6 2.7 nF to GND at the jack (low-pass
≈ 125 kHz). Output ≈ 2.15 Vpp from ≈ 470 Ω.

Preamp target: loudest guitar peak ≈ −6 dB below full scale **at the jack**.

## Single-supply biasing (how it works)

- Op-amp output can only swing between its rails. On 0 V / +9 V, a signal
  centred on 0 V loses its negative half.
- Fix: centre everything on **Vbias = Vsupply / 2 = 4.5 V** ("virtual
  ground"). Made by two equal resistors (e.g. 100k/100k) + a large cap to GND
  (e.g. 47 µF) to hold it steady and filter supply noise.
- **Input:** C_in blocks DC (guitar at 0 V, op-amp at 4.5 V). 1 MΩ from (+)
  to Vbias sets the DC level and is the input impedance.
- **Gain trap:** non-inverting gain applies to DC too. Rg straight to GND →
  Vout(DC) = G × 4.5 V → hits the rail. **C_g in series with Rg**: at DC it
  blocks → gain 1 → output sits at 4.5 V; at audio it passes → gain G.
- **Output:** C_out removes the 4.5 V before the Pmod (which has no DC block
  ahead of its divider).
- Each cap + resistor is a high-pass: `f = 1 / (2πRC)`, aim < ~10 Hz.

```
                         +9 V
                          │
guitar ── C_in ──┬───── (+)\
                 │          op-amp ──┬──── C_out ──── Pmod line in
                1M       ┌─(−)/      │                (10.2 kΩ)
                 │       │           │
               Vbias     ├── Rf (4.7k + 50k pot) ──┘
              (4.5 V)    │
                         Rg 10k
                         │
                        C_g
                         │
                        GND
```

Cap values (target f ≈ 5 Hz, round **up** — bigger C = lower cutoff):

| Part | Value | Cutoff | Notes |
|------|-------|--------|-------|
| C_in | 10 nF C0G (0402) | 7.2 Hz with the 2M2 used (first draft: 33 nF, 2.2 Hz) | non-polar |
| C_g | 3.3 µF electrolytic | 4.8 Hz (10 kΩ) | + to Rg (4.5 V), − to GND |
| C_out | 3.3 µF electrolytic | 4.7 Hz (10.2 kΩ Pmod) | + to op-amp out (4.5 V), − to Pmod (0 V) |

## Vbias

As built (schematic R2 / R3 / C3, buffered by U1B):

    VCC 8.15 V ── R2 220k ──┬── R3 100k ── GND
                            ├── U1B follower → Vbias ≈ 2.55 V → R5 2M2
                            C3 10 µF (+ to node) ── GND

- **Why not mid-supply:** the OPA1642 (JFET input) only works with its
  inputs between V− − 0.1 V and V+ − 3.5 V, i.e. 0 … 4.65 V here. The (+)
  input carries the guitar signal on top of Vbias, so Vbias goes in the
  lower part of *that* range, not the middle of the supply.
- **Why 2.55 V and not 2.2 V (centre of the input range):** with gain > 1 the
  output carries G × the input, so the output's downward swing (to ≈ 0.2 V
  above GND into 10 k) is the real limit, not the input. At 2.2 V that left
  only ≈ 0.2 V beyond ADC full scale. Raising Vbias trades input room above
  bias (which only matters at G ≈ 1) for output room below it.
- Vbias = 8.15 × 100 / 320 = 2.55 V (2.63 V at the more likely 8.4 V).
  Input room +2.10 / −2.65 V; output swing ≈ −2.35 V / +5.4 V. The ADC
  (1.875 V peak) now clips before the op-amp does at every gain setting.
- Filter source resistance R2 ∥ R3 = 69 kΩ, × 10 µF → 0.23 Hz.

The original mid-supply working, kept for the reasoning:

    +9 V ── R1 100k ──┬── R2 100k ── GND
                      ├── Vbias 4.5 V → 1 MΩ input bias resistor
                      C_bias 10 µF (+ to Vbias) ── GND

- Noise on Vbias enters the (+) input via the 1 MΩ and is amplified by G —
  so Vbias must be well filtered.
- Divider current: 9 V / 200 kΩ = 45 µA. Load is only the 1 MΩ → no buffer.
- Filter source resistance R1 ∥ R2 = 50 kΩ. τ = 50k × 10 µF = 0.5 s.
- Cutoff 1/(2πτ) = 0.32 Hz → 100 Hz ripple cut ≈ 310× (−50 dB).
- Start-up: settles in ≈ 5τ = 2.5 s (acceptable for a pedal).
- Rejected: 4.7 µF (0.68 Hz, 1.2 s, −43 dB).
- **Buffer:** use the dual op-amp's spare half as a unity follower on the
  filtered node → low-impedance Vbias. The 10 µF stays on the follower
  *input*, never directly on its output (capacitive load → oscillation; add
  ~100 Ω series if any C is needed on the output). Never leave a spare half
  floating.
- A buffer does **not** speed up settling: it copies the RC node, which still
  settles in ≈ 2.5 s. Faster settle = smaller RC = less filtering.
- **Power-up thump:** handled digitally — FPGA mutes the input for a few
  seconds after reset, then ramps the gain up (~50 ms). See spec §6.

## Supply input

Pedal standard: **9 V DC, 2.1 mm barrel, centre negative** (Boss). Bench
supply for development.

    DC jack ──|>|── R_s 100 Ω ──┬────────────┬── V+ (op-amp, Vbias divider)
            D1 SS14             C_s 100 µF   100 nF ceramic at op-amp pin
                                │            │
    GND ────────────────────────┴────────────┴──

- D1 series Schottky: reverse-polarity block, ≈ 0.35 V drop. (Alternatives:
  shunt diode — harsh on supply; P-MOSFET — ≈ 0 V drop, more parts.)
- R_s / C_s low-pass: 100 µF → f ≈ 16 Hz, 100 Hz ripple ≈ −16 dB. Enough:
  the op-amp's own supply rejection does most of the work, and Vbias has its
  own filter (R2 ∥ R3 = 69 k with C3 10 µF → 0.23 Hz). 470 µF (3.4 Hz,
  −29 dB) was dropped as physically too big for no audible gain.
- 100 nF ceramic as close as possible to the op-amp supply pin (HF decoupling).
- Caps rated ≥ 25 V (≥ 2× supply; survives an 18 V adaptor).
- Supply at circuit ≈ 9 − 0.35 − (5 mA × 100 Ω) = **8.15 V** (check op-amp
  quiescent current: OPA1642 2 × 1.8 mA typ). The review estimates
  **≈ 8.4 V**: the SS14 drops ≈ 0.25 V at 4 mA, not 0.35 V. Vbias =
  0.3125 × VCC ≈ 2.55–2.6 V (ratio divider, tracks the supply).
- Output swing ≈ −2.35 V below Vbias (RRO, limited by the bottom rail):
  covers the 0.94 V target and the 1.875 V ADC full scale with ≈ 0.5 V spare.
- Ripple defence in depth: supply RC (−29 dB) → Vbias RC (−50 dB, the
  critical one) → op-amp PSRR (typ. 80–120 dB at 100 Hz).

## Mains hum (50 Hz UK)

No analog 50/60 Hz filter in the preamp:
- Inside the guitar's range (low E 82 Hz, drop D 73 Hz) — a notch thins the tone.
- Single-coil hum is mostly harmonics (100, 150, 200 Hz …): one notch removes little.
- Analog notches (twin-T) need matched parts and drift.

Reduce at source instead: grounded metal enclosure, single star ground, short
high-impedance input wiring, filtered supply and Vbias, input traces away from
power. Residual hum → handled digitally (noise gate; optional IIR notch at
50 Hz + harmonics — see spec §6).

## Gain

- Full-scale peak at jack: 3.75 Vpp / 2 = 1.875 V. Target (−6 dB): **≈ 0.94 V peak**.
- Guitar peak: not measured yet (typical single coil 0.3–0.5 V, hard strum).
  Measure: scope ×10 probe, bridge pickup, volume/tone full, single-shot
  trigger ~100 mV, hardest strum.
- Gain needed = 0.94 / guitar peak → ≈ 1.9 (0.5 V) … 3.1 (0.3 V) … 4.7 (0.2 V).
- Design: adjustable **G ≈ 1.5 … 5**, non-inverting, `G = 1 + Rf/Rg`,
  Rf = fixed + trim pot.
- **Chosen: Rg = 10 kΩ, Rf = R6 (0 Ω link) + 50 kΩ trim pot → G = 1 … 6.**
  (First draft had R6 4.7 kΩ, G = 1.47 … 6.47: a 1.3 V-peak pickup clipped
  even at minimum gain.) C7 100 pF across Rf limits the bandwidth (stability).
  Top of range can overdrive the ADC with hot pickups (clips, no damage:
  Pmod R7 5.1 kΩ limits current). Set the pot on the bench with the scope.
- P7 Op-amp choice — see below.

## Op-amp selection

Criteria, in order of importance for a high-impedance guitar input:

| Spec | Why it matters here |
|------|---------------------|
| Input current noise `i_n` | Multiplied by the source impedance. A pickup is ~10 kΩ at low frequency but hundreds of kΩ near its resonance (a few kHz). Bipolar inputs (NE5532: ~0.7 pA/√Hz) are noisy here; FET / CMOS inputs (fA/√Hz) are not. |
| Input bias current `I_b` | Flows through the 1 MΩ bias resistor → DC offset `I_b × 1 MΩ`. pA (FET) = µV, fine. µA (bipolar) = volts, not fine. |
| Input voltage noise `e_n` | Matters once current noise is negligible. < ~10 nV/√Hz is good. |
| Supply range | Must run from the chosen supply (single 9 V → needs ≥ ~4.5 V min, not ±15 V only). |
| Rail-to-rail output | More swing from a single low-voltage supply. |
| THD+N, slew rate | Modern audio parts are far better than needed; check, don't optimise. |
| Package / price / stock | SOIC-8 or MSOP-8 dual for layout; check distributor stock. |

Total input-referred noise density (to compare parts):

    e_total = sqrt( e_n^2 + (i_n * R_s)^2 + 4*k*T*R_s )

`4kTR_s` is the thermal noise of the source itself — no op-amp can beat it.

Candidates to compare (verify every figure against the datasheet):
FET/CMOS-input audio op-amps such as TI OPA1656, OPA1642, OPA1678, and
ADI ADA4625. Fill in the table:

| Part | Input type | e_n @1 kHz | i_n | I_b | Supply range | RRO? | PSRR @100 Hz | I_q per amp | Price |
|------|-----------|-----------|-----|-----|--------------|------|--------------|-------------|-------|
|      |           |           |     |     |              |      |              |             |       |

Must run from ≈ 8 V single supply (after D1 + R_s). Dual package: one half
gain stage, one half Vbias buffer.

**Chosen: OPA1642AID.** JFET input (pA bias current, fine with the 1 MΩ
bias resistor), 4.5–36 V supply, rail-to-rail output, ~5 nV/√Hz,
~1.8 mA per amp. Unity-gain stable for the Vbias follower.
Drop-in alternatives (same pinout, no other changes): OPA1652AID (FET,
4.5–36 V), TLC2272CDR (CMOS, 16 V max, so not for an 18 V adaptor).

## Output side (Pmod line out → amp)

Decided 2026-11-01: **no attenuator for the prototype.** The Pmod line out
(≈ 1.07 V peak full scale, 470 Ω source) is already close to guitar level:
with the preamp trimmed to −6 dBFS the amp sees ≈ 0.5 V peak, about +3 dB over
the bare guitar. The amp has no FX loop, so it goes into the front input.
- Adapter lead: 3.5 mm tip + sleeve → 6.35 mm TS, ring **not** connected
  (a TRS→TS adapter shorts the right DAC output to ground, below its 3 kΩ
  minimum load). FPGA sends zeros on the right channel.
- Match the bypass level digitally (output volume block, effect #1).
- Hum on the bench is most likely a ground loop (Arty on an earthed PC's USB
  + earthed amp): try the laptop on battery first.
- For an enclosure later: a switchable 0 / −10 / −20 dB L-pad after the Pmod
  (R_s 6.8k / R_p 3.3k, or 9.1k / 1k; keep R_s + R_p ≥ 4.3 kΩ).

## PCB (first draft, 2026-11-01)

[hardware/preamp/preamp.kicad_pcb](../hardware/preamp/preamp.kicad_pcb):
72 × 54 mm, 4 layers, M3 holes in the corners. Parts placed, power fanned out
to the planes, signal nets **not routed yet** (DRC lists them as unconnected).

| Layer | Use |
|-------|-----|
| L1 F.Cu | All parts, signal tracks, spare area poured **VCC** |
| L2 In1.Cu "GND" | Solid GND plane |
| L3 In2.Cu "PWR" | Solid VCC plane |
| L4 B.Cu | Spare signal layer, spare area poured GND |

Stackup (1.6 mm): 1 oz outer, 0.1 mm prepreg L1–L2, 1.24 mm core, 0.1 mm
prepreg L3–L4. Set the real figures from the fab's 4-layer stackup when
ordering.

- Why this order: every L1 track sits 0.1 mm over unbroken GND, so its
  return current runs directly underneath (smallest loop, least hum pickup)
  and L2 shields L1 from the VCC plane. Don't route on L2 or cut it.
- The L2–L3 core is thick, so plane-to-plane capacitance is small; C2
  (100 nF at U1 pin 8) and C1 still do the decoupling.
- L4 tracks reference the L3 VCC plane: keep L4 for short, non-critical runs.
- Fanout: every SMD GND / VCC pad has a 0.4 mm track to a 0.6 / 0.3 mm via
  (U1 pin 8 shares C2's VCC via). THT GND pads connect to every GND layer.
- The L1 VCC pour carries DC only, but it is copper next to the 1.1 MΩ input
  node (J2 tip → C4 → R10 → U1 pin 3 and R5). If that node picks up hum or
  supply noise, add a rule area on L1 that keeps the VCC pour away from it, or
  surround it with a GND guard track. The review also notes every L1 GND pad
  sits inside VCC copper (more chance of a VCC–GND solder bridge on a
  hand-soldered 0603); a GND pour on L1 would avoid both.
- Review fixes placed (2026-11-01): C8 beside J2's tip pad (GND via below
  it), C4 now 0402 in the same spot, R10 next to U1 pin 3 (R5 moved 1.5 mm
  right for it), C7 beside U1 pins 1–2. Keep the C4 → R10 → pin 3 track away
  from the pin 1 / R6 output track.
- Mounting holes H1–H4 (M3, non-plated) are **isolated from the chassis**:
  a ⌀9 mm rule area on all four copper layers keeps out pours, tracks and
  vias (M3 washer DIN 125 is 7 mm OD, so 1 mm margin; also clears a nylon
  standoff's hex). Don't rely on solder mask under a washer.
- `preamp.kicad_dru`: J3's library footprint draws its own edge notch and its
  silkscreen crosses it; a DRC rule allows that for J3 only.
