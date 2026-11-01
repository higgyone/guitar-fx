-- Self-checking testbench for gain_stage.
--
-- Each test sends one sample (one-clock sample_in_valid pulse), waits for
-- sample_out_valid, and compares sample_out with the expected value.
-- Latency-tolerant: works for any pipeline depth up to timeout_cycles, and
-- reports the measured latency.
--
-- Number formats (see docs/learning/01_fixed_point.md):
--   sample_in / sample_out : Q1.23, integer k = value * 2**23
--   gain                   : Q3.15, integer k = value * 2**15
--   expected               = sample * gain / 2**15
--
-- Test groups:
--   1. Exact results: no rounding, no overflow. Pass with v1 (truncate).
--   2. Saturation (added with v2).
--   3. Rounding (added with v3).
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/gain.vhd sim/gain_stage_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP gain_stage_tb

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity gain_stage_tb is
end entity gain_stage_tb;

architecture sim of gain_stage_tb is

    constant clk_period     : time    := 10 ns; -- 100 MHz
    constant timeout_cycles : natural := 20;    -- max latency accepted

    -- Q3.15 gain constants (integer form)
    constant gain_0_00  : integer := 0;
    constant gain_0_50  : integer := 2 ** 14;
    constant gain_0_75  : integer := 3 * 2 ** 13;
    constant gain_1_00  : integer := 2 ** 15;
    constant gain_2_00  : integer := 2 ** 16;
    constant gain_m1_00 : integer := -(2 ** 15);

    -- Q1.23 limits (integer form)
    constant sample_max : integer := 2 ** 23 - 1;
    constant sample_min : integer := -(2 ** 23);

    signal clk              : std_logic           := '0';
    signal reset            : std_logic           := '1';
    signal sample_in        : signed(23 downto 0) := (others => '0');
    signal sample_in_valid  : std_logic           := '0';
    signal gain             : signed(17 downto 0) := (others => '0');
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

        -- Sends sample x with gain g, waits for the output, checks it.
        -- x, g and expected are integer forms (Q1.23, Q3.15, Q1.23).

        procedure check_sample (
            constant name     : in string;
            constant x        : in integer;
            constant g        : in integer;
            constant expected : in integer
        ) is

            variable cycles : natural := 0;

        begin

            -- Present the sample with a one-clock valid pulse.
            wait until rising_edge(clk);
            sample_in       <= to_signed(x, sample_in'length);
            gain            <= to_signed(g, gain'length);
            sample_in_valid <= '1';
            wait until rising_edge(clk);
            sample_in_valid <= '0';

            -- Wait for the result. cycles ends equal to the latency.
            while sample_out_valid /= '1' loop

                wait until rising_edge(clk);
                cycles := cycles + 1;
                assert cycles <= timeout_cycles
                    report name & ": no sample_out_valid within "
                           & integer'image(timeout_cycles) & " clocks"
                    severity failure;

            end loop;

            assert sample_out = to_signed(expected, sample_out'length)
                report name & ": expected " & integer'image(expected)
                       & ", got " & integer'image(to_integer(sample_out))
                severity failure;

            -- sample_out_valid must be a single-clock pulse.
            wait until rising_edge(clk);
            assert sample_out_valid = '0'
                report name & ": sample_out_valid longer than one clock"
                severity failure;

            report name & ": ok, latency " & integer'image(cycles) & " clock(s)"
                severity note;

            -- Idle gap between samples (real system: 2083 clocks).
            for i in 1 to 5 loop

                wait until rising_edge(clk);

            end loop;

        end procedure check_sample;

    begin

        -- Reset for 3 clocks. Output valid must stay low.
        for i in 1 to 3 loop

            wait until rising_edge(clk);
            assert sample_out_valid /= '1'
                report "sample_out_valid high during reset"
                severity failure;

        end loop;

        reset <= '0';

        -- Group 1: exact results (no rounding, no overflow).
        check_sample("unity +",          1000,        gain_1_00, 1000);
        check_sample("unity -",          -1000,       gain_1_00, -1000);
        check_sample("unity max",        sample_max,  gain_1_00, sample_max);
        check_sample("unity min",        sample_min,  gain_1_00, sample_min);
        check_sample("half +",           2000,        gain_0_50, 1000);
        check_sample("half -",           -2000,       gain_0_50, -1000);
        check_sample("three quarters",   4000,        gain_0_75, 3000);
        check_sample("double +",         1000,        gain_2_00, 2000);
        check_sample("double -",         -1000,       gain_2_00, -2000);
        check_sample("double quarter fs", 2 ** 21,    gain_2_00, 2 ** 22);
        check_sample("zero gain",        sample_max,  gain_0_00, 0);
        check_sample("invert",           1000,        gain_m1_00, -1000);

        -- Group 2: saturation (enable with v2).
        -- Group 3: rounding (enable with v3).

        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
