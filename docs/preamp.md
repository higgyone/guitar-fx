# Guitar preamp / buffer

Status: **requirements draft.** Design not started.

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
| C_in | 33 nF film | 4.8 Hz (1 MΩ) | non-polar |
| C_g | 3.3 µF electrolytic | 4.8 Hz (10 kΩ) | + to Rg (4.5 V), − to GND |
| C_out | 3.3 µF electrolytic | 4.7 Hz (10.2 kΩ Pmod) | + to op-amp out (4.5 V), − to Pmod (0 V) |

Still to do: Vbias divider values + filter cap; op-amp choice; supply
filtering / reverse-polarity protection.

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
- **Chosen: Rg = 10 kΩ, Rf = 4.7 kΩ + 50 kΩ trim pot → G = 1.47 … 6.47.**
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

| Part | Input type | e_n @1 kHz | i_n | I_b | Supply range | RRO? | Price |
|------|-----------|-----------|-----|-----|--------------|------|-------|
|      |           |           |     |     |              |      |       |

## Also needed: output side

The I2S2 line out is line level. A guitar amp input expects instrument level.
Plan an attenuator (or use the amp FX return) before playing live.
