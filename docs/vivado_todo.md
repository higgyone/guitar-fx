# Vivado-PC TODO

Tasks that need Vivado. Tick them off on the Vivado PC and push.

- [x] Installed Vivado version: **2025.2** on the Claude PC. Keep the
  other PC on the same version (a project made by a newer Vivado won't open
  in an older one; the script itself is version-neutral).
- [x] `scripts/create_project.tcl` builds the project (tested 2026-10-30:
  part, VHDL-2008 file types, sim-only testbenches, runtime `all`).
- [x] UART / PC control (2026-11-18, laptop; done 2026-11-19: all four
  top_tb modes pass, WNS +0.722 ns, status and write work): re-run
  `scripts/create_project.tcl` (new: uart_*, cmd_decoder, ctrl_regs and
  testbenches); run `top_tb` in all four modes (`g_mode` 0..3) with the
  real Clocking Wizard; build, program. Then, with the venv:
  `.venv\Scripts\python -m serial.tools.list_ports -v` (find the Arty's
  COM port), `fx.py --port COMx status`, `fx.py --port COMx write
  control 0x85` (PC control: distortion + tremolo on), `status` again,
  `write control 0` to hand back to the switches. (The `.venv` doesn't
  exist on a fresh PC: `python -m venv .venv`, then
  `.venv\Scripts\python -m pip install -r model\requirements.txt`.)
  Don't `run all` after `launch_simulation`: the runtime is already
  `all`, and running on past top_tb's `finish` fails with an index error.
- [x] UART stage 2 (2026-11-23, laptop, after the user's fx.py
  conversions; done 2026-11-25: top_tb modes 0..4 pass, WNS +1.605 ns,
  in the flash, board test passed, PR #48): no new files, but tremolo_stage, ctrl_regs and top
  changed. Run `top_tb` in all five modes (`g_mode` 0..4) with the real
  Clocking Wizard (mode 3 is now 150 Hz and writes depth 0 over the
  UART); build (check WNS), program. Then `fx.py --port COMx status`
  (version 2, tremolo depth 0.5, rate 5.0011 Hz), SW2 up and
  `write tremolo_rate 8`, `write tremolo_depth 1.0` (should dip to
  silence), `write control 0x88` (PC control, tone filter on, the rest
  off), `write control 0` to hand back to the switches.
- [ ] Delay (2026-11-27, branch `effect-delay`, after the user's fx.py
  delay conversions): re-run `scripts/create_project.tcl` (new:
  `rtl/delay_stage.vhd`, `sim/delay_stage_tb.vhd`). `top_tb` modes 0..5
  already pass in CLI xsim; build (check WNS, and the utilisation report:
  24 RAMB36 for the delay buffer; built 2026-11-27: WNS +0.667 ns,
  24 RAMB36 in `delay_stage`), program. Then `fx.py --port COMx
  status` (version 3, delay off, 250 ms / 0.5 / 0.5), `write control 0x90`
  (PC control, delay only: echoes 250 ms apart, each half the last),
  `write delay_time 400`, `write delay_feedback 0.8` (longer tail),
  `write delay_mix 1.0` (echo only), `write control 0x91` (distortion +
  delay), `write control 0` to hand back to the switches (delay off).
