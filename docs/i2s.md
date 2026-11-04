# I2S interface to the Pmod I2S2 — design

Status: **design / groundwork.** No VHDL yet. The user writes the blocks;
Claude writes the testbenches (including a model of the Pmod's converters).

Sources: Pmod I2S2 reference manual, CS5343 (ADC) and CS4344 (DAC) datasheets
(local copies in `datasheets/`), notes in [spec.md](spec.md) §4.

## 1. What I2S is

Three wires carry audio one bit at a time, plus a master clock:

| Signal | Name on the Pmod | At 48 kHz | Job |
|--------|------------------|-----------|-----|
| MCLK | master clock | 12.288 MHz (256 × fs) | runs the converters' internal filters |
| SCLK | serial / bit clock (BCLK) | 3.072 MHz (64 × fs) | one data bit per clock |
| LRCK | left/right (word select) | 48 kHz (= fs) | low = left channel, high = right |
| SD | serial data | — | ADC → FPGA (`SDOUT`), FPGA → DAC (`SDIN`) |

One LRCK period = one **frame** = 64 SCLK = 32 bits left + 32 bits right.
Each 32-bit slot carries a 24-bit sample, **MSB first**, starting **one SCLK
after** the LRCK edge (the I2S delay); the remaining 7 bits are ignored.

```
LRCK  ‾‾‾\_________________________________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\___
SCLK  _/‾\_/‾\_/‾\_/‾\_ ... _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_ ... _/‾\_/‾\_
SD    xxx| -  |b23 |b22 | ... | b0 | x .. x | -  |b23 |b22 | ... | b0 | x ..
           ↑ 1 SCLK delay       left (24 of 32)      right (24 of 32)
```

Edges (Pmod manual): data **changes on SCLK falling** edges and is **valid on
SCLK rising** edges. So: the FPGA *reads* `SDOUT` at SCLK rising, and *drives*
`SDIN` at SCLK falling.

## 2. Board connections

FPGA is **master**: it makes MCLK, SCLK and LRCK for both converters.
Jumper **JP1 = SLV** (ADC in slave mode). Pmod in port **JA**:

| Pmod pin | Pmod signal | XDC port | FPGA pin | Direction |
|----------|-------------|----------|----------|-----------|
| 1 | DA MCLK | `ja[0]` | G13 | out |
| 2 | DA LRCK | `ja[1]` | B11 | out |
| 3 | DA SCLK | `ja[2]` | A11 | out |
| 4 | DA SDIN | `ja[3]` | D12 | out |
| 7 | AD MCLK | `ja[4]` | D13 | out |
| 8 | AD LRCK | `ja[5]` | B18 | out |
| 9 | AD SCLK | `ja[6]` | A18 | out |
| 10 | AD SDOUT | `ja[7]` | K16 | **in** |

Both rows get the same MCLK / LRCK / SCLK (one set of clocks for in and out).
Mono guitar: use the **left** channel in (tip of the jack), send the same
sample to **both** channels out.

## 3. Clock plan — one clock domain

The DSP so far runs on 100 MHz. 100 MHz cannot be divided down to
12.288 MHz exactly (100 / 12.288 = 8.14). Two options:

- **(a)** Keep 100 MHz for the DSP, make 12.288 MHz separately with the
  MMCM → **two clock domains** → every sample must cross between them
  (clock domain crossing: synchronisers, FIFOs — a hard topic).
- **(b) Proposed:** run the **whole design** from one MMCM output at
  **98.304 MHz = 8 × MCLK**, and make MCLK, SCLK and LRCK by **dividing**
  it with a counter. One clock domain, nothing to cross.

With (b): 98.304 MHz / 48 kHz = **2048 clocks per sample** (was 2083 at
100 MHz) — a power of 2, so a single free-running counter gives every clock:

| Clock | Divide 98.304 MHz by | = 2^n | Counter bit |
|-------|----------------------|-------|-------------|
| MCLK 12.288 MHz | 8 | 2^3 | 2 |
| SCLK 3.072 MHz | 32 | 2^5 | 4 |
| LRCK 48 kHz | 2048 | 2^11 | 10 |

Bit *n* of a counter repeats every 2^(n+1) clocks, so clk ÷ 2^p is bit p − 1.
The counter is **11 bits** (`unsigned(10 downto 0)`, 0 … 2047) and wraps to 0
by itself — no count-to-limit `if` needed. The MMCM (Clocking Wizard, configured by the user on the
Vivado PC) may only get *close* to 98.304 MHz. That is fine: the ADC and DAC
both run from the same clocks, so in and out rates match exactly; the
absolute rate being off by ~0.1 % shifts pitch by about 1 cent (inaudible).
GHDL testbenches just use an ideal 98.304 MHz clock (period ≈ 10.173 ns).

Internal logic never uses MCLK/SCLK/LRCK **as clocks**. They are outputs to
the Pmod pins. Inside, the counter also gives one-clock **strobes** (enables):
"SCLK is about to rise", "SCLK is about to fall", "new frame" — everything
stays clocked by the single 98.304 MHz clock.

### Strobes (one clock wide, flag the last value *before* the edge)

| Strobe | When | Counter |
|--------|------|---------|
| `sclk_rise` | SCLK about to go 0 → 1 | bits 4..0 = `01111` (15) |
| `sclk_fall` | SCLK about to go 1 → 0 | bits 4..0 = `11111` (31) |
| `frame_start` | LRCK about to fall: new frame, left slot | all 11 bits = `11111111111` (2047) |

A process that does something `when sclk_rise = '1'` therefore acts on the
same clock edge where SCLK rises.

### `i2s_clocks` ports

| Port | Dir | Type | Meaning |
|------|-----|------|---------|
| `clk` | in | `std_logic` | 98.304 MHz system clock |
| `reset` | in | `std_logic` | synchronous, active high |
| `mclk` | out | `std_logic` | counter bit 2 → Pmod MCLK (both rows) |
| `sclk` | out | `std_logic` | counter bit 4 → Pmod SCLK (both rows) |
| `lrck` | out | `std_logic` | counter bit 10 → Pmod LRCK (both rows) |
| `sclk_rise` | out | `std_logic` | strobe, see table above |
| `sclk_fall` | out | `std_logic` | strobe |
| `frame_start` | out | `std_logic` | strobe |

## 4. Blocks (user writes these)

```
                ┌─────────────── top level ───────────────┐
 CLK100MHZ ──→ [MMCM 98.304 MHz] ─→ clk                    │
               [i2s_clocks] ─→ mclk, sclk, lrck (to pins)  │
                        └─→ strobes                         │
 ja[7] SDOUT ─→ [i2s_rx] ─→ sample, valid ─→ [soft_start] ─→ [effects…] ─→ [i2s_tx] ─→ ja[3] SDIN
               └────────────────────────────────────────────┘
```

| Block | Does | Key ideas |
|-------|------|-----------|
| `i2s_clocks` | free-running counter → MCLK, SCLK, LRCK, strobes | counter bits as dividers, enables not clocks |
| `i2s_rx` | shifts in 24 bits of the left slot from `SDOUT`, outputs `sample_out` + one-clock `sample_out_valid` per frame | shift register, bit counting, I2S one-bit delay |
| `i2s_tx` | loads a sample per frame, shifts it out MSB first on `SDIN`, same sample in left and right slots | parallel-in serial-out shift register |
| top level | MMCM + the blocks + soft_start, Pmod ports | first top level, XDC pins |

`i2s_rx` / `i2s_tx` use the project's standard effect interface on their
audio side (`sample_out` / `sample_out_valid` and `sample_in` /
`sample_in_valid`), so the effects chain plugs straight in.

## 5. Order of work

1. `i2s_clocks` + testbench (Claude) checking frequencies and strobe timing.
2. `i2s_rx` + testbench with a **model of the CS5343 ADC** (Claude) that
   sends known samples on SDOUT.
3. `i2s_tx` + testbench with a **model of the CS4344 DAC** that captures SDIN.
4. Loopback in simulation: ADC model → rx → tx → DAC model, samples match.
5. Top level, Clocking Wizard and XDC (user, Vivado PC). When the Pmod
   arrives: PC line out → Pmod in → FPGA → Pmod out → headphones.

## 6. Open questions (user)

- Q1 Fill the clock table in §3: divide ratios, powers of 2, counter bits.
- Q2 How many bits does the free-running counter need?
- Q3 Why is one clock domain (option b) simpler than two (option a)?
- Q4 SCLK is a counter bit. On which counter value(s) is it about to rise,
  and about to fall? (These become the strobes.)
