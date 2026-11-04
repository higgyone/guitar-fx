-- File-streaming testbench for gain_stage.
--
-- Reads Q1.23 integers (one per line) from g_in_file, sends each one through
-- gain_stage with gain g_gain (Q3.15 integer), and writes each output to
-- g_out_file, one per line. No checking here: the Python run script compares
-- the output with the bit-exact model (model/gain_stage_model.py).
--
-- Samples are 8 clocks apart (not the real 2083) so a 5 s file simulates in
-- seconds; gain_stage only needs sample_in_valid pulses, not real timing.
--
-- File paths are relative to the directory the simulator runs in. GHDL from
-- the repo root (PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/gain_stage.vhd sim/gain_stage_file_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP gain_stage_file_tb -gg_gain=65536
-- Generics can be overridden with -g<name>=<value>, e.g. -gg_gain=65536 for
-- a gain of 2.0, or -gg_in_file=sim/out/other.txt.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library std;
    use std.textio.all;

entity gain_stage_file_tb is
    generic (
        g_in_file  : string  := "sim/out/gain_in.txt";  -- input samples, Q1.23
        g_out_file : string  := "sim/out/gain_out.txt"; -- output samples, Q1.23
        g_gain     : integer := 2 ** 15                 -- gain, Q3.15 (2**15 = 1.0)
    );
end entity gain_stage_file_tb;

architecture sim of gain_stage_file_tb is

    constant clk_period     : time    := 10 ns; -- 100 MHz
    constant timeout_cycles : natural := 20;    -- max latency accepted
    constant gap_cycles     : natural := 5;     -- idle clocks between samples

    signal clk              : std_logic           := '0';
    signal reset            : std_logic           := '1';
    signal sample_in        : signed(23 downto 0) := (others => '0');
    signal sample_in_valid  : std_logic           := '0';
    signal gain             : signed(17 downto 0) := to_signed(g_gain, 18);
    signal sample_out       : signed(23 downto 0);
    signal sample_out_valid : std_logic;

begin

    clk <= not clk after clk_period / 2;

    dut : entity work.gain_stage
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_in,
            sample_in_valid  => sample_in_valid,
            gain             => gain,
            sample_out       => sample_out,
            sample_out_valid => sample_out_valid
        );

    stimulus : process is

        file     in_file  : text;
        file     out_file : text;
        variable in_line  : line;
        variable out_line : line;
        variable x        : integer;
        variable count    : natural := 0;
        variable cycles   : natural;

    begin

        file_open(in_file, g_in_file, read_mode);
        file_open(out_file, g_out_file, write_mode);

        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';

        while not endfile(in_file) loop

            readline(in_file, in_line);
            read(in_line, x);

            -- Send one sample with a one-clock valid pulse.
            wait until rising_edge(clk);
            sample_in       <= to_signed(x, sample_in'length);
            sample_in_valid <= '1';
            wait until rising_edge(clk);
            sample_in_valid <= '0';

            -- Wait for its output, then write it.
            cycles := 0;

            while sample_out_valid /= '1' loop

                wait until rising_edge(clk);
                cycles := cycles + 1;
                assert cycles <= timeout_cycles
                    report "no sample_out_valid for sample " & integer'image(count)
                    severity failure;

            end loop;

            write(out_line, to_integer(sample_out));
            writeline(out_file, out_line);
            count := count + 1;

            for i in 1 to gap_cycles loop

                wait until rising_edge(clk);

            end loop;

        end loop;

        file_close(in_file);
        file_close(out_file);
        report "done: " & integer'image(count) & " samples, gain "
               & integer'image(g_gain) & ", written to " & g_out_file
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
