-- Self-checking testbench for tone_gen.
--
-- Drives frame_start once every c_frame clocks (a short frame, so the run is
-- quick) and records every sample_out_valid pulse. Checks:
--   1. One valid pulse per frame_start, one clock wide.
--   2. The quarter points of the sine, from the table formula:
--      sample 0 = 0, 12 = +A, 24 = 0, 36 = -A (A = the -20 dBFS amplitude).
--   3. Every sample matches round(A * sin(2 pi i / 48)).
--   4. The period: sample i = sample i + 48 over two cycles.
--   5. Reset restarts the sine at sample 0.
--
-- Run (repo root, PowerShell, xsim):
--   xvhdl -2008 rtl/tone_gen.vhd sim/tone_gen_tb.vhd
--   xelab tone_gen_tb -s tone_gen_sim
--   xsim tone_gen_sim -R

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library std;
    use std.env.all;

entity tone_gen_tb is
end entity tone_gen_tb;

architecture sim of tone_gen_tb is

    constant clk_period : time     := 10 ns;
    constant c_frame    : positive := 20;    -- clocks per frame (real: 2048)
    constant c_level_db : real     := -20.0;
    constant c_steps    : positive := 48;
    constant c_count    : positive := 2 * c_steps;

    constant c_amplitude : real := (2.0 ** 23 - 1.0) * 10.0 ** (c_level_db / 20.0);

    signal clk              : std_logic := '0';
    signal reset            : std_logic := '1';
    signal frame_start      : std_logic := '0';
    signal sample_out       : signed(23 downto 0);
    signal sample_out_valid : std_logic;

    signal sim_done : boolean := false;

    type t_samples is array (0 to c_count - 1) of integer;

    -- The expected sample i (same formula as the design, worked out here).

    function expected (
        i : natural
    ) return integer is
    begin

        return integer(round(c_amplitude * sin(math_2_pi * real(i mod c_steps) / real(c_steps))));

    end function expected;

begin

    dut : entity work.tone_gen
        generic map (
            g_level_db => c_level_db
        )
        port map (
            clk              => clk,
            reset            => reset,
            frame_start      => frame_start,
            sample_out       => sample_out,
            sample_out_valid => sample_out_valid
        );

    clk <= not clk after clk_period / 2 when not sim_done else
           '0';

    -- frame_start: a one-clock strobe every c_frame clocks.
    frames : process is
    begin

        wait until rising_edge(clk) and reset = '0';

        while not sim_done loop

            frame_start <= '1';
            wait until rising_edge(clk);
            frame_start <= '0';

            for k in 1 to c_frame - 1 loop

                wait until rising_edge(clk);

            end loop;

        end loop;

        wait;

    end process frames;

    check : process is

        variable v_samples : t_samples;
        variable v_a       : integer;

        -- Wait for the next valid pulse, check it is one clock wide, return the sample.

        procedure get_sample (
            variable vs : out integer
        ) is
        begin

            wait until rising_edge(clk) and sample_out_valid = '1' for c_frame * 3 * clk_period;
            assert sample_out_valid = '1'
                report "no sample_out_valid within 3 frames"
                severity failure;
            vs := to_integer(sample_out);
            wait until rising_edge(clk);
            assert sample_out_valid = '0'
                report "sample_out_valid is wider than one clock"
                severity failure;

        end procedure get_sample;

    begin

        for k in 1 to 5 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';

        -- 1 and 3: two whole cycles, every sample against the formula.
        for i in 0 to c_count - 1 loop

            get_sample(v_samples(i));
            assert v_samples(i) = expected(i)
                report "sample " & integer'image(i) & " = " & integer'image(v_samples(i))
                       & ", expected " & integer'image(expected(i))
                severity failure;

        end loop;

        -- 2: the quarter points.
        v_a := integer(round(c_amplitude));
        assert v_samples(0) = 0 and v_samples(24) = 0
            report "zero crossings are not 0"
            severity failure;
        assert v_samples(12) = v_a and v_samples(36) = -v_a
            report "peaks are " & integer'image(v_samples(12)) & " / " & integer'image(v_samples(36))
                   & ", expected +/-" & integer'image(v_a)
            severity failure;

        -- 4: the period is exactly 48 samples.
        for i in 0 to c_steps - 1 loop

            assert v_samples(i) = v_samples(i + c_steps)
                report "sample " & integer'image(i) & " differs one cycle later"
                severity failure;

        end loop;

        -- 5: reset mid-cycle, then the sine starts again at sample 0.
        get_sample(v_samples(0)); -- now part way into the third cycle
        wait until rising_edge(clk);
        reset <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        reset <= '0';
        get_sample(v_samples(0));
        get_sample(v_samples(1));
        assert v_samples(0) = 0 and v_samples(1) = expected(1)
            report "after reset the sine did not restart at sample 0"
            severity failure;

        report "tone_gen: amplitude " & integer'image(v_a) & " (" & real'image(c_level_db)
               & " dBFS), 48-sample period, reset OK";
        report "ALL TESTS PASSED";
        sim_done <= true;
        wait for clk_period;
        finish;

    end process check;

end architecture sim;
