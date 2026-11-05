-- i2s_tx: I2S transmitter for the Pmod I2S2's CS4344 DAC.
--
-- Takes one sample per frame from the effects chain (sample_in with a
-- one-clock sample_in_valid, the project's standard effect interface) and
-- sends it to the DAC on sdin, 24 bits MSB first, in BOTH slots (mono
-- guitar, heard in both ears).
--
-- Timing: the DAC reads sdin on sclk rising edges, so sdin changes on the
-- sclk_fall strobe (from i2s_clocks). Counting sclk falling edges
-- m = 0 .. 63 from the start of the frame, position in the slot = m mod 32:
--   0       delay bit, sdin = '0'; load the slot's sample into s_shift
--   1 .. 24 b23 .. b0: sdin = s_shift(23), then shift up one
--   25 .. 31 padding, sdin = '0'
-- m = 0 is the frame_start clock (sclk_fall is also '1' there, so
-- frame_start is tested first and sets s_m to 1 for the next edge).
--
-- Double buffer: s_hold catches every new sample, whenever it comes (it
-- usually lands mid-left-slot). At m = 0, s_frame <= s_hold: the sample for
-- this frame, held still for both slots so left and right never differ.
-- On that clock s_shift also loads from s_hold (s_frame only updates after
-- the edge); at m = 32 it reloads from s_frame.
--
-- Latency: a sample is sent in the frame after the frame_start that follows
-- it. Reset (synchronous, active high) clears everything, so the next
-- frame sends silence.
-- Design notes: docs/i2s.md section 4. Testbench: sim/i2s_tx_tb.vhd.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity i2s_tx is
    port (
        clk             : in    std_logic;           -- 98.304 MHz
        reset           : in    std_logic;           -- synchronous, active high
        sample_in       : in    signed(23 downto 0); -- from the effects chain
        sample_in_valid : in    std_logic;           -- one clock per sample
        sclk_fall       : in    std_logic;           -- strobe from i2s_clocks
        frame_start     : in    std_logic;           -- strobe from i2s_clocks
        sdin            : out   std_logic := '0'     -- Pmod DA SDIN pin (ja[3])
    );
end entity i2s_tx;

architecture rtl of i2s_tx is

    signal s_m     : natural range 0 to 63         := 0;               -- falling edge m in the frame
    signal s_hold  : std_logic_vector(23 downto 0) := (others => '0'); -- latest sample in
    signal s_frame : std_logic_vector(23 downto 0) := (others => '0'); -- this frame's sample
    signal s_shift : std_logic_vector(23 downto 0) := (others => '0'); -- bits left to send, MSB at 23

begin

    i2s_tx_proc : process (clk) is
    begin

        if rising_edge(clk) then
            -- Catch a new sample on any clock (not part of the chain below).
            if (sample_in_valid = '1') then
                s_hold <= std_logic_vector(sample_in);
            end if;

            if (reset = '1') then
                s_m     <= 0;
                s_hold  <= (others => '0');
                s_frame <= (others => '0');
                s_shift <= (others => '0');
                sdin    <= '0';
            elsif (frame_start = '1') then
                -- m = 0: new frame, left slot's delay bit.
                s_frame <= s_hold;
                s_shift <= s_hold;
                sdin    <= '0';
                s_m     <= 1;
            elsif (sclk_fall = '1') then
                -- One case per position in the slot (m mod 32).
                if (s_m mod 32 = 0) then
                    -- m = 32: right slot's delay bit, reload the same sample.
                    s_shift <= s_frame; -- double buffer
                    sdin    <= '0';
                elsif (s_m mod 32 >= 1 and s_m mod 32 <= 24) then
                    -- Data bits, the same in both slots as the guitar is mono.
                    sdin    <= s_shift(23);
                    s_shift <= s_shift(22 downto 0) & '0';
                else
                    -- Padding.
                    sdin <= '0';
                end if;

                if (s_m < 63) then
                    s_m <= s_m + 1;
                end if;
            end if;
        end if;

    end process i2s_tx_proc;

end architecture rtl;
