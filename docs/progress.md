# Progress log

Where the project stands and what comes next. **Read this at the start of
every session (either PC); update it at the end.**

## Current state (2026-11-02, end of session, laptop)

### FPGA: `gain_stage` — complete (v3, #11)

Registered Q4.38 product, round to nearest (`c_round` = bit 14 added after
the register), saturate (bits 41..38 mixed → clamp, direction from bit 41),
slice `(38 downto 15)` → Q1.23. Latency 1 clock. All 29 tests pass.

### FPGA: `soft_start` — in progress (entity written)

**Why:** hides the power-up thump (preamp Vbias settles over ≈ 2.5 s) and
the click of audio switching on: mute for 3 s, then ramp the gain 0 → 1.0.

**Decided:**
- **Option B:** `soft_start` has the standard effect interface and
  **contains a `gain_stage` instance**; internal ramp logic drives its
  `gain` port. First hierarchical design.
- Mute 3 s = **144,000 samples** (counter needs **18 bits**: 2^17 − 1 =
  131,071 is too small).
- Ramp **2,048 samples = 2^11** (42.7 ms), step **16** per sample:
  32,768 / 2,048 = 16 exactly (2,400 samples would give 13.65, not whole).
  Ramp gain = counter × 2^(15 − g_ramp_bits) (a left shift).
- Generics so the testbench can use tiny values (e.g. mute 10, ramp bits 3):
  `g_mute_length` (default 144000; suggested rename `g_mute_samples`) and
  `g_ramp_bits` (default 11).

**State table (agreed):**

| State | Gain to gain_stage | Counter | Move on |
|-------|--------------------|---------|---------|
| MUTE | 0 | +1 per `sample_in_valid` | at `g_mute_samples - 1` → RAMP, counter to 0 |
| RAMP | counter × 2^(15 − g_ramp_bits) | +1 per `sample_in_valid` | at `2 ** g_ramp_bits - 1` → RUN |
| RUN | 32,768 (1.0 in Q3.15) | stops | never (until reset) |

**Entity written** (`rtl/soft_start_stage.vhd`, entity `soft_start`,
compiles clean). To tidy: rename the file to `rtl/soft_start.vhd`; replace
the template comment on the generics with what they mean; optional rename
`g_mute_length` → `g_mute_samples`.

**Next step (user):** write the architecture's **state machine and counter
only** — `type t_state is (st_mute, st_ramp, st_run)`, `case` in a clocked
process, counter as `natural range 0 to g_mute_samples - 1`, both stepping
on `sample_in_valid`. Shown a traffic-light example of enum + case. Then:
gain value from state/counter, then the `gain_stage` instance. Claude writes
`sim/soft_start_tb.vhd` (small generics) when the architecture is ready.

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
- Recurring slips: off-by-one in bit ranges (N bits = `N-1 downto 0`) and
  in counts (N bits hold up to 2^N − 1; count 0..N−1 for N items), unit
  prefixes (k/µ/n — use "kΩ × µF = ms"), series vs parallel resistance.
  Worked small examples (Q1.3, 8-bit) help more than formulas.
- When stuck after a couple of tries, give a fill-in-the-blanks skeleton.

## Done

- 2026-10-29: project setup, spec, fixed-point lesson, preamp design (#1–#5).
- 2026-10-30: Vivado project script (#7).
- 2026-11-01: VS Code set up (VHDL LS, VHDLwhiz, EditorConfig); gain_stage v1
  + testbench (#8); saturation tests; v2 saturation done (#10).
- 2026-11-02: gain_stage v3 rounding (#11); gain stage complete.
  soft_start designed (states, numbers, option B); entity written.
