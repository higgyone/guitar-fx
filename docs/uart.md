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

## 5. Command protocol — to decide (later)

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
