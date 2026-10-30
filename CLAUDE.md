# CLAUDE.md

Guidance for Claude Code in this repository.

## Project

Guitar pedal effects in VHDL on a Digilent Arty A7-35T (Artix-7
XC7A35T-1L, `xc7a35ticsg324-1L`), the same board as the ULA project
(`C:\repos\ULA`). Purpose: the user learns VHDL and DSP.

GitHub: https://github.com/higgyone/guitar-fx

Spec: [docs/spec.md](docs/spec.md) (in progress).

## Working style: mentor, don't do

The user writes all design VHDL (`rtl/`). Claude:

- Explains what to build and why (DSP theory, fixed-point maths, block
  diagrams, timing), then lets the user write it.
- Reviews the user's code: says what is right, what is wrong, what could be
  better. Does not rewrite it unasked.
- Walks through compile / sim / synthesis errors: how to read the message and
  find the cause. No patched files.
- Asks questions to check understanding before moving to the next step.
- MAY write: testbenches (`sim/`), Python reference models and vector
  generators (`model/`), scripts, tooling config, docs, and comments in the
  user's code.
- Comments: factual, brief, descriptive enough to make sense months later.
- When in doubt, ask: "walk you through it, or just apply it?"

## Multi-PC setup

Two PCs, synced only through git. **Always `git pull` before starting and
push when stopping.**

| PC | Has | Used for |
|----|-----|----------|
| Claude PC | GHDL 6.0.0 (mcode), VSG, Python, VS Code + VHDL LS | writing VHDL, lint, GHDL simulation, Python DSP models |
| Vivado PC | Vivado | synthesis, implementation, timing, bitstream, programming, xsim sign-off, ILA |

Rules that keep both PCs working:

- **The Vivado project is not tracked.** `scripts/create_project.tcl`
  rebuilds it into `build/` (gitignored). Add a source file → add it to the
  Tcl script in the same commit. (Unlike ULA, which tracks `ULA.xpr`.)
- **Sources live in plain folders** (`rtl/`, `sim/`, `constraints/`), not
  under Vivado's `*.srcs/` tree, so GHDL and Vivado read the same files.
- **Portable VHDL-2008 only.** Testbenches must run in both GHDL and xsim.
- **Keep Xilinx IP out of the DSP core.** Clocking (MMCM) and anything
  Xilinx-only sit at the top level, so every effect block simulates in GHDL.
- **Vivado-PC TODO list**: anything needing Vivado goes in
  [docs/vivado_todo.md](docs/vivado_todo.md) so it isn't lost between PCs.

## Toolchain

- **Lint / format**: VSG, same rules as ULA ([vsg_config.yaml](vsg_config.yaml),
  4-space indent). Pre-commit hook runs `vsg --fix` on staged VHDL
  ([.pre-commit-config.yaml](.pre-commit-config.yaml), VSG rev `3.35.0`).
  Per-PC setup is in that file's header (pipx is broken on the dev box; use
  the manual venv).
- **Compile-time lint**: `ghdl -a --std=08 -Wall` should be clean.
- **Simulation (Claude PC)**: GHDL, scratch workdir outside the repo:
  ```powershell
  $work = "$env:TEMP\ghdl_gfx_work"; New-Item -ItemType Directory -Force -Path $work | Out-Null
  ghdl -a --std=08 --workdir=$work rtl/<dut>.vhd sim/<dut>_tb.vhd
  ghdl -r --std=08 --workdir=$work <dut>_tb
  ```
  Analyse dependencies first. Self-checking TBs end with `ALL TESTS PASSED`.
- **Gotchas (from ULA)**: time literals need a space (`10 ns`); no UTF-8 BOMs.

## Effect interface

Every effect block uses the same ports (full table in docs/spec.md §4):
`clk`, `reset` (sync, active high), `sample_in` / `sample_out`
(`signed(23 downto 0)`, Q1.23), `sample_in_valid` / `sample_out_valid`
(1-clock pulses), then effect parameters.

## Layout

```
rtl/          design VHDL (user-written)
sim/          testbenches
model/        Python reference models, stimulus + golden vector generators
constraints/  XDC (Digilent master XDC, pins uncommented as used)
scripts/      create_project.tcl, GHDL run scripts
docs/         spec, notes, Vivado-PC TODO
hardware/     KiCad 10 projects (preamp/), one folder per board
```
