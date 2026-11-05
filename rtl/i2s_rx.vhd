-- i2s_rx: I2S receiver for the Pmod I2S2's CS5343 ADC (left channel only).
--
-- Collects the 24-bit left sample from sdout, MSB first, and outputs it once
-- per frame on sample_out with a one-clock sample_out_valid (the project's
-- standard effect interface). The right slot is ignored (mono guitar).
--
-- Timing: sdout is read on sclk_rise strobes (from i2s_clocks). Counting
-- sclk rising edges k = 0, 1, 2 ... from frame_start:
--   k = 0       I2S delay bit, ignored
--   k = 1 .. 24 b23 (MSB) .. b0, shifted into s_shift
--   k = 24      the sample is complete: sample_out = the old 23 bits & the
--               bit arriving now (s_shift itself only updates after the edge)
--   k > 24      padding and the right slot, ignored
--
-- The bit counter stops at 25 ("done for this frame") until the next
-- frame_start. Reset (synchronous, active high) and power-up also leave it
-- at 25, so a reset in the middle of a frame gives no garbage sample: the
-- receiver waits for the next frame_start.
-- Design notes: docs/i2s.md section 4. Testbench: sim/i2s_rx_tb.vhd.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity i2s_rx is
    port (
        clk              : in    std_logic;                              -- 98.304 MHz
        reset            : in    std_logic;                              -- synchronous, active high
        sdout            : in    std_logic;                              -- Pmod AD SDOUT pin (ja[7])
        sclk_rise        : in    std_logic;                              -- strobe from i2s_clocks
        frame_start      : in    std_logic;                              -- strobe from i2s_clocks
        sample_out       : out   signed(23 downto 0) := (others => '0'); -- to the effects chain
        sample_out_valid : out   std_logic                               -- one clock per frame
    );
end entity i2s_rx;

architecture rtl of i2s_rx is

    signal s_bit   : natural range 0 to 25         := 25;              -- k; 25 = done / waiting
    signal s_shift : std_logic_vector(23 downto 0) := (others => '0'); -- bits so far, MSB first

begin

    i2s_rx_proc : process (clk) is
    begin

        if rising_edge(clk) then
            sample_out_valid <= '0'; -- default: the '1' below wins on the k = 24 clock

            if (reset = '1') then
                s_bit   <= 25;
                s_shift <= (others => '0');
            elsif (frame_start = '1') then
                s_bit <= 0;
            elsif (sclk_rise = '1') then
                -- Data bits b23 .. b0.
                if (s_bit >= 1 and s_bit <= 24) then
                    s_shift <= s_shift(22 downto 0) & sdout;
                end if;

                -- Last bit: output the finished sample.
                if (s_bit = 24) then
                    sample_out       <= signed(s_shift(22 downto 0) & sdout);
                    sample_out_valid <= '1';
                end if;

                -- Count up to 25, then wait for the next frame_start.
                if (s_bit < 25) then
                    s_bit <= s_bit + 1;
                end if;
            end if;
        end if;

    end process i2s_rx_proc;

end architecture rtl;
