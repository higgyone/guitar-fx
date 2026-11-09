-- soft_clip_stage: soft-clip distortion. Each sample goes through a tanh
-- curve held in a lookup table (ROM): straight near zero, bending smoothly
-- towards full scale, with no hard corner (warmer than hard_clip_stage).
--
--   out = tanh(k * in) / tanh(k)        k = g_drive
--
-- Dividing by tanh(k) makes a full-scale input give (almost) full-scale
-- output, so the table uses the whole 24-bit range. Small inputs come out
-- about k / tanh(k) louder (the curve's slope at zero); set the level with
-- the output gain stage.
--
--   sample_in  : Q1.23
--   g_drive    : real, k. ~1 barely bends, 3 = overdrive, 10 = near hard clip
--   sample_out : Q1.23
--
-- The table: 1025 entries of the positive half only (tanh is odd:
-- tanh(-x) = -tanh(x)). Entry i is the output for input i / 1024, so
-- entry 1024 is input 1.0, output 2**23 - 1 (needed as the right-hand end
-- of the last step). It is filled when the design is built (math_real runs
-- at elaboration only), and the registered reads let Vivado put it in one
-- dual-port block RAM.
--
-- Between entries the output is linearly interpolated, so the curve is
-- smooth instead of a 1024-step staircase, and inputs smaller than one step
-- are not rounded down to 0:
--
--   |x| = bits 22..0 of the input, inverted if negative
--   a   = bits 22..13 of |x|   which entry       (0 .. 1023)
--   f   = bits 12..0  of |x|   how far to a + 1  (0 .. 8191, out of 8192)
--   out = T(a) + ((T(a+1) - T(a)) * f) / 8192    (/ 8192 = drop 13 bits)
--
-- Pipeline (stages 1 and 2 step every clock; stage 3 loads only for a real
-- sample, so sample_out holds between samples):
--   before : |x|, a, f from sample_in (not x = -x - 1 never overflows, so
--            -1.0 needs no special case)
--   stage 1: read T(a) and T(a+1) (block RAM); register f, sign, valid
--   stage 2: product = gap * f (DSP); carry T(a), sign, valid along
--   stage 3: sum = T(a) + product bits 36..13, with its sign
--   after  : negative input: invert the sum back (not)
--
-- Latency: 3 clocks. sample_out_valid pulses for one clock, three clocks
-- after sample_in_valid. Reset clears the valid chain, so a sample in
-- flight at reset never comes out.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity soft_clip_stage is
    generic (
        g_drive : real := 3.0 -- k: how hard the curve is driven
    );
    port (
        clk              : in    std_logic;
        reset            : in    std_logic;
        sample_in        : in    signed(23 downto 0);
        sample_in_valid  : in    std_logic;
        sample_out       : out   signed(23 downto 0);
        sample_out_valid : out   std_logic
    );
end entity soft_clip_stage;

architecture rtl of soft_clip_stage is

    -- The lookup table: 1025 Q1.23 values, the positive half of the curve
    -- (entry 1024 is the end point of the last step).

    type t_tanh is array (0 to 1024) of signed(23 downto 0);

    -- Builds the table at elaboration: entry i = tanh(k * i / 1024) / tanh(k),
    -- scaled to Q1.23 and rounded.

    function generate_tanh_soft_clip_values (
        k : real -- the drive
    ) return t_tanh is

        variable table : t_tanh; -- the table being built

    begin

        for i in 0 to 1024 loop

            table(i) := to_signed(integer(round(tanh(k * real(i) / 1024.0) / tanh(k) * real(2 ** 23 - 1))), 24); -- entry i: tanh(k * i / 1024) / tanh(k), as Q1.23

        end loop;

        return table;

    end function generate_tanh_soft_clip_values;

    constant c_tanh : t_tanh := generate_tanh_soft_clip_values(g_drive); -- the ROM

    -- Before the registers (from sample_in, this sample):
    signal s_pos      : signed(22 downto 0);   -- |sample_in|, bits 22..0 (inverted if negative)
    signal s_address  : unsigned(9 downto 0);  -- a: table entry, bits 22..13 of s_pos
    signal s_fraction : unsigned(12 downto 0); -- f: how far from entry a to a + 1, bits 12..0 of s_pos

    -- Stage 1 (every clock):
    signal s_t_a_1      : signed(23 downto 0);   -- T(a), read from the ROM
    signal s_t_a1_1     : signed(23 downto 0);   -- T(a+1), the next entry (second ROM port)
    signal s_fraction_1 : unsigned(12 downto 0); -- f
    signal s_neg_1      : std_logic := '0';      -- '1': the sample was negative
    signal s_valid_1    : std_logic := '0';      -- '1': a real sample is in stage 1

    -- Stage 2 (every clock):
    signal s_t_a_2     : signed(23 downto 0); -- T(a), carried along to the add
    signal s_neg_2     : std_logic := '0';    -- sign
    signal s_valid_2   : std_logic := '0';    -- '1': a real sample is in stage 2
    signal s_product_2 : signed(37 downto 0); -- (T(a+1) - T(a)) * f, 24 + 14 bits

    -- Stage 3 (only when s_valid_2 = '1', so it holds between samples):
    signal s_sum_3 : signed(23 downto 0); -- T(a) + product / 8192, for |sample|
    signal s_neg_3 : std_logic := '0';    -- its sign, loaded with it

begin

    -- The three pipeline stages. Every line reads the values from before
    -- the edge, so each stage works on the sample the stage before it held
    -- one clock earlier; the _1 / _2 / _3 copies of sign and valid keep
    -- them lined up with their sample's data.
    soft_clip_proc : process (clk) is
    begin

        if rising_edge(clk) then
            -- Stage 1: read both table entries (registered: block RAM). The
            -- + 1 is on the integer, so a = 1023 reads entry 1024.
            s_t_a_1      <= c_tanh(to_integer(s_address));
            s_t_a1_1     <= c_tanh(to_integer(s_address) + 1);
            s_fraction_1 <= s_fraction;
            s_neg_1      <= sample_in(23);
            s_valid_1    <= sample_in_valid;

            -- Stage 2: gap * f (registered: DSP). '0' & f keeps f positive
            -- as a signed number. The gap is never negative (the curve only
            -- rises).
            s_product_2 <= (s_t_a1_1 - s_t_a_1) * signed('0' & s_fraction_1);
            s_t_a_2     <= s_t_a_1;
            s_neg_2     <= s_neg_1;
            s_valid_2   <= s_valid_1;

            sample_out_valid <= s_valid_2;                                    -- one clock pulse, with stage 3's load

            if (reset = '1') then                                             -- last assignment wins: overrides the copies above
                s_sum_3          <= (others => '0');
                s_neg_3          <= '0';
                s_valid_1        <= '0';
                s_valid_2        <= '0';
                sample_out_valid <= '0';
            elsif (s_valid_2 = '1') then
                -- Stage 3: / 8192 = keep product bits 36..13 (24 bits).
                -- Bits 37..28 are always 0 (product < 24700 * 8192 < 2**28),
                -- and the sum can't overflow: it is at most T(a+1).
                s_sum_3 <= s_t_a_2 + s_product_2(36 downto 13);
                s_neg_3 <= s_neg_2;
            end if;                                                           -- no else: s_sum_3, s_neg_3 hold between samples
        end if;

    end process soft_clip_proc;

    -- Before the registers: uses sample_in(23), the sign of the sample
    -- arriving now. |x| comes from the inverted input for negatives, so f
    -- is measured from the mirrored side too.
    s_pos      <= not(sample_in(22 downto 0)) when sample_in(23) = '1' else
                  sample_in(22 downto 0);
    s_address  <= unsigned(s_pos(22 downto 13));
    s_fraction <= unsigned(s_pos(12 downto 0));

    -- After the registers: the sign back, with s_neg_3 (same sample as
    -- s_sum_3).
    sample_out <= not s_sum_3 when s_neg_3 = '1' else
                  s_sum_3;

end architecture rtl;
