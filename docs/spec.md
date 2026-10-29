# guitar-fx specification

Status: **draft — open questions.** Answer inline (replace `?`) or in chat.
Decisions get moved into the "Decided" part of each section.

---

## 1. Goals

What the project is for, and what "done" looks like for v1.

**Decided:**
- Learning first: understand and build each effect. Play live later.
- Practise with each effect as it is built (simulation output audio first,
  then hardware).

- Q1.1 Is the main goal learning (a few effects done well, understood fully)
  or a usable pedal you play through live? ?
- Q1.2 What does v1 look like? e.g. "guitar in → one effect → amp out, with a
  bypass switch". ?
- Q1.3 Which effects do you want, in rough order? (suggested order of
  difficulty is in §6) ?
- Q1.4 Is anything out of scope for v1 (presets, MIDI, display, stereo)? ?

## 2. Audio hardware (the board has no audio codec)

The Arty A7 has no audio input. An ADC/DAC must be added, usually via a Pmod.
Common choice: **Digilent Pmod I2S2** (Cirrus CS5343 ADC + CS4344 DAC, 24-bit,
I2S, 3.5 mm line in/out, plugs into one Pmod port).

**Decided:**
- Converter: Digilent Pmod I2S2 (to be purchased).
- Until it arrives, and until the preamp exists: PC-generated test signals
  (simulation with WAV-derived files first; PC line out → I2S2 later).
- Guitar input: a preamp/buffer will be designed and built — see
  [preamp.md](preamp.md).

- Q2.1 ~~Do you already own an audio Pmod?~~ Buying a Pmod I2S2.
- Q2.2 A guitar pickup is high impedance (~250 kΩ–1 MΩ source) and low level
  (~100 mV–1 V peak). A line input is ~10 kΩ and expects ~1 V. Plugging the
  guitar straight in loads the pickups (dull tone) and gives poor
  signal-to-noise. How will you get guitar → line level?
  (a) build a buffer/preamp (JFET or op-amp, a nice side project)
  (b) use an existing pedal / DI box / amp FX loop
  (c) start with test audio from a PC/phone and solve this later ?
- Q2.3 Output: into a guitar amp's input, an FX loop return, headphones, or
  a PC for recording? ?
- Q2.4 Mono only? (guitar is mono; stereo out matters for some effects
  like ping-pong delay or chorus) ?

## 3. Digital audio format

**Decided:**
- Sample rate 48 kHz.
- Samples 24-bit signed two's complement, Q1.23 (range −1 to +1 − 2⁻²³).
- Fixed-point background: lesson notes in
  [learning/01_fixed_point.md](learning/01_fixed_point.md).

- Q3.1 ~~Sample rate~~ 48 kHz.
- Q3.2 Sample width inside the FPGA: the converter gives 24 bits. Will you
  process at 24 bits, or use 16 / 18 bits to start? (Hint: the DSP48 slice
  multiplier is 25 × 18 bits — look up why that matters.) ?
- Q3.3 Number format: signed two's complement fixed point. Which Q-format?
  e.g. Q1.23 (range −1 to +1). Do you know what Q-format means yet? ?
- Q3.4 What happens on overflow: wrap or saturate? Which sounds worse, and
  why? ?

## 4. Clocks and architecture

Board oscillator is 100 MHz. I2S needs a master clock (MCLK, usually 256 ×
fs, e.g. 12.288 MHz for 48 kHz), a bit clock and a left/right clock.

**Pmod I2S2 facts (reference manual):**
- 48 kHz: MCLK = 12.288 MHz (256 × Fs), SCLK = 64 × LRCK, LRCK = Fs.
- JP1 = ADC master/slave. Slave (SLV): FPGA generates MCLK/SCLK/LRCK for both
  converters (simplest: one set of clocks for in and out).
- I2S: MSB first, one SCLK after the LRCK edge; data changes on SCLK falling
  edge, valid on rising edge.
- Manual's ADC ratio table says "784x" — typo for 768x.
- Supply 3.0–5.25 V, 3.3 V recommended (VA = 3.3 V).

- Q4.1 Generate MCLK with the MMCM (clocking wizard / primitive), or divide
  down? What is wrong with dividing 100 MHz to get 12.288 MHz? ?
- Q4.2 One clock domain for the DSP (e.g. 100 MHz with a 1-cycle "sample
  valid" strobe at 48 kHz), or run the DSP from the audio clock? Think about
  how many clock cycles you get per sample at 100 MHz. ?
- Q4.3 How do samples cross between the I2S clock domain and the DSP clock
  domain? (Clock domain crossing is a big topic, worth learning properly.) ?
**Decided — common effect interface (every effect block uses it):**

| Port | Dir | Type | Meaning |
|------|-----|------|---------|
| `clk` | in | `std_logic` | 100 MHz system clock |
| `reset` | in | `std_logic` | synchronous, active high |
| `sample_in` | in | `signed(23 downto 0)` | Q1.23 input sample |
| `sample_in_valid` | in | `std_logic` | 1-clock pulse: `sample_in` is new |
| *(parameters)* | in | per effect | e.g. `gain` Q3.15 |
| `sample_out` | out | `signed(23 downto 0)` | Q1.23 output sample |
| `sample_out_valid` | out | `std_logic` | 1-clock pulse: `sample_out` is new |

Chaining: one block's `sample_out` / `sample_out_valid` drive the next
block's `sample_in` / `sample_in_valid`.

- Q4.4 ~~Common interface for every effect block~~ (decided above), so they chain and can be
  swapped? e.g. `clk, rst, in_valid, in_sample, out_valid, out_sample`, plus
  parameters. Look up AXI-Stream: do you want its handshake, or a simpler
  strobe? ?
- Q4.5 Effects chain: fixed order, or selectable? ?
- Q4.6 Reset: synchronous or asynchronous, active high or low? (ULA
  conventions: `_n` suffix for active low.) ?

## 5. Controls and user interface

Board has 4 switches, 4 buttons, 4 LEDs + 4 RGB LEDs, and the USB-UART.

- Q5.1 Bypass / effect select using the board switches to start? ?
- Q5.2 Knobs for parameters (gain, delay time, mix)? Options: the Artix-7
  XADC with potentiometers, a Pmod ADC, a rotary encoder, or set them over
  UART from the PC. ?
- Q5.3 Footswitch? (needs debouncing — a good first VHDL exercise) ?
- Q5.4 Any level meter / clip indicator on the LEDs? ?

## 6. Effects (suggested learning order)

Each one teaches a new idea. Do they interest you? Re-order or drop any.

| # | Effect | New idea it teaches |
|---|--------|---------------------|
| 0 | Passthrough + bypass | I2S, clocks, sample strobe, the whole chain end to end |
| 1 | Volume / gain | fixed-point multiply, DSP48, saturation |
| 2 | Hard / soft clip distortion | non-linear functions, lookup tables (ROM) |
| 3 | Tremolo | LFO (counter / phase accumulator, sine table) |
| 4 | Tone (low-pass / high-pass) | IIR filters, biquads, coefficient quantisation |
| 5 | Delay / echo | block RAM, circular buffers, feedback |
| 6 | Chorus / flanger | modulated delay, fractional delay, interpolation |
| 7 | Reverb | many delays + all-pass filters, resource budget |
| 8 | Noise gate / compressor | envelope detection, dynamics |
| util | Power-up mute / soft start | counter + comparator + gain ramp; hides preamp settle thump (after #1) |
| opt | Hum notch (50 Hz + harmonics) | IIR biquad notch, cascading filters (after #4) |

- Q6.1 Delay memory: at 48 kHz × 24 bits, how many seconds of delay fit in the
  XC7A35T's block RAM (50 × 36 Kb)? Work it out. Is that enough, or do you
  need the board's 256 MB DDR3 (much harder)? ?

## 7. Verification

- Q7.1 Prototype each effect in Python (numpy) first, then build the VHDL
  against it? The Python model makes test vectors and the testbench compares
  bit for bit. ?
- Q7.2 Testbenches read / write audio files (e.g. text sample files made from
  WAV by a Python script) so you can *listen* to simulation output? ?
- Q7.3 On hardware, use the ILA (Vivado's on-chip logic analyser) to watch
  samples? ?
- Q7.4 Python on this PC: which version, and is numpy/scipy/matplotlib
  installed? (see the miniforge venv notes) ?

## 8. Learning background

Helps me pitch explanations at the right level.

**Known:** understands fixed point, sampling and Nyquist (rusty). Needs help
designing and understanding each effect: theory refresher + design
walk-through before writing VHDL.

- Q8.1 After ULA, how comfortable are you with: processes and clocked logic,
  state machines, generics, records, numeric_std signed/unsigned? ?
- Q8.2 Any DSP background (sampling, Nyquist, filters, z-transform), or
  start from the beginning? ?
- Q8.3 Preferred learning style: theory first then build, or build first and
  learn the theory when stuck? ?
- Q8.4 Book or online references you already have or want? ?

## 9. Project conventions (proposed: same as ULA)

- snake_case identifiers; `_n` = active low; `s_` prefix for internal signals.
- Port order: clk, reset, enable, other inputs, outputs.
- Direct entity instantiation (`entity work.name`).
- Architecture name `rtl` for synthesizable code, `sim` / `behavioral` for
  models.
- Q9.1 Agree, or change anything? ?
