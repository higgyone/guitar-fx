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
