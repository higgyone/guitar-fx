-- gain_stage: multiplies each audio sample by a gain.
--
--   sample_in  : Q1.23 (range -1.0 to +1.0 - 2^-23)
--   gain       : Q3.15 (range -4.0 to +4.0 - 2^-15)
--   sample_out : Q1.23, saturated to max/min on overflow (never wraps)
--
-- Latency: 1 clock. sample_out_valid pulses for one clock, one clock after
-- sample_in_valid. sample_out holds its value between samples.
-- Rounding: round to nearest, ties up (adds half an output LSB, 2^14, to
-- the product before slicing). Saturation is checked after rounding.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity gain_stage is
    port (
        clk              : in    std_logic;
        reset            : in    std_logic;
        sample_in        : in    signed(23 downto 0);
        sample_in_valid  : in    std_logic;
        gain             : in    signed(17 downto 0);
        sample_out       : out   signed(23 downto 0);
        sample_out_valid : out   std_logic
    );
end entity gain_stage;

architecture rtl of gain_stage is

    signal s_sample_gain : signed(41 downto 0) := (others => '0'); -- registered product, Q4.38
    signal s_gain_slice  : signed(23 downto 0) := (others => '0'); -- product as Q1.23, saturated

    signal s_rounded  : signed(41 downto 0) := (others => '0'); -- product + 2^14 (rounded), Q4.38
    signal s_overflow : std_logic           := '0';             -- '1': rounded product doesn't fit Q1.23

    constant c_sample_max : signed(23 downto 0) := (23 => '0', others => '1'); -- Q1.23 max, 0x7FFFFF = +0.99999988
    constant c_sample_min : signed(23 downto 0) := (23 => '1', others => '0'); -- Q1.23 min, 0x800000 = -1.0

    -- bit 14 is the round bit as bit 15 is the LSB of the Q1.23 output.
    -- Add 0.5 LSB to round to nearest value.
    constant c_round : signed (41 downto 0) := (14 => '1', others => '0');

begin

    -- Registers the product when a new sample arrives and raises
    -- sample_out_valid for that one clock.
    gain_proc : process (clk) is
    begin

        if rising_edge(clk) then
            sample_out_valid <= '0';                  -- default: low; set high below for one clock
            if (reset = '1') then
                s_sample_gain <= (others => '0');
            elsif (sample_in_valid = '1') then
                s_sample_gain    <= sample_in * gain; -- sample x gain, Q4.38 (42 bits), registered
                sample_out_valid <= '1';
            end if;                                   -- no else: s_sample_gain holds its value
        end if;

    end process gain_proc;

    -- Round to nearest: add half an output LSB (see c_round), then the slice
    -- below truncates. Cannot overflow 42 bits (largest product is 2^40).
    s_rounded <= s_sample_gain + c_round;

    -- Overflow check. Q1.23 keeps bit 38 as its sign and drops bits 41..39.
    -- The value fits only if bits 41..38 are all 0 (small positive) or all
    -- 1 (small negative); any mix means it is outside -1.0 .. +1.0.
    s_overflow <= '0' when s_rounded(41 downto 38) = "1111"
                           or s_rounded(41 downto 38) = "0000" else
                  '1';

    -- Q4.38 -> Q1.23. No overflow: bits 38..15 of the rounded product (drops
    -- the 15 LSBs; with c_round added this rounds to nearest).
    -- Overflow: clamp to max or min. Bit 41 is the true sign:
    -- the full 42-bit product never overflows, so its MSB is always right
    -- (bit 38 or 39 can be wrong, e.g. -1.0 x 3.5).
    s_gain_slice <= s_rounded(38 downto 15) when s_overflow = '0' else
                    c_sample_max when s_rounded(41) = '0' else
                    c_sample_min;

    sample_out <= s_gain_slice;

end architecture rtl;


