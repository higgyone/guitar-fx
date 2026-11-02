# Progress log

Where the project stands and what comes next. **Read this at the start of
every session (either PC); update it at the end.**

## Current state (2026-11-02, end of session, laptop)

### FPGA: `gain_stage` — complete (v3)

- **v1** (#8): registered Q4.38 product, slice `(38 downto 15)` → Q1.23,
  one-clock `sample_out_valid`, latency 1 clock.
- **v2** (#10): saturation. Overflow when product bits 41..38 are mixed;
  clamp to `c_sample_max` / `c_sample_min`, direction from bit 41.
- **v3** (#11): round to nearest (ties up). `c_round` = bit 14 (2^14 = half
  an output LSB) added after the product register (`s_rounded`); overflow
  check and slice both use the rounded value. All 29 tests pass (12 exact,
  9 saturation, 8 rounding), latency 1. Lesson learnt on the way: adding
  the rounding constant twice (in the multiply *and* after it) adds a whole
  LSB — caught by group 1.

**Next — the user picks one:**
1. Hear it: user writes a Python model of the gain stage (guided); Claude
   writes WAV ↔ text plumbing; a testbench streams real audio through the
   VHDL and the output is listened to.
2. Effect 2: hard/soft clip distortion (non-linear functions, lookup tables).
3. Power-up mute / soft start block (reuses gain_stage).

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
- 2026-11-02: gain_stage v3 rounding (#11); gain stage complete.
