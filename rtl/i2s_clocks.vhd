-- i2s_clocks: clock generator for the Pmod I2S2 (CS5343 ADC, CS4344 DAC).
--
-- Runs from the one 98.304 MHz system clock. An 11-bit counter (0 .. 2047)
-- counts every clock and wraps to 0 by itself; three of its bits are the
-- I2S clocks (counter bit n = clk / 2^(n+1)):
--
--   mclk : bit 2  = clk / 8    = 12.288 MHz (256 x fs)
--   sclk : bit 4  = clk / 32   =  3.072 MHz (64 x fs, one data bit per clock)
--   lrck : bit 10 = clk / 2048 = 48 kHz     (fs; low = left, high = right)
--
-- These are outputs to the Pmod pins only; nothing inside uses them as
-- clocks. Logic uses the strobes instead: one clk wide, high on the clock
-- BEFORE the edge, so a process acting on a strobe acts on the same clk
-- edge as the I2S edge:
--
--   sclk_rise   : counter bits 4..0 = 15 (sclk about to go 0 -> 1)
--   sclk_fall   : counter bits 4..0 = 31 (sclk about to go 1 -> 0)
--   frame_start : counter = 2047 (lrck about to fall: new frame, left slot)
--
-- Reset: synchronous, active high, counter back to 0.
-- Design notes: docs/i2s.md section 3. Testbench: sim/i2s_clocks_tb.vhd.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity i2s_clocks is
    port (
        clk         : in    std_logic;
        reset       : in    std_logic;
        mclk        : out   std_logic;
        sclk        : out   std_logic;
        lrck        : out   std_logic;
        sclk_rise   : out   std_logic;
        sclk_fall   : out   std_logic;
        frame_start : out   std_logic
    );
end entity i2s_clocks;

architecture rtl of i2s_clocks is

    signal s_counter : unsigned(10 downto 0) := (others => '0'); -- 0 .. 2047, wraps

begin

    i2s_clocks_proc : process (clk) is
    begin

        if rising_edge(clk) then
            if (reset = '1') then
                s_counter <= (others => '0');
            else
                s_counter <= s_counter + 1;
            end if;
        end if;

    end process i2s_clocks_proc;

    -- I2S clocks: counter bits, straight to the pins.
    mclk <= s_counter(2);
    sclk <= s_counter(4);
    lrck <= s_counter(10);

    -- Strobes: one clk wide, the clock before each edge.
    sclk_rise <= '1' when s_counter(4 downto 0) = "01111" else
                 '0';
    sclk_fall <= '1' when s_counter(4 downto 0) = "11111" else
                 '0';

    frame_start <= '1' when s_counter = to_unsigned(2047, 11) else
                   '0';

end architecture rtl;
