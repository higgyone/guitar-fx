-- Self-checking testbench for hard_clip_stage.
--
-- Each test sends one sample (one-clock sample_in_valid pulse) with a given
-- threshold, waits for sample_out_valid, and compares sample_out with the
-- expected value. Latency-tolerant (any pipeline depth up to
-- timeout_cycles); reports the measured latency.
--
-- Number formats: sample_in / sample_out / threshold are Q1.23, written here
-- as integers k = value * 2**23.
--   expected = +threshold  if sample >  +threshold
--              -threshold  if sample <  -threshold
--              sample      otherwise
--
-- Test groups:
--   1. The Q1 table: threshold 0.25, inputs +0.5, -0.5, +0.1, -0.25.
--   2. Edges: exactly on +/-threshold, one LSB either side.
--   3. Extreme thresholds: max (passes everything except -1.0) and 0
--      (everything clamps to 0).
--   4. sample_out holds its value between samples; reset clears it.
--
-- Run (repo root, PowerShell, GHDL):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/hard_clip_stage.vhd sim/hard_clip_stage_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP hard_clip_stage_tb
-- Or xsim: xvhdl -2008 (both files) -> xelab hard_clip_stage_tb -> xsim -R

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity hard_clip_stage_tb is
end entity hard_clip_stage_tb;

architecture sim of hard_clip_stage_tb is

    constant clk_period     : time    := 10 ns; -- 100 MHz
    constant timeout_cycles : natural := 20;    -- max latency accepted

    -- Q1.23 constants (integer form)
    constant q_0_10     : integer := 838861; -- round(0.1 * 2^23)
    constant q_0_25     : integer := 2 ** 21;
    constant q_0_50     : integer := 2 ** 22;
    constant sample_max : integer := 2 ** 23 - 1;
    constant sample_min : integer := -(2 ** 23);

    signal clk              : std_logic           := '0';
    signal reset            : std_logic           := '1';
    signal sample_in        : signed(23 downto 0) := (others => '0');
    signal sample_in_valid  : std_logic           := '0';
    signal threshold        : signed(23 downto 0) := (others => '0');
    signal sample_out       : signed(23 downto 0);
    signal sample_out_valid : std_logic;

begin

    clk <= not clk after clk_period / 2;

    dut : entity work.hard_clip_stage
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_in,
            sample_in_valid  => sample_in_valid,
            threshold        => threshold,
            sample_out       => sample_out,
            sample_out_valid => sample_out_valid
        );

    stimulus : process is

        -- Sends sample x with threshold t, waits for the output, checks it.
        -- All three are Q1.23 integer forms.

        procedure check_sample (
            constant name     : in string;
            constant x        : in integer;
            constant t        : in integer;
            constant expected : in integer
        ) is

            variable cycles : natural := 0;

        begin

            -- Present the sample with a one-clock valid pulse.
            wait until rising_edge(clk);
            sample_in       <= to_signed(x, sample_in'length);
            threshold       <= to_signed(t, threshold'length);
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

        -- Group 1: the Q1 table (threshold 0.25).
        check_sample("+0.5 clips to +0.25",  q_0_50,     q_0_25, q_0_25);
        check_sample("-0.5 clips to -0.25",  -q_0_50,    q_0_25, -q_0_25);
        check_sample("+0.1 passes",          q_0_10,     q_0_25, q_0_10);
        check_sample("-0.25 on the edge",    -q_0_25,    q_0_25, -q_0_25);

        -- Group 2: edges, one LSB either side of each threshold.
        check_sample("+t exactly",           q_0_25,     q_0_25, q_0_25);
        check_sample("+t + 1 LSB clips",     q_0_25 + 1, q_0_25, q_0_25);
        check_sample("+t - 1 LSB passes",    q_0_25 - 1, q_0_25, q_0_25 - 1);
        check_sample("-t - 1 LSB clips",     -q_0_25 - 1, q_0_25, -q_0_25);
        check_sample("-t + 1 LSB passes",    -q_0_25 + 1, q_0_25, -q_0_25 + 1);
        check_sample("full scale + clips",   sample_max, q_0_25, q_0_25);
        check_sample("full scale - clips",   sample_min, q_0_25, -q_0_25);
        check_sample("zero passes",          0,          q_0_25, 0);

        -- Group 3: extreme thresholds.
        -- Max threshold: everything passes except -1.0, which is below
        -- -max (= -1.0 + 1 LSB) and clips to it.
        check_sample("max t, + full scale",  sample_max, sample_max, sample_max);
        check_sample("max t, -1.0 clips",    sample_min, sample_max, -sample_max);
        check_sample("max t, small",         -12345,     sample_max, -12345);
        -- Zero threshold: every sample clamps to 0.
        check_sample("t = 0, +",             q_0_50,     0,          0);
        check_sample("t = 0, -",             -q_0_50,    0,          0);

        -- Group 4a: sample_out holds between samples (no valid pulse).
        check_sample("hold: set up",         q_0_10,     q_0_25, q_0_10);
        sample_in <= to_signed(-q_0_50, sample_in'length); -- changes, no valid

        for i in 1 to 10 loop

            wait until rising_edge(clk);
            assert sample_out = to_signed(q_0_10, sample_out'length)
                report "hold: sample_out changed without sample_in_valid"
                severity failure;

        end loop;

        report "hold: ok"
            severity note;

        -- Group 4b: reset clears the output to 0 and keeps valid low.
        reset <= '1';

        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        assert sample_out = to_signed(0, sample_out'length)
            report "reset: sample_out not cleared to 0, got "
                   & integer'image(to_integer(sample_out))
            severity failure;
        assert sample_out_valid = '0'
            report "reset: sample_out_valid high"
            severity failure;
        reset <= '0';
        report "reset: ok"
            severity note;

        -- And it works again after reset.
        check_sample("after reset",          -q_0_50,    q_0_25, -q_0_25);

        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
