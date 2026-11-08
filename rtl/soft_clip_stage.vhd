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
-- The table: 1024 entries of the positive half only (tanh is odd:
-- tanh(-x) = -tanh(x)). Entry i is the output for input i / 1024. It is
-- filled when the design is built (math_real runs at elaboration only),
-- and the registered read lets Vivado put it in one block RAM.
--
-- Per sample:
--   1. negative input: invert it (not x = -x - 1, never overflows, so
--      -1.0 needs no special case), giving 0 .. 0x7FFFFF;
--   2. address = bits 22..13 of that (bits 12..0 are dropped, so the curve
--      is a 1024-step staircase);
--   3. read the table (registered), and register the input's sign;
--   4. negative input: invert the table value back.
--
-- Latency: 1 clock. sample_out_valid pulses for one clock, one clock after
-- sample_in_valid. sample_out holds its value between samples.

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

    -- The lookup table: 1024 Q1.23 values, the positive half of the curve.

    type t_tanh is array (0 to 1023) of signed(23 downto 0);

    -- Builds the table at elaboration: entry i = tanh(k * i / 1024) / tanh(k),
    -- scaled to Q1.23 and rounded.

    function generate_tanh_soft_clip_values (
        k : real -- the drive
    ) return t_tanh is

        variable table : t_tanh; -- the table being built

    begin

        for i in 0 to 1023 loop

            table(i) := to_signed(integer(round(tanh(k * real(i) / 1024.0) / tanh(k) * real(2 ** 23 - 1))), 24); -- entry i: tanh(k * i / 1024) / tanh(k), as Q1.23

        end loop;

        return table;

    end function generate_tanh_soft_clip_values;

    constant c_tanh : t_tanh := generate_tanh_soft_clip_values(g_drive); -- the ROM

    -- Before the register (from sample_in, this sample):
    signal s_pos     : signed(22 downto 0);  -- |sample_in|, bits 22..0 (inverted if negative)
    signal s_address : unsigned(9 downto 0); -- table address, bits 22..13 of s_pos
    -- After the register (both loaded on the same edge, so same sample):
    signal s_neg       : std_logic := '0';    -- '1': the sample was negative
    signal s_table_out : signed(23 downto 0); -- table value for |sample|, Q1.23

begin

    -- Step 3: when a new sample arrives, register its sign and read the
    -- table at its address (a registered read: block RAM), and raise
    -- sample_out_valid for that one clock.
    soft_clip_proc : process (clk) is
    begin

        if rising_edge(clk) then
            sample_out_valid <= '0';                               -- default: low; set high below for one clock
            if (reset = '1') then
                s_table_out <= (others => '0');
                s_neg       <= '0';
            elsif (sample_in_valid = '1') then
                s_neg            <= sample_in(23);
                s_table_out      <= c_tanh(to_integer(s_address));
                sample_out_valid <= '1';
            end if;                                                -- no else: s_neg, s_table_out hold their values
        end if;

    end process soft_clip_proc;

    -- Steps 1-2, before the register: uses sample_in(23), the sign of the
    -- sample arriving now (s_neg would still hold the previous sample's).
    s_pos     <= not(sample_in(22 downto 0)) when sample_in(23) = '1' else
                 sample_in(22 downto 0);
    s_address <= unsigned(s_pos(22 downto 13));

    -- Step 4, after the register: the sign back, with s_neg (same sample as
    -- s_table_out).
    sample_out <= not s_table_out when s_neg = '1' else
                  s_table_out;

end architecture rtl;
