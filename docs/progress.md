# Progress log

Where the project stands and what comes next. **Read this at the start of
every session (either PC); update it at the end.**

## Current state (2026-11-01, end of session, laptop)

### FPGA: `gain_stage` — v2 (saturation) done; next v3 (rounding)

- **v1** (#8): registered Q4.38 product, slice `s_sample_gain(38 downto 15)`
  → Q1.23, one-clock `sample_out_valid`, latency 1 clock.
- **v2** (#10): saturation. `s_overflow` = `'1'` unless product bits 41..38
  are all `0` or all `1`; output clamps to `c_sample_max`
  `(23 => '0', others => '1')` / `c_sample_min` `(23 => '1', others => '0')`,
  direction from bit **41** (the true sign; bit 39 is wrong for e.g.
  −1.0 × 3.5). All 21 tests pass (group 1: 12 exact, group 2: 9 saturation).
  Claude added the comments (user asked).
- **Next — v3: rounding.** Still truncating (rounds towards −∞). Open
  question to the user: one output step is bit 15; what is half of it (power
  of 2, which bit)? Answer: 2^14, bit 14. Then: add 2^14 to the product
  before slicing, saturate after rounding (rounding can push +0.99999 over
  the top). Claude adds testbench group 3 (rounding) **before** the user
  writes v3. Think about where the add goes (before or after the product
  register) and its effect on latency / timing.

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
  + testbench (#8); saturation tests; v2 saturation done (#10).
