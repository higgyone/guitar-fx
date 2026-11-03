-- Self-checking testbench for soft_start.
--
-- Uses tiny generics so the whole mute -> ramp -> run sequence takes a few
-- samples instead of 3 seconds: mute 6 samples, ramp 2**2 = 4 samples.
-- A constant input x = 0.5 (Q1.23) is sent and each output is checked
-- against the expected behaviour (not against exact gain values, so the
-- test doesn't depend on internal timing details):
--
--   1. Mute: the first c_mute outputs are exactly 0.
--   2. Ramp: outputs never go down, never exceed x, rise by at most two
--            ramp steps at a time, take at least 2**c_ramp_bits - 1
--            samples, and reach x within the expected number of samples.
--   3. Run:  output equals the input (gain 1.0), positive and negative.
--   4. Reset during run: back to mute (output 0 for c_mute samples).
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/gain_stage.vhd rtl/soft_start.vhd sim/soft_start_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP soft_start_tb

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity soft_start_tb is
end entity soft_start_tb;

architecture sim of soft_start_tb is

    constant clk_period     : time    := 10 ns; -- 100 MHz
    constant timeout_cycles : natural := 20;    -- max latency accepted

    constant c_mute      : natural := 6; -- g_mute_samples for the test
    constant c_ramp_bits : natural := 2; -- ramp = 2**2 = 4 samples
    constant c_ramp_len  : natural := 2 ** c_ramp_bits;

    constant c_x        : integer := 2 ** 22;              -- test input, 0.5 in Q1.23
    constant c_max_rise : integer := 2 * c_x / c_ramp_len; -- two ramp steps, in output units

    signal clk              : std_logic           := '0';
    signal reset            : std_logic           := '1';
    signal sample_in        : signed(23 downto 0) := (others => '0');
    signal sample_in_valid  : std_logic           := '0';
    signal sample_out       : signed(23 downto 0);
    signal sample_out_valid : std_logic;

begin

    clk <= not clk after clk_period / 2;

    dut : entity work.soft_start
        generic map (
            g_mute_samples => c_mute,
            g_ramp_bits    => c_ramp_bits
        )
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_in,
            sample_in_valid  => sample_in_valid,
            sample_out       => sample_out,
            sample_out_valid => sample_out_valid
        );

    stimulus : process is

        -- Sends sample x with a one-clock valid pulse, waits for the output
        -- and returns it in y. Checks sample_out_valid is one clock wide.

        procedure send_sample (
            constant x : in integer;
            variable y : out integer
        ) is

            variable cycles : natural := 0;

        begin

            wait until rising_edge(clk);
            sample_in       <= to_signed(x, sample_in'length);
            sample_in_valid <= '1';
            wait until rising_edge(clk);
            sample_in_valid <= '0';

            while sample_out_valid /= '1' loop

                wait until rising_edge(clk);
                cycles := cycles + 1;
                assert cycles <= timeout_cycles
                    report "no sample_out_valid within "
                           & integer'image(timeout_cycles) & " clocks"
                    severity failure;

            end loop;

            y := to_integer(sample_out);

            wait until rising_edge(clk);
            assert sample_out_valid = '0'
                report "sample_out_valid longer than one clock"
                severity failure;

            -- Idle gap between samples (real system: 2083 clocks).
            for i in 1 to 3 loop

                wait until rising_edge(clk);

            end loop;

        end procedure send_sample;

        variable y       : integer;
        variable prev    : integer;
        variable n       : natural;
        variable reached : boolean;

    begin

        -- Reset for 3 clocks.
        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';

        -- 1. Mute: first c_mute outputs are 0.
        for i in 0 to c_mute - 1 loop

            send_sample(c_x, y);
            assert y = 0
                report "mute: sample " & integer'image(i) & " expected 0, got "
                       & integer'image(y)
                severity failure;

        end loop;

        report "mute: ok, " & integer'image(c_mute) & " samples at 0"
            severity note;

        -- 2. Ramp: rises steadily from 0 to x.
        prev    := 0;
        n       := 0;
        reached := false;

        while n < c_ramp_len + 4 loop

            send_sample(c_x, y);
            n    := n + 1;
            report "ramp: sample " & integer'image(n) & " output "
                   & integer'image(y)
                severity note;
            assert y >= prev
                report "ramp: output went down (" & integer'image(prev) & " -> "
                       & integer'image(y) & ")"
                severity failure;
            assert y <= c_x
                report "ramp: output above input (" & integer'image(y) & ")"
                severity failure;
            assert y - prev <= c_max_rise
                report "ramp: jump too big (" & integer'image(prev) & " -> "
                       & integer'image(y) & ")"
                severity failure;
            prev := y;

            if (y = c_x) then
                reached := true;
                exit;
            end if;

        end loop;

        assert reached
            report "ramp: never reached gain 1.0"
            severity failure;
        assert n >= c_ramp_len - 1
            report "ramp: too short, reached 1.0 after " & integer'image(n)
                   & " samples"
            severity failure;
        report "ramp: ok, reached 1.0 after " & integer'image(n) & " samples"
            severity note;

        -- 3. Run: output = input.
        for i in 1 to 4 loop

            send_sample(c_x, y);
            assert y = c_x
                report "run: expected " & integer'image(c_x) & ", got "
                       & integer'image(y)
                severity failure;
            send_sample(-c_x, y);
            assert y = -c_x
                report "run: expected " & integer'image(-c_x) & ", got "
                       & integer'image(y)
                severity failure;

        end loop;

        report "run: ok, output = input"
            severity note;

        -- 4. Reset during run: back to mute.
        wait until rising_edge(clk);
        reset <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        reset <= '0';

        for i in 0 to c_mute - 1 loop

            send_sample(c_x, y);
            assert y = 0
                report "after reset: sample " & integer'image(i)
                       & " expected 0, got " & integer'image(y)
                severity failure;

        end loop;

        report "reset: ok, muted again"
            severity note;

        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
