# UART control over the Arty's USB port — design

Status: **design / groundwork** (2026-11-13). No VHDL yet. The user writes
the blocks (and the Python on the PC side); Claude writes the testbenches,
including a model of the PC's serial port.

Goal (spec Q5.1 / Q5.2, progress "Later"): commands from the PC switch
effects in and out and change their parameters while the pedal runs.

## 1. What a UART is

One wire each way, no clock wire. Both ends agree on the speed (**baud
rate**, bits per second) in advance, and each byte is wrapped in a **frame**:

```
 idle  start  b0  b1  b2  b3  b4  b5  b6  b7  stop  idle
 ‾‾‾‾‾‾\_____/‾‾‾\___/‾‾‾ ...                /‾‾‾‾‾‾‾‾‾‾‾
        0     LSB first ................ MSB  1
```

- The line **idles high**.
- **Start bit** = one bit time low: "a byte is coming".
- **8 data bits, least significant first.**
- **Stop bit** = one bit time high (back to idle).
- No parity. This format is called **8N1** (8 data, no parity, 1 stop):
  10 bit times per byte.

Because there is no clock wire, the receiver times each bit itself from the
falling edge of the start bit, and samples each bit in its **middle**, where
it is most stable. Small speed differences between the two ends are fine as
long as the error over 10 bits stays well under half a bit (in practice keep
the rate within about ±2 %).

## 2. On the Arty

The board's USB port is an FTDI FT2232 chip. One half is the JTAG
programmer, the other half is a serial port that appears on the PC as a
**COM port** (Device Manager → Ports). Same USB cable as programming.

| XDC port | FPGA pin | Direction (FPGA's view) |
|----------|----------|-------------------------|
| `uart_txd_in` | A9 | **in**: the FTDI's TXD → FPGA receives (`uart_rx`) |
| `uart_rxd_out` | D10 | **out**: FPGA transmits (`uart_tx`) → the FTDI's RXD |

Name = the FTDI chip's pin + the direction from the FPGA's side. One side's
transmit always wires to the other side's receive.

## 3. Baud rate and timing

Proposed **115 200 baud, 8N1** (a standard rate every terminal supports).
The design runs on s_clk = 98.305 MHz, so one bit lasts
s_clk / 115 200 clocks — not a whole number. The transmitter and
receiver count whole clocks, so the rate is slightly off:

| | Working | Value |
|---|---|---|
| Clocks per bit | 98 305 000 / 115 200 = 853.34 | **853** |
| Actual baud | 98 305 000 / 853 | 115 246 |
| Error | (115 246 − 115 200) / 115 200 | **+0.04 %** (limit ~±2 %) |
| Bit counter | 0 .. 852 | **10 bits** (max 1023) |
| One byte (10 bits) | 10 / 115 200 | **86.8 µs** |
| Max rate | 115 200 / 10 | **11 520 bytes/s** |
| Audio samples per byte | 86.8 µs / 20.8 µs | **≈ 4.2** |

The UART is far slower than the audio: a 3-byte command spans ~12 samples.
The effects simply pick up new register values whenever they change.

### Why `uart_txd_in` needs a synchroniser (Q3)

The PC's UART is timed by its own clock, unrelated to s_clk, so its edges
can land inside a flip-flop's setup/hold window and make it **metastable**
(stuck between 0 and 1 for a while). A second flip-flop samples it a clock
later, after it has settled. The I2S input needed none: the ADC changes
`ad_sdout` on SCLK falling, which the FPGA itself makes from s_clk, and it
is read ~16 clocks later at SCLK rising. Rule: synchronise **once**, then use
only the synchronised signal.

## 4. Blocks (user writes these)

```
 PC ─USB─ FT2232 ── uart_txd_in ──→ [2-FF sync] → [uart_rx] ──→ byte, valid ─→ [command decoder] ──→ registers ──→ effect parameters
                 ←─ uart_rxd_out ←─────────────── [uart_tx] ←── byte, valid ←─┘ (replies / echo)
```

| Block | Does | Key ideas |
|-------|------|-----------|
| `uart_tx` | sends one byte: start bit, 8 bits LSB first, stop bit; `busy` while sending | bit-time counter, shift register (like `i2s_tx`) |
| `uart_rx` | finds the start bit, samples each bit mid-way, outputs the byte with a one-clock `valid` | 2-FF synchroniser (asynchronous input), half-bit wait, state machine |
| command decoder | turns received bytes into register writes, sends a reply | protocol design, a small register file |
| top level | pins, wiring the registers to the effects instead of fixed generics | runtime parameters |

Interface style: a byte plus a one-clock valid pulse, like the audio
`sample` / `sample_valid` pairs.

### `uart_tx` design (agreed 2026-11-13)

| Port | Dir | Type | Meaning |
|------|-----|------|---------|
| `clk` | in | `std_logic` | s_clk, 98.305 MHz |
| `reset` | in | `std_logic` | sync, active high |
| `data_in` | in | `std_logic_vector(7 downto 0)` | byte to send |
| `data_in_valid` | in | `std_logic` | one-clock pulse: send it (ignored while busy) |
| `tx` | out | `std_logic` | serial line → `uart_rxd_out` (D10); idles '1' |
| `busy` | out | `std_logic` | '1' from load until the end of the stop bit |

Generic `g_clks_per_bit` (853; the testbench uses a small value).

- 10-bit shift register loaded with `'1' & data_in & '0'` (stop, data, start);
  `tx = s_shift(0)`; shift **right**, shifting in `'1'`, so it sends start,
  d0 … d7, stop, then stays high (idle) with no extra logic.
- `s_baud_count` 0 .. g_clks_per_bit − 1 (count-to-limit), `s_bit_count`
  0 .. 9; busy clears when bit 9's time ends. Reset: register all '1'.

### `uart_rx` design (agreed 2026-11-14)

| Port | Dir | Type | Meaning |
|------|-----|------|---------|
| `clk`, `reset` | in | `std_logic` | as always |
| `rx` | in | `std_logic` | raw pin `uart_txd_in` (A9), not yet synchronised |
| `data_out` | out | `std_logic_vector(7 downto 0)` | received byte |
| `data_out_valid` | out | `std_logic` | one-clock pulse: good byte |
| `frame_error` | out | `std_logic` | one-clock pulse: stop bit was '0', byte discarded |

Generic `g_clks_per_bit` (853).

- 2-FF synchroniser `s_rx_meta` → `s_rx_sync`, both starting **'1'** (idle;
  '0' would look like a start bit). Only `s_rx_sync` is used after it.
- Sample in the **middle** of each bit: half a bit (`g_clks_per_bit / 2` =
  426, integer division) after the start bit's falling edge, then every full
  bit. Margin ±½ bit; after 9.5 bits a 2 % rate error drifts ~0.19 bit.
- LSB first → shift **right**, new bit in at the top:
  `s_data <= s_rx_sync & s_data(7 downto 1)`; after 8 bits d0 is in bit 0.
- States: `st_idle` (wait for '0') → `st_start` (half bit; still '0'? else
  glitch → idle) → `st_data` (8 × full bit, shift) → `st_stop` (full bit;
  '1' → valid pulse, '0' → frame_error pulse) → idle.

### Echo test: can `uart_tx` be busy when a byte arrives? (yes)

Echo = uart_rx's byte + valid straight into uart_tx. uart_rx pulses valid
at the middle of each stop bit (9.5 bits after the start bit); uart_tx then
stays busy for exactly 10 of **our** bit times (853 clocks each). With
back-to-back input the next valid comes 10 of the **PC's** bit times later:

- PC at exactly 115 200 (853.3 clocks/bit) or slower: echo finishes ~2
  clocks before the next valid. Just in time.
- PC slightly fast (USB-UART chips often land a little above 115 200): the
  next valid arrives while uart_tx is busy and that byte is **dropped**.

Typing by hand never hits it (gaps between keys). **Pasting text** may drop
characters — worth trying on the board. Fix: a small FIFO between uart_rx
and uart_tx. A FIFO absorbs bursts, not a permanent rate difference; fine
for short commands (16 bytes is plenty).

### `uart` wrapper block (2026-11-15)

`top.vhd` is ~400 lines; the UART goes in as **one** structural block (like
`soft_start` containing `gain_stage`), built from the user's `uart_rx`,
`uart_fifo` (branch `uart-fifo`: count-based circular buffer, show-ahead
read, guarded write/read, overflow pulse) and `uart_tx`:

```
 rx ──→ [uart_rx] ──→ rx_data, rx_valid, rx_frame_error ──→ (out)

 (in) tx_data, tx_valid ──→ [uart_fifo] wr_data, wr_en
                                  │ rd_data ──→ [uart_tx] data_in ──→ tx
                                  │ rd_en ←── not empty and not busy ──→ data_in_valid
                            full ──→ tx_full (out),  overflow ──→ tx_overflow (out)
```

| Port | Dir | Goes to |
|------|-----|---------|
| `clk`, `reset` | in | all three blocks |
| `rx` | in | `uart_rx.rx` (pin `uart_txd_in`, A9) |
| `tx_data` (7..0), `tx_valid` | in | `uart_fifo.wr_data`, `wr_en` |
| `tx` | out | `uart_tx.tx` (pin `uart_rxd_out`, D10) |
| `rx_data` (7..0), `rx_valid`, `rx_frame_error` | out | from `uart_rx` |
| `tx_full`, `tx_overflow` | out | from `uart_fifo` |

Generics: `g_clks_per_bit` (853, to uart_rx and uart_tx), `g_fifo_addr_bits`
(4, to uart_fifo). The only logic: `rd_en = not empty and not busy`, which
drives both `uart_fifo.rd_en` and `uart_tx.data_in_valid` (uart_tx raises
busy on the edge it accepts a byte, so one byte leaves per send).
FIFO on the **transmit** side: uart_tx is the slow consumer (86.8 µs/byte).
Echo test in top = two wires (`rx_data -> tx_data`, `rx_valid -> tx_valid`);
the command decoder replaces them later.

## 5. Command protocol

**Decided 2026-11-16: option A, binary packets from a Python script.**

```
PC → FPGA:   [ register ] [ value high byte ] [ value low byte ]     3 bytes
FPGA → PC:   [ 0x06 ] ACK (done)     or     [ 0x15 ] NAK (unknown register)
```

Answered (user):
- **Q1 lost byte → timeout.** If a command has started and no byte arrives
  for ~1 ms (≈ 11 byte times; bytes inside a command are back-to-back),
  discard what was received and wait for a new register byte. The Python
  script waits for the ACK (~100 ms timeout) before sending the next
  command, so a broken command is always followed by a long enough gap.
- **Q2 switches vs PC → a register bit.** Register 0x00 bit 7 = PC control:
  '0' (reset) the board switches decide, '1' bits 0..2 decide. The pedal
  works as before until the PC takes over; easy to flip while testing.

Decoder states (proposed):

| State | On rx_valid | Timeout or rx_frame_error |
|-------|-------------|---------------------------|
| st_reg | byte = register number → st_hi | (nothing to discard) |
| st_hi | byte = value high → st_lo | → st_reg |
| st_lo | byte = value low; known register: write it, reply 0x06; else 0x15; → st_reg | → st_reg |

Timeout counter: cleared on every received byte, counts otherwise. Reply =
one clock of tx_valid with tx_data into the uart block (queued by its FIFO).

**Replies** (user asked for an error the PC can retry on, 2026-11-16):

| Reply | Meaning | Python |
|-------|---------|--------|
| 0x06 ACK | written | next command |
| 0x15 NAK | unknown register | don't resend (script bug), report |
| 0x18 CAN | command broken (timeout or frame error) | resend |

**st_discard** — after a timeout or `rx_frame_error`, ignore bytes (each one
restarts the timer) until the line has been quiet for the timeout, then send
**one** CAN and go to st_reg. Without it, the rest of a broken command would
start a new command and cause a second CAN, which the PC would take as the
reply to its resend. Rule: exactly one reply per command attempt.

**Python side:** send 3 bytes, wait ≤ 100 ms: ACK done; NAK stop + report;
CAN or nothing → resend (≤ 3 tries). "Nothing" covers a lost command and a
lost reply; a resend after a lost ACK writes the same value again, harmless
(writes are idempotent, so retries are safe).

Timeout: **1 ms = 98 305 clocks → 17-bit counter** (2^17 = 131 072); generic
`g_timeout_clks` (98305) so the testbench can shrink it. Frame error →
abandon the command at once (via st_discard).

### Proposed split: `cmd_decoder` + `ctrl_regs`

```
uart rx_* ──→ [ cmd_decoder ] ──→ reg_addr, reg_data, reg_write ──→ [ ctrl_regs ] ──→ effect settings
uart tx_* ←──          └──── reg_addr_valid (register exists?) ←─────────┘
```

- `cmd_decoder`: bytes, timeout, ACK / NAK / CAN; turns 3 bytes into one
  write (8-bit address, 16-bit value, one-clock `reg_write`).
- `ctrl_regs`: what each register means; stores values (reset = current
  defaults), converts to the effects' Q-formats, says which addresses exist.

**Agreed 2026-11-16.** reg_addr is driven all the time from s_reg_addr
(stored in st_reg); ctrl_regs answers reg_addr_valid combinationally, so
it is ready long before st_lo, where the decoder checks it (write + ACK, or
NAK). Reply codes as constants c_ack / c_nak / c_can. Signals: s_state
(st_reg, st_hi, st_lo, st_discard), s_reg_addr, s_data_hi, s_timer (0 ..
g_timeout_clks - 1), s_tx_data / s_tx_valid, s_reg_data, s_reg_write.

`cmd_decoder` ports: clk, reset; rx_data (7..0), rx_valid, rx_frame_error
in (from uart); tx_data (7..0), tx_valid out (reply to uart); reg_addr
(7..0), reg_data (15..0), reg_write out; reg_addr_valid in. Generic
g_timeout_clks.

Proposed registers (to refine): 0x00 effect on/off bits, 0x01 output gain,
0x02 drive gain, 0x03 clip threshold, 0x04 tremolo depth, 0x05 tremolo rate.
Several need a fixed-point mapping into 16 bits (Q3.15 is 18 bits, the
threshold 23, the tremolo phase step 32). The soft clip drive stays a
generic (its tanh table is built at elaboration).

### Earlier option comparison

| Option | PC side | FPGA side |
|--------|---------|-----------|
| **A. Binary packets**, e.g. 3 bytes: register number, value high byte, value low byte | a small Python script (`pyserial`) | simple: count 3 bytes, write a register |
| **B. Text commands** typed in a terminal, e.g. `trem 5.0` | any terminal (PuTTY, Tera Term) | harder: parse ASCII characters, digits, decimals |

A is easier in VHDL and the Python side is good practice; B is nicer to
use but the parser is a big step. Decide when the UART itself works.

Also to decide: which generics become runtime registers. Some are easy
(switch overrides, gains, tremolo depth). Some are built into tables at
elaboration (`g_soft_drive`'s tanh table) and would need a different design
to change at run time.

## 6. Order of work

1. `uart_tx` + testbench (Claude, with a model of the PC's receiver).
   Board test: the FPGA prints a fixed message, seen in a terminal on the PC.
2. `uart_rx` + testbench (Claude, with a model of the PC's transmitter).
3. Echo on the board: every byte typed comes straight back.
4. Protocol decision, command decoder, registers, Python (or terminal) side.
5. Effects controlled from the PC.

## 7. Open questions (user)

- Q1 Which of `uart_txd_in` / `uart_rxd_out` is the FPGA's input, and which
  its output? (Hint: the names describe the FTDI chip's pins.)
- Q2 At 115 200 baud and 98.305 MHz: clocks per bit (to the nearest whole
  number)? Percentage error from rounding? Counter width?
- Q3 Why does `uart_txd_in` need a 2-flip-flop synchroniser (like the
  switches), but the I2S `ad_sdout` input did not?
- Q4 How long is one byte on the wire at 115 200 baud, and how many bytes a
  second at most?
