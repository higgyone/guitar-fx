-- tone_stage: tone control, a biquad low-pass filter (effect #4). Cuts the
-- treble above g_cutoff_hz, 12 dB per octave: darker, less fizz (most
-- useful after the distortion).
--
--   y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
--
-- An IIR filter: the last two outputs feed back, so one biquad does the
-- work of a long average. Coefficients from the Audio EQ Cookbook
-- (low-pass), divided by a0, worked out when the design is built and
-- rounded to Q2.16 (18 bits, -2 .. just under +2: a1 approaches -2 at low
-- cutoffs). model/biquad_model.py is the reference: the same coefficients,
-- the response plot (exact vs Q2.16) and a bit-exact sample model.
--
--   sample_in     : Q1.23
--   g_cutoff_hz   : real, the -3 dB point (3000 = gentle treble cut)
--   g_q           : real, the corner: 0.707 smooth (Butterworth), higher
--                   gives a peak at the cutoff (Q 2 = +6 dB)
--   g_sample_rate : real, the real sample rate (the coefficients depend
--                   on it)
--   sample_out    : Q1.23, saturated
--
-- Direct Form I: the state is the last two inputs and the last two
-- outputs, as rounded, saturated Q1.23 samples. Pipeline (5 DSP slices for
-- the products):
--   stage 1: the five products, Q3.39 (42 bits); x2 <- x1, x1 <- x
--   stage 2: their sum, Q6.39 (45 bits, so it can never wrap)
--   stage 3: + 2**15 (round to nearest), bits 39..16, or full scale if it
--            doesn't fit (a full-scale step overshoots and clips)
--   then   : y2 <- y1, y1 <- y (the clock after stage 3, once y is in
--            s_y_3)
-- Rounding inside the loop can leave a steady input 1 LSB off (deadband);
-- the model does the same.
--
-- Latency: 3 clocks. sample_out_valid pulses for one clock, three clocks
-- after sample_in_valid; samples must be at least 4 clocks apart (the
-- y state is ready 4 clocks after the input; ~2048 in the real design).
-- Reset clears the state (the filter restarts from silence) and the valid
-- chain, so a sample in flight never comes out.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity tone_stage is
    generic (
        g_cutoff_hz   : real := 3000.0; -- -3 dB point, Hz
        g_q           : real := 0.707;  -- resonance: 0.707 = smooth (Butterworth)
        g_sample_rate : real := 48000.0 -- samples per second (sample_in_valid pulses)
    );
    port (
        clk              : in    std_logic;
        reset            : in    std_logic;
        sample_in        : in    signed(23 downto 0); -- Q1.23
        sample_in_valid  : in    std_logic;
        sample_out       : out   signed(23 downto 0); -- Q1.23
        sample_out_valid : out   std_logic
    );
end entity tone_stage;

architecture rtl of tone_stage is

    -- Coefficients, worked out when the design is built (Audio EQ Cookbook
    -- low-pass, divided by a0), then rounded to Q2.16 (18 bits, 1.0 = 2**16).

    -- The angle and the bandwidth term (real: they exist at build time only).
    constant c_w0    : real := 2.0 * MATH_PI * g_cutoff_hz / g_sample_rate; -- cutoff as an angle per sample, radians
    constant c_alpha : real := sin(c_w0) / (2.0 * g_q);                     -- sets the width of the corner (Q)

    -- The six raw Cookbook values (before dividing by a0).
    constant c_a0_real : real := 1.0 + c_alpha;
    constant c_b0_real : real := (1.0 - cos(c_w0)) / 2.0;
    constant c_b1_real : real := 1.0 - cos(c_w0);
    constant c_b2_real : real := (1.0 - cos(c_w0)) / 2.0;
    constant c_a1_real : real := -2.0 * cos(c_w0);
    constant c_a2_real : real := 1.0 - c_alpha;

    -- Divided by a0, scaled to Q2.16, rounded: the bits the hardware uses
    -- (3 kHz, Q 0.707: 1963, 3926, 1963, -95302, 37618, as in
    -- model/biquad_model.py). to_signed stops the build if one doesn't fit.
    constant c_b0 : signed(17 downto 0) := to_signed(integer(round(c_b0_real / c_a0_real * 2.0 ** 16)), 18);
    constant c_b1 : signed(17 downto 0) := to_signed(integer(round(c_b1_real / c_a0_real * 2.0 ** 16)), 18);
    constant c_b2 : signed(17 downto 0) := to_signed(integer(round(c_b2_real / c_a0_real * 2.0 ** 16)), 18);
    constant c_a1 : signed(17 downto 0) := to_signed(integer(round(c_a1_real / c_a0_real * 2.0 ** 16)), 18);
    constant c_a2 : signed(17 downto 0) := to_signed(integer(round(c_a2_real / c_a0_real * 2.0 ** 16)), 18);

    -- The state: the last two inputs and outputs, Q1.23. Start at 0, so
    -- the filter starts from silence.
    signal s_x1 : signed(23 downto 0) := (others => '0'); -- x[n-1]
    signal s_x2 : signed(23 downto 0) := (others => '0'); -- x[n-2]
    signal s_y1 : signed(23 downto 0) := (others => '0'); -- y[n-1]
    signal s_y2 : signed(23 downto 0) := (others => '0'); -- y[n-2]

    -- Stage 1: the five products, Q1.23 x Q2.16 = Q3.39 (24 + 18 = 42 bits).
    signal s_p0      : signed(41 downto 0) := (others => '0'); -- b0 * x[n]
    signal s_p1      : signed(41 downto 0) := (others => '0'); -- b1 * x[n-1]
    signal s_p2      : signed(41 downto 0) := (others => '0'); -- b2 * x[n-2]
    signal s_p3      : signed(41 downto 0) := (others => '0'); -- a1 * y[n-1]
    signal s_p4      : signed(41 downto 0) := (others => '0'); -- a2 * y[n-2]
    signal s_valid_1 : std_logic           := '0';             -- '1': the products are a real sample's

    -- Stage 2: the sum, Q6.39 (45 bits: five Q3.39 terms need 3 more
    -- integer bits so the sum can never wrap).
    signal s_sum_2   : signed(44 downto 0) := (others => '0'); -- p0 + p1 + p2 - p3 - p4
    signal s_valid_2 : std_logic           := '0';             -- '1': the sum is a real sample's

    -- Between stages 2 and 3 (combinational, as in gain_stage):
    signal s_rounded  : signed(44 downto 0); -- sum + half an output LSB (2**15)
    signal s_overflow : std_logic;           -- '1': the rounded sum doesn't fit Q1.23

    -- Stage 3: the output sample, Q1.23 (also the next y[n-1]).
    signal s_y_3     : signed(23 downto 0) := (others => '0'); -- y[n]: rounded, clipped
    signal s_valid_3 : std_logic           := '0';             -- one-clock pulse: y[n] is new

begin

    -- The pipeline. A sample in starts it; each stage loads one clock after
    -- the one before (valid moves along with it). There are ~2048 clocks per
    -- sample, so y[n-1] is back in the state long before the next sample.
    tone_proc : process (clk) is
    begin

        if rising_edge(clk) then
            -- Valid moves along every clock (one-clock pulses).
            s_valid_1 <= sample_in_valid;
            s_valid_2 <= s_valid_1;
            s_valid_3 <= s_valid_2;

            if (reset = '1') then
                s_valid_1 <= '0';
                s_valid_2 <= '0';
                s_valid_3 <= '0';

                s_x1 <= (others => '0');
                s_x2 <= (others => '0');
                s_y1 <= (others => '0');
                s_y2 <= (others => '0');
            else
                -- Stage 1: the five products, from the state BEFORE this
                -- edge; then move the inputs along (x2 <- x1, x1 <- x).
                if (sample_in_valid = '1') then
                    s_p0 <= c_b0 * sample_in;
                    s_p1 <= c_b1 * s_x1;
                    s_p2 <= c_b2 * s_x2;
                    s_p3 <= c_a1 * s_y1;
                    s_p4 <= c_a2 * s_y2;

                    s_x2 <= s_x1;
                    s_x1 <= sample_in;
                end if;

                -- Stage 2: the sum at 45 bits (resize the first term, or
                -- numeric_std adds at 42 bits and can wrap).
                if (s_valid_1 = '1') then
                    s_sum_2 <= resize(s_p0, 45) + s_p1 + s_p2 - s_p3 - s_p4;
                end if;

                -- Stage 3: Q6.39 -> Q1.23: bits 39..16 of the rounded sum,
                -- or full scale if it overflowed (bit 44 = the true sign).
                if (s_valid_2 = '1') then
                    if (s_overflow = '0') then
                        s_y_3 <= s_rounded(39 downto 16);
                    elsif (s_rounded(44) = '0') then
                        s_y_3 <= to_signed(2 ** 23 - 1, 24);                 -- +full scale: 2**23 - 1
                    else
                        s_y_3 <= to_signed(-(2 ** 23), 24);                  -- -full scale: -2**23
                    end if;
                end if;

                -- Move the outputs along (y2 <- y1, y1 <- y). One clock
                -- after stage 3: on stage 3's own edge s_y_3 still holds the
                -- previous y. Inside the reset's else, so reset always wins.
                if (s_valid_3 = '1') then
                    s_y2 <= s_y1;
                    s_y1 <= s_y_3;
                end if;
            end if;
        end if;

    end process tone_proc;

    -- Round to nearest: add half of what the slice drops (16 bits).
    s_rounded <= s_sum_2 + to_signed(2 ** 15, 45);

    -- Fits Q1.23 only if bits 44..39 are all 0 or all 1 (the bits the slice
    -- drops at the top must all equal its sign bit, 39).
    s_overflow <= '0' when s_rounded(44 downto 39) = "000000"
                           or s_rounded(44 downto 39) = "111111" else
                  '1';

    sample_out       <= s_y_3;
    sample_out_valid <= s_valid_3;

end architecture rtl;
