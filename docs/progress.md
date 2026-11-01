# Progress log

Where the project stands and what comes next. **Read this at the start of
every session (either PC); update it at the end.**

## Current state (2026-11-01, end of session, laptop)

### FPGA: `gain_stage` — v2 (saturation) in progress

- **v1 done** (merged in #8): registered Q4.38 product, truncating slice
  `s_sample_gain(38 downto 15)` → Q1.23, one-clock `sample_out_valid`,
  latency 1 clock. Testbench group 1 (12 exact cases) passes.
- **Testbench group 2 (9 saturation cases) added** to
  `sim/gain_stage_tb.vhd`. v1 fails its first case as expected:
  `sat max x2: expected 8388607, got -2` (wraps instead of clamping).
- **v2 work in progress** in `rtl/gain_stage.vhd` (committed as-is, so
  group 2 still fails and GHDL warns `s_overflow` is never referenced).
  The user has declared `s_overflow` and two constants. Still to do:
  1. **Overflow check** (concurrent, outside the process): `s_overflow` is
     `'0'` when product bits 41..38 are all `0` or all `1`, else `'1'`.
     Compare the 4-bit slice `s_sample_gain(41 downto 38)` with `"0000"` and
     `"1111"` (or `= 0` / `= -1`, or VHDL-2008 reduction `and` / `or`).
  2. **Fix the constants**: the current ones are wrong
     (`c_byte_max` = `1111 0000…` = −0.125, `c_byte_min` = 0). Should be
     max `0111…1` = `(23 => '0', others => '1')`, min `1000…0`
     = `(23 => '1', others => '0')`. Rename to `c_sample_max` /
     `c_sample_min`.
  3. **Output select** (conditional assignment replacing the plain slice):
     slice when `s_overflow = '0'`; else `c_sample_max` when bit **41**
     = `'0'` (bit 41 is the true sign; bit 39 is wrong for e.g.
     −1.0 × 3.5); else `c_sample_min`.
  4. Run the testbench: groups 1 and 2 must pass; latency stays 1.
- **Then v3: rounding** (add half an output LSB, 2^14, before slicing;
  saturate after rounding). Claude adds testbench group 3 first.

Run (repo root, PowerShell):

    ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/gain_stage.vhd sim/gain_stage_tb.vhd
    ghdl -r --std=08 --workdir=$env:TEMP gain_stage_tb

### Preamp (docs/preamp.md)

Designed except the op-amp: gain stage (Rg 10k, Rf 4.7k + 50k trim,
G 1.47–6.47), coupling caps, Vbias (100k/100k + 10 µF, buffered by the spare
op-amp half), supply input (1N5817, 100 Ω + 470 µF, 100 nF decoupling).
**Open:** fill the op-amp comparison table and choose a part.

### Hardware

Pmod I2S2 to be bought. Guitar peak level not measured yet (scope, ×10 probe).

## How the user learns best

- Short steps, one question at a time; check understanding before moving on.
- Recurring slips: off-by-one in bit ranges (N bits = `N-1 downto 0`), unit
  prefixes (k/µ/n — use "kΩ × µF = ms"), series vs parallel resistance.
  Worked small examples (Q1.3, 8-bit) help more than formulas.
- When stuck after a couple of tries, give a fill-in-the-blanks skeleton.

## Done

- 2026-10-29: project setup, spec, fixed-point lesson, preamp design (#1–#5).
- 2026-10-30: Vivado project script (#7).
- 2026-11-01: VS Code set up (VHDL LS, VHDLwhiz, EditorConfig); gain_stage v1
  + testbench (#8); saturation tests; v2 started.
