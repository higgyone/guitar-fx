-- tremolo_stage: tremolo. The volume rises and falls smoothly, g_rate_hz
-- times a second, driven by a sine-wave LFO (low-frequency oscillator).
--
--   gain = 1 - depth * (1 + sin) / 2       out = in * gain
--
-- (1 + sin) / 2 moves the sine from -1..+1 up to 0..1, so the gain swings
-- between 1.0 (sine trough) and 1 - depth (sine peak). It never goes above
-- 1.0, so the tremolo can't make anything clip.
--
--   sample_in     : Q1.23
--   g_rate_hz     : real, wobble speed in Hz (a few Hz is typical)
--   g_depth       : real, 0.0 no effect .. 0.5 gentle (-6 dB dips) .. 1.0
--                   dips to silence
--   g_sample_rate : real, the real sample rate; the block counts samples, so
--                   this must match or the rate is off by the same factor
--   sample_out    : Q1.23
--
-- The LFO is a phase accumulator: a 32-bit counter that adds c_step every
-- sample. Its whole range is one turn of the sine, so it wraps back to the
-- start by itself (the carry out of the top bit is dropped), and any
-- remainder carries into the next turn, so the rate is exact over time:
--
--   c_step = g_rate_hz * 2**32 / g_sample_rate     (5 Hz at 48 kHz: 447 392)
--
-- Its top 10 bits (31..22) pick one of 1024 entries of a sine table (one
-- full cycle, Q2.15, filled when the design is built). The gain path is a
-- 5-register pipeline that steps every clock:
--
--   s_sine -> s_u = (1 + sin) / 2 -> s_dip_product = u * depth (DSP)
--          -> s_dip (back to Q.15) -> s_gain = 1 - dip (Q3.15)
--
-- It doesn't need to line up with the samples: the sine moves one table
-- entry every ~9 samples at 5 Hz (thousands of clocks), so a gain a few
-- clocks late is the same gain. The multiply is a gain_stage, so latency,
-- rounding, saturation and sample_out_valid are gain_stage's (1 clock).
-- Reset restarts the LFO at phase 0 (sin 0, gain 1 - depth / 2).

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity tremolo_stage is
    generic (
        g_rate_hz     : real := 5.0;     -- wobble speed, Hz
        g_sample_rate : real := 48000.0; -- samples per second (sample_in_valid pulses)
        g_depth       : real := 0.5      -- how far the volume dips: 0.0 none .. 1.0 to silence
    );
    port (
        clk              : in    std_logic;
        reset            : in    std_logic;
        sample_in        : in    signed(23 downto 0);
        sample_in_valid  : in    std_logic;
        sample_out       : out   signed(23 downto 0);
        sample_out_valid : out   std_logic
    );
end entity tremolo_stage;

architecture rtl of tremolo_stage is

    -- The sine table: one full cycle, 1024 Q2.15 values (1.0 = 32768; the
    -- spare integer bit makes it the same 18-bit width as gain_stage's gain).

    type t_sin is array (0 to 1023) of signed(17 downto 0);

    -- Builds the table at elaboration: entry i = sin(2 * pi * i / 1024),
    -- scaled by 2**15 - 1 (so +1.0 fits) and rounded.

    function generate_sine_values
    return t_sin is

        variable table : t_sin; -- the table being built

    begin

        for i in 0 to 1023 loop

            table(i) := to_signed(integer(round(sin(MATH_2_PI * real(i) / 1024.0) * real(2 ** 15 - 1))), 18); -- entry i: sin(2 pi i / 1024), Q2.15

        end loop;

        return table;

    end function generate_sine_values;

    -- Worked out once, when the design is built (real maths only exists
    -- there; the hardware gets the bits):
    constant c_sin   : t_sin                 := generate_sine_values;                                                   -- the ROM
    constant c_step  : unsigned(31 downto 0) := to_unsigned(integer(round(g_rate_hz * 2.0 ** 32 / g_sample_rate)), 32); -- phase added per sample
    constant c_depth : signed(17 downto 0)   := to_signed(integer(round(g_depth * 32768.0)), 18);                       -- depth, Q.15

    signal s_phase       : unsigned(31 downto 0) := (others => '0'); -- LFO position, one turn = 2**32
    signal s_address     : unsigned(9 downto 0);                     -- table entry, phase bits 31..22
    signal s_sine        : signed(17 downto 0);                      -- sin, Q2.15 (-1 .. +1)
    signal s_u           : signed(17 downto 0);                      -- (1 + sin) / 2, Q.15 (0 .. 1)
    signal s_dip_product : signed(35 downto 0);                      -- u * depth, Q.30
    signal s_dip         : signed(17 downto 0);                      -- how far the gain dips, Q.15 (0 .. depth)
    signal s_gain        : signed(17 downto 0);                      -- 1 - dip, Q3.15 (1 - depth .. 1)

begin

    -- The multiply: sample x LFO gain, with gain_stage's rounding,
    -- saturation and valid pulse.
    tremolo_gain_stage : entity work.gain_stage
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_in,
            sample_in_valid  => sample_in_valid,
            gain             => s_gain,
            sample_out       => sample_out,
            sample_out_valid => sample_out_valid
        );

    -- The LFO. The gain pipeline steps every clock (each line reads the
    -- value the line above held one clock earlier); the phase steps once
    -- per sample.
    tremolo_proc : process (clk) is
    begin

        if rising_edge(clk) then
            s_sine        <= c_sin(to_integer(s_address));      -- registered read: block RAM
            s_u           <= shift_right(s_sine + 32768, 1);    -- (1 + sin) / 2: + 1.0, then / 2 as a shift
            s_dip_product <= s_u * c_depth;                     -- Q.15 x Q.15 = Q.30 (DSP)
            s_dip         <= s_dip_product(32 downto 15);       -- / 2**15: back to Q.15 (bits 35..31 always 0)
            s_gain        <= (to_signed(32768, 18) - s_dip);    -- 1.0 - dip

            if (reset = '1') then
                s_phase <= (others => '0');                     -- restart the LFO at phase 0
            elsif (sample_in_valid = '1') then
                s_phase <= s_phase + c_step;                    -- wraps at 2**32: one full turn
            end if;
        end if;

    end process tremolo_proc;

    -- Which 1/1024 of the turn: the top 10 bits of the phase.
    s_address <= s_phase(31 downto 22);

end architecture rtl;
