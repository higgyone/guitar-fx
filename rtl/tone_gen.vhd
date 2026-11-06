-- tone_gen: a test tone for checking the DAC and line out on the board.
--
-- A 1 kHz sine, one sample per audio frame. At 48 kHz that is exactly 48
-- samples per cycle, so a 48-entry table repeats with no drift and no
-- phase accumulator is needed.
--
-- Output: the project's standard effect interface, sample_out with a
-- one-clock sample_out_valid, so it can feed i2s_tx in place of the
-- effects chain (top's g_test_tone switch does that).
--
-- Level: g_level_db, in dBFS (0 dB = a full-scale 24-bit sine). The default
-- -20 dBFS is about 0.15 V peak at the Pmod line out: safe for a PC mic or
-- line input.
--
-- The table is a constant worked out with ieee.math_real when the design is
-- elaborated. Synthesis only sees the 48 finished numbers, so math_real is
-- fine here (it would not be in logic that runs on the chip).
--
-- Reset (synchronous, active high) restarts the sine at sample 0.
-- Testbench: sim/tone_gen_tb.vhd.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity tone_gen is
    generic (
        g_level_db : real := -20.0 -- peak level in dBFS
    );
    port (
        clk              : in    std_logic;                              -- 98.304 MHz
        reset            : in    std_logic;                              -- synchronous, active high
        frame_start      : in    std_logic;                              -- strobe from i2s_clocks
        sample_out       : out   signed(23 downto 0) := (others => '0'); -- to i2s_tx
        sample_out_valid : out   std_logic           := '0'              -- one clock per sample
    );
end entity tone_gen;

architecture rtl of tone_gen is

    constant c_steps : positive := 48; -- 48 kHz / 1 kHz

    type t_table is array (0 to c_steps - 1) of signed(23 downto 0);

    -- One cycle of the sine: amplitude * sin(2 pi i / 48), rounded.

    function make_table return t_table is

        constant c_amplitude : real := (2.0 ** 23 - 1.0) * 10.0 ** (g_level_db / 20.0);
        variable v_table     : t_table;

    begin

        for i in 0 to c_steps - 1 loop

            v_table(i) := to_signed(integer(round(c_amplitude * sin(math_2_pi * real(i) / real(c_steps)))), 24);

        end loop;

        return v_table;

    end function make_table;

    constant c_table : t_table := make_table;

    signal s_index : natural range 0 to c_steps - 1 := 0;

begin

    tone_proc : process (clk) is
    begin

        if rising_edge(clk) then
            sample_out_valid <= '0'; -- a one-clock pulse unless set below

            if (reset = '1') then
                s_index    <= 0;
                sample_out <= (others => '0');
            elsif (frame_start = '1') then
                -- One new sample per frame.
                sample_out       <= c_table(s_index);
                sample_out_valid <= '1';

                if (s_index = c_steps - 1) then
                    s_index <= 0;
                else
                    s_index <= s_index + 1;
                end if;
            end if;
        end if;

    end process tone_proc;

end architecture rtl;
