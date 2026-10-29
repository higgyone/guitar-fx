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
- P8 Pmod I2S2 input network (coupling cap / resistors in front of the
  CS5343): check the Pmod schematic for the impedance the preamp drives.

## Converter levels (Pmod powered at VA = 3.3 V)

| Item | Spec | At 3.3 V | Source |
|------|------|----------|--------|
| ADC full-scale input (CS5343) | 0.568 × VA Vpp (typ) | 1.87 Vpp = 0.94 V peak | CS5343/44 datasheet p5 |
| ADC input impedance (chip) | 7.5 MΩ (typ) | — | CS5343/44 datasheet p5 |
| DAC full-scale output (CS4344) | 0.65 × VA Vpp (typ; 0.60–0.70) | 2.15 Vpp (1.98–2.31) | CS4344/45/48 datasheet p6 |
| DAC output impedance | 100 Ω (typ) | — | CS4344/45/48 datasheet p6 |
| DAC min AC load / max load C | 3 kΩ / 100 pF | — | CS4344/45/48 datasheet p6 |

Preamp target: loudest guitar peak ≈ −6 dB below ADC full scale.
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
