# Booting from the QSPI flash

The FPGA loses its design at power-off. With the design stored in the
Arty's QSPI flash and the MODE jumper on, it loads itself at power-on in
about 25 ms, with no PC or Vivado needed. Done and tested 2026-11-09.

## How it is set up

| What | Where | Setting |
|---|---|---|
| Read the flash on 4 wires | `constraints/Arty-A7-35-Master.xdc` | `BITSTREAM.CONFIG.SPI_BUSWIDTH 4` |
| Configuration clock | same | `BITSTREAM.CONFIG.CONFIGRATE 33` (MHz) |
| Compress the bitstream | same | `BITSTREAM.GENERAL.COMPRESS TRUE` |
| Write a `.bin` with every `.bit` | `scripts/create_project.tcl` | `STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE true` on `impl_1` |

- `.bit` is for JTAG: the configuration data plus a text header. `.bin` is
  the raw data the FPGA reads from flash address 0.
- Compression shrinks the image from about 2.2 MB to **408 KB** (the
  design uses a small part of the chip). At 4 wires × 33 MHz = 132 Mbit/s
  that loads in about 25 ms. The defaults (1 wire, ~3 MHz, uncompressed)
  would take about 6 s.
- 33 MHz, not the flash's 100+ MHz: the FPGA makes this clock from an
  internal oscillator that can be up to ±50 % off.
- The XDC's `## Quad SPI Flash` pins (`qspi_cs`, `qspi_dq`) are for user
  logic reading the flash after start-up. Booting doesn't need them; leave
  them commented out.

## Updating the flash after a change

**Quick way (2026-11-24): `scripts/program_flash.tcl`**, after Generate
Bitstream. From the Vivado Tcl console (GUI open or not):

    cd D:/Repos/guitar-fx
    source scripts/program_flash.tcl

It takes `impl_1/top.bin` from the repo path (prints its build date),
connects, adds the flash part if Vivado has forgotten it, erases, programs
and verifies (stops with an error if any step fails), then reboots the FPGA
from the flash. About 15 s of flash work. Or from a terminal, without the
GUI: `vivado -mode batch -nojournal -nolog -source scripts/program_flash.tcl`.
Then check with `fx.py --port COMx read version`.

The same by hand, in the GUI:

1. **Generate Bitstream.** `build/vivado/guitar-fx.runs/impl_1/` gets
   `top.bit` and `top.bin`.
2. **Hardware Manager → Open Target → Auto Connect.**
3. Right-click `xc7a35t_0` → **Add Configuration Memory Device** →
   **`mt25ql128-spi-x1_x2_x4`** (the Micron MT25QL128 on this board; older
   Arty A7s have a Spansion S25FL128S instead). Once added, it stays under
   the FPGA; next time right-click it → **Program Configuration Memory
   Device**.
4. Configuration file = `top.bin`; keep Erase, Program and Verify ticked.
   Vivado loads a helper design to reach the flash, so the effect stops
   while it programs.
5. Press **PROG** (or unplug and replug the USB) to boot the new design.

For a quick test without touching the flash, program `top.bit` over JTAG
as before: it runs until the next power-off, then the flash design comes
back.

### Checks (learned 2026-11-24)

A power cycle once brought back an old flash image without the UART (`fx.py`
got "no reply" although the build was right). What to check:

- **The flash device can vanish** from Hardware Manager after
  `scripts/create_project.tcl` rebuilds the project: add it again (step 3).
- **The file:** check the full path and date in the Configuration file box:
  `build/vivado/guitar-fx.runs/impl_1/top.bin`, from the build you mean.
  The dialog can remember an older path.
- **The result:** Vivado must report that flash programming completed
  successfully (with Verify ticked). Anything else: it isn't in the flash.
- **Boot test:** unplug and replug the USB (a real power cycle), then
  `.venv\Scripts\python model\fx.py --port COMx read version`. It must
  answer (2 for `ctrl_regs` v2), and `read out_gain` gives the power-up
  default 0.03125: proof it booted from flash, not a design still loaded
  over JTAG.
- **"no reply" from fx.py on every register** = no UART in the running
  design (the old image), not a wrong register: re-flash. The Arty shows
  one COM port (VID:PID 0403:6010); the other half of its FTDI chip is the
  JTAG.

## On the board

- **MODE jumper (JP1)** on: boot from flash at power-on. Off: wait for
  JTAG.
- At power-on: **DONE** LED on at once, the clock's **locked** LED on,
  then 3 s of silence (`soft_start`) and the audio fades in.
- Tested 2026-11-09 after a power cycle: locked LED on, bypass gain
  −28.8 dB at 1 kHz, the same as JTAG-programmed builds.
