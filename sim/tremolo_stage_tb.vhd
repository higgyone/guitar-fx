-- Self-checking testbench for tremolo_stage.
--
-- Feeds a constant-size input (amplitude 0.5, sign alternating every
-- sample so the sign path is checked too) and watches the output envelope:
-- |out| / |in| is the tremolo gain at that sample.
--
-- The rate is set to 100 Hz at 48 kHz (a 480-sample period) so a few
-- periods simulate quickly; sample_in_valid pulses every 8 clocks instead
-- of every ~2048 (the block counts samples, not clocks, so the period in
-- samples is the same).
--
-- Checks (g = |out| / |in|, d = g_depth):
--   1. Never louder than the input: g <= 1.0 (no boost, no clipping).
--   2. Right sign: out has the sign of in (whenever g is not ~0).
--   3. The first sample after reset: phase 0, sin 0, so g = 1 - d/2.
--   4. Range: max g = 1.0 (sine trough), min g = 1 - d (sine peak).
--   5. Rate: g crosses its middle level (1 - d/2) going up once every
--      480 samples (+-1 for where the samples land in the cycle).
--   6. d = 0: no tremolo at all, every output equals its input exactly.
--   7. One output per input.
--
-- Run for each depth (generic g_depth, default 0.5): 0.5, 1.0 and 0.0.
--   xsim: xvhdl -2008 rtl/gain_stage.vhd rtl/tremolo_stage.vhd
--         sim/tremolo_stage_tb.vhd
--         xelab tremolo_stage_tb -generic_top g_depth=1.0 -s trem_d10
--         (put the xelab arguments in a file and use xelab -f: the .bat
--         launcher splits "g_depth=1.0" at the '=')

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity tremolo_stage_tb is
    generic (
        g_depth : real := 0.5 -- passed to the DUT
    );
end entity tremolo_stage_tb;

architecture sim of tremolo_stage_tb is

    constant clk_period    : time    := 10 ns;
    constant c_rate_hz     : real    := 100.0;
    constant c_sample_rate : real    := 48000.0;
    constant c_period      : natural := 480;               -- samples per LFO cycle
    constant c_n_samples   : natural := 5 * c_period + 50; -- five cycles and a bit
    constant c_clocks_per  : natural := 8;                 -- clocks between samples
    constant c_amp         : integer := 2 ** 22;           -- 0.5 full scale
    constant c_tol         : real    := 0.002;             -- envelope tolerance

    signal clk              : std_logic           := '0';
    signal reset            : std_logic           := '1';
    signal sample_in        : signed(23 downto 0) := (others => '0');
    signal sample_in_valid  : std_logic           := '0';
    signal sample_out       : signed(23 downto 0);
    signal sample_out_valid : std_logic;

    signal sim_done : boolean := false;
    signal n_in     : natural := 0; -- samples sent

begin

    clk <= not clk after clk_period / 2 when not sim_done;

    dut : entity work.tremolo_stage
        generic map (
            g_rate_hz     => c_rate_hz,
            g_sample_rate => c_sample_rate,
            g_depth       => g_depth
        )
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_in,
            sample_in_valid  => sample_in_valid,
            sample_out       => sample_out,
            sample_out_valid => sample_out_valid
        );

    -- Sends c_n_samples samples, +amp and -amp alternately, one every
    -- c_clocks_per clocks.
    stimulus : process is
    begin

        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';

        -- Let the gain pipeline (5 registers) settle on phase 0.
        for i in 1 to 10 loop

            wait until rising_edge(clk);

        end loop;

        for n in 0 to c_n_samples - 1 loop

            if (n mod 2 = 0) then
                sample_in <= to_signed(c_amp, 24);
            else
                sample_in <= to_signed(-c_amp, 24);
            end if;

            sample_in_valid <= '1';
            n_in            <= n + 1;
            wait until rising_edge(clk);
            sample_in_valid <= '0';

            for i in 2 to c_clocks_per loop

                wait until rising_edge(clk);

            end loop;

        end loop;

        wait;

    end process stimulus;

    checker : process is

        variable n_out     : natural := 0;
        variable g         : real;
        variable g_prev    : real    := -1.0;
        variable g_min     : real    := 10.0;
        variable g_max     : real    := -10.0;
        variable mid       : real;
        variable expect_in : integer;
        variable last_up   : integer := -1;
        variable n_up      : natural := 0;
        variable gap       : integer;

    begin

        mid := 1.0 - g_depth / 2.0;

        while n_out < c_n_samples loop

            wait until rising_edge(clk);

            if (sample_out_valid = '1') then
                if (n_out mod 2 = 0) then
                    expect_in := c_amp;
                else
                    expect_in := -c_amp;
                end if;

                g := abs (real(to_integer(sample_out))) / real(c_amp);

                -- 1. never louder than the input
                assert g <= 1.0 + 1.0e-6
                    report "sample " & integer'image(n_out) & ": gain " & real'image(g) & " > 1.0"
                    severity failure;

                -- 2. sign follows the input
                if (g > 0.01) then
                    assert (to_integer(sample_out) > 0) = (expect_in > 0)
                        report "sample " & integer'image(n_out) & ": wrong sign"
                        severity failure;
                end if;

                -- 3. first sample: phase 0, sin 0
                if (n_out = 0) then
                    assert abs (g - mid) < c_tol
                        report "first sample: gain " & real'image(g) & ", expected "
                               & real'image(mid) & " (phase 0)"
                        severity failure;
                end if;

                -- 6. depth 0: exact pass-through
                if (g_depth = 0.0) then
                    assert to_integer(sample_out) = expect_in
                        report "depth 0: sample " & integer'image(n_out) & " changed: "
                               & integer'image(to_integer(sample_out))
                        severity failure;
                end if;

                -- 4. range
                if (g < g_min) then
                    g_min := g;
                end if;

                if (g > g_max) then
                    g_max := g;
                end if;

                -- 5. rate: upward crossings of the middle level
                if (g_depth > 0.0 and g_prev >= 0.0 and g_prev < mid and g >= mid) then
                    if (last_up >= 0) then
                        gap := n_out - last_up;
                        assert abs (gap - c_period) <= 1
                            report "period " & integer'image(gap) & " samples, expected "
                                   & integer'image(c_period)
                            severity failure;
                    end if;

                    last_up := n_out;
                    n_up    := n_up + 1;
                end if;

                g_prev := g;
                n_out  := n_out + 1;
            end if;

        end loop;

        -- 4. range over the whole run
        assert abs (g_max - 1.0) < c_tol
            report "max gain " & real'image(g_max) & ", expected 1.0"
            severity failure;
        assert abs (g_min - (1.0 - g_depth)) < c_tol
            report "min gain " & real'image(g_min) & ", expected " & real'image(1.0 - g_depth)
            severity failure;

        -- 5. enough cycles seen to check the rate
        if (g_depth > 0.0) then
            assert n_up >= 4
                report "only " & integer'image(n_up) & " cycles seen"
                severity failure;
        end if;

        -- 7. one output per input (stimulus is done once n_out reaches it)
        for i in 1 to 4 * c_clocks_per loop

            wait until rising_edge(clk);
            assert sample_out_valid = '0'
                report "extra sample_out_valid after the last input"
                severity failure;

        end loop;

        assert n_in = n_out
            report "inputs " & integer'image(n_in) & ", outputs " & integer'image(n_out)
            severity failure;

        report "depth " & real'image(g_depth) & ": gain " & real'image(g_min) & " .. "
               & real'image(g_max) & ", " & integer'image(n_up) & " cycles of "
               & integer'image(c_period) & " samples, " & integer'image(n_out)
               & " samples"
            severity note;
        report "ALL TESTS PASSED"
            severity note;
        sim_done <= true;
        wait;

    end process checker;

end architecture sim;
