# Progress log

Where the project stands and what comes next. **Read this at the start of
every session (either PC); update it at the end.**

## Current state (2026-11-04, end of session, laptop)

### FPGA: `gain_stage` — complete (#11)

Registered Q4.38 product, round to nearest (`c_round` = bit 14 added after
the register), saturate (bits 41..38 mixed → clamp, direction from bit 41),
slice `(38 downto 15)` → Q1.23. Latency 1 clock. All 29 tests pass.
`s_rounded` now has an initial value (silences a 0 ms metavalue warning).

### FPGA: `soft_start` — complete (#13)

Hides the power-up thump: mute 3 s, then ramp the gain 0 → 1.0 over
2,048 samples (42.7 ms, step 16), then run at 1.0.

- Standard effect interface; **contains a `gain_stage` instance**
  (`gain_stage0`) whose `gain` is driven by `s_gain` — first hierarchical
  design.
- State machine `t_state` (st_mute, st_ramp, st_run) in a clocked process,
  stepping only on `sample_in_valid`; counter `natural range 0 to
  g_mute_samples - 1`, count-to-limit pattern (limit − 1, then reset to 0).
- Ramp gain `to_signed(s_counter * 2 ** (15 - g_ramp_bits), 18)`; jumps to
  1.0 at the last ramp sample. Generics `g_mute_samples` (144000),
  `g_ramp_bits` (11).
- `sim/soft_start_tb.vhd` (mute 6, ramp bits 2) checks mute = 0, ramp
  monotonic/bounded/long enough, run = input, reset → mute again. Passes.
- Known, harmless quirks: output lags the gain by one sample (s_gain and
  the product register update on the same edge) so the ramp starts with two
  zeros; the last ramp step is 2 steps (jump to 1.0).
- Lessons on the way: state changes must sit inside the count-to-limit
  `if`; reset must be the outer `if` (last assignment wins); `signed *
  integer` doubles the width (use integer maths then `to_signed`, or
  `shift_left`).

### Python: hear-it pipeline — working (#14)

- Project venv `.venv` (gitignored); packages in `model/requirements.txt`
  (numpy, scipy, matplotlib, ruff). Other PC: create the venv once (commands
  in that file's header).
- `model/gain_stage_model.py` (user-written): `gain_stage` (one sample,
  bit-exact) and `gain_stage_array` (numpy, `np.clip`); agree on 10,000
  random samples.
- `model/run_gain_stage.py` (user-written): reads `sim/out/test_guitar.wav`,
  writes `gain_in.txt`, runs GHDL (`subprocess`, gain passed as
  `-gg_gain=`), compares VHDL output with the model (0 mismatches on
  240,000 samples), writes `sim/out/gain_out.wav`. One command:
  `.venv\Scripts\python model\run_gain_stage.py` (repo root). GAIN was left
  at 2**10 (1/32) while its comment says 2.0 — user to fix.
- Plumbing by Claude: `model/wav_io.py`, `model/make_test_signal.py`
  (synthetic plucked guitar, 5 s), `sim/gain_stage_file_tb.vhd`.
- Ruff lints/formats Python (`ruff.toml`, pre-commit hook): docstrings with
  Args/Returns and type hints required on every function.

**Next — the user picks one:**
1. Effect 2: hard/soft clip distortion (non-linear functions, lookup tables).
2. **I2S interface — groundwork done** in [i2s.md](i2s.md) (2026-11-04): one
   98.304 MHz clock domain, MCLK/SCLK/LRCK from a free-running counter,
   blocks i2s_clocks → i2s_rx → i2s_tx → top. Clock design answered:
   11-bit counter, MCLK/SCLK/LRCK = bits 2/4/10, strobes at 15/31/2047
   (port table in i2s.md §3).
   - 2026-11-05 (Vivado PC): **`i2s_clocks` done** (user-written; branch
     `i2s-clocks`). `sim/i2s_clocks_tb.vhd` passes in xsim: every clock
     checked against an integer model, strobe-before-edge, LRCK changes only
     where SCLK falls, exact periods, 64/64/1 strobes per frame, reset
     mid-frame; it catches mutated strobe values / clock bits. TB clock is
     10.172 ns (an even number of ps, so the half period is exact). Grammar
     learned: bit select `v(n)`, slices, `when … else`, `to_unsigned`, and
     that `(others => '1')` is an aggregate, not an index.
   - 2026-11-05: **`i2s_rx` done** (user-written; branch `i2s-rx`). Counts
     sclk rising edges k from frame_start (counter stops at 25, reset/power-up
     at 25 so a mid-frame reset waits for the next frame), shifts k = 1..24,
     outputs `s_shift(22 downto 0) & sdout` at k = 24. `sim/i2s_rx_tb.vhd`
     (i2s_clocks + CS5343 model: delay bit = NOT b23, padding 1010, right
     slot = complement) passes in xsim; catches the Q5 copy trap, reset-to-0
     and a late shift start. Lessons: signals update after the edge (read =
     old value); a default outside `rising_edge` runs on both clock edges
     (half-clock pulse); `natural range a to b` starts at a unless given
     `:=`; last assignment wins.
   - 2026-11-05: **`i2s_tx` done** (user-written; branch `i2s-tx`). Counts
     sclk falling edges m (frame_start = m 0, tested before sclk_fall since
     both are '1' there; sets s_m to 1), position = m mod 32: 0 load / delay
     bit, 1..24 send s_shift(23) and shift, else '0'. Double buffer: s_hold
     catches samples any time, s_frame <= s_hold at m 0 (s_shift loads from
     s_hold on that clock), right slot reloads from s_frame at m 32.
     `sim/i2s_tx_tb.vhd` (i2s_clocks + CS4344 model; samples fed at awkward
     points incl. the frame_start and m 32 clocks; sdin stable ±30 ns round
     sclk rising) passes in xsim; catches strobe order, s_m 0, Q5-style
     load from s_frame, no double buffer, 23 bits. Lessons: count if/end if
     from the outside when the compiler says "syntax error near X" (the bug
     is above X); mutually exclusive cases belong in one if/elsif/else (the
     two separate ifs at positions 0 and 1..24 still work; merging is the
     user's call) — merged into one if/elsif/else afterwards (at the user's request).
   - 2026-11-05: **loopback sim passes** (`sim/i2s_loopback_tb.vhd`):
     ADC model → i2s_rx → i2s_tx → DAC model, rx output wired straight into
     tx. 39 frames of edge cases + a sine: DAC left = right = the ADC sample
     from the frame before (latency exactly one frame, 20.8 µs). Catches a
     broken rx (no `& sdout`) and a broken tx (23 bits).
   - 2026-11-06 (Vivado PC): **top level done** (branch `i2s-top`, user
     wrote all the VHDL and Vivado config):
     - XDC: 11 ports — `clk100mhz` (E3, lowercase; master `create_clock`
       commented out, the IP constrains its input), `reset_btn` (BTN0 D9),
       `led_locked` (LD4 H5), JA renamed `da_mclk/da_lrck/da_sclk/da_sdin/
       ad_mclk/ad_lrck/ad_sclk/ad_sdout`; all other pins commented; CFGBVS /
       CONFIG_VOLTAGE 3.3 added.
     - Clocking Wizard `clk_wiz_audio` created by `create_project.tcl`
       (create_ip + CONFIG only): 100 MHz → 98.30508 MHz (VCO 725 MHz =
       ×7.25, /7.375), 11 ppm off. Script also sets tops `top` / `top_tb`.
       Run it with the full path: `& "C:\AMDDesignTools5.2\Vivadoinivado.bat"
       -mode batch -source scripts/create_project.tcl` (Vivado not on PATH).
     - `rtl/top.vhd`: IP as a component (MMCM reset '0'), reset =
       `reset_btn or not locked` through a 2-FF synchroniser on s_clk
       (start '1'), i2s_clocks → rx → soft_start → tx, one set of I2S
       clocks to both Pmod rows; generics pass through to soft_start
       (defaults = hardware 3 s mute).
     - `sim/top_tb.vhd` (pins only: 100 MHz osc, ADC + DAC models, one
       button press) passes in Vivado with the real IP (~1.29 ms sim).
     - Implemented: **WNS +5.107 ns**, no critical warnings.
     - Lessons: XDC = only rename inside `get_ports { }`; a port has one
       direction (JA can't be one vector); IP needs a component; every
       signal exactly one driver; wire by where a signal comes from;
       generic map has no `;` before port map.
   - **Next: board test** when the Pmod I2S2 arrives (JA, JP1 = SLV): PC
     audio → LINE IN, LINE OUT → USB adapter mic in; expect 3 s silence
     then pass-through; BTN0 = silence then fade-in. For the mic input the
     level must be cut ~30 dB (÷32) — see the bench-kit note.

Run (repo root, PowerShell), e.g.:

    ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/gain_stage.vhd rtl/soft_start.vhd sim/soft_start_tb.vhd
    ghdl -r --std=08 --workdir=$env:TEMP soft_start_tb

On the Vivado PC: re-run `scripts/create_project.tcl` after pulling (new files).

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
- 2026-11-03: soft_start complete (state machine, ramp, gain_stage instance) + testbench (#13).
- 2026-11-04: Python venv, gain stage model, hear-it pipeline (0 mismatches), Ruff (#14).
