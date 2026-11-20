-- Self-checking testbench for tone_stage (biquad low-pass).
--
-- A model of the filter runs alongside the DUT, written from the maths
-- (model/biquad_model.py's biquad_q), not from the DUT: Direct Form I, the
-- five products summed at 45 bits, + 2**15, >> 16, clipped to Q1.23, the
-- state holding the clipped outputs. Every output is compared bit for bit.
-- The model's coefficients come from the same generics, so any cutoff / Q
-- can be checked. For the default (3 kHz, Q 0.707) the impulse and step
-- responses are also compared with numbers printed by the Python model
-- itself, so a mistake shared by DUT and TB model (e.g. a wrong formula)
-- still fails.
--
-- Checked on every clock: sample_out_valid pulses exactly 3 clocks after
-- each sample_in_valid (one output per input), and a reset drops samples in
-- flight.
--
-- Tests:
--   1. Impulse (0.5 full scale): 16 outputs = Python's.
--   2. Full-scale step up: the overshoot clips at +full scale; 30 outputs =
--      Python's. Then a full-scale step down clips at -full scale.
--   3. Reset mid-stream (a sample in flight): the impulse again gives
--      Python's numbers exactly (state cleared).
--   4. Sines 1 kHz and 10 kHz (0.5 full scale): gain about 0 dB and
--      -23.5 dB (default generics only).
--   5. 3000 random samples, 4 to 12 clocks apart (4 is the minimum: the
--      y state is updated 3 clocks after the input).
--
-- Run (xsim): xvhdl -2008 rtl/tone_stage.vhd sim/tone_stage_tb.vhd ->
-- xelab tone_stage_tb -> xsim -R. Other filters: xelab tone_stage_tb
-- -generic_top g_cutoff_hz=1000.0 -generic_top g_q=2.0 (via xelab -f file:
-- the .bat launcher splits "x=y").

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity tone_stage_tb is
    generic (
        g_cutoff_hz : real := 3000.0; -- passed to the DUT and the model
        g_q         : real := 0.707
    );
end entity tone_stage_tb;

architecture sim of tone_stage_tb is

    constant clk_period    : time    := 10 ns;
    constant c_sample_rate : real    := 48000.0;
    constant c_max         : integer := 2 ** 23 - 1;
    constant c_min         : integer := -(2 ** 23);
    constant c_default     : boolean := g_cutoff_hz = 3000.0 and g_q = 0.707;

    type t_ints is array (natural range <>) of integer;

    -- Printed by model/biquad_model.py (biquad_q, 3 kHz, Q 0.707).
    constant c_py_impulse : t_ints(0 to 15) :=
    (
        125632,
        433957,
        684576,
        746412,
        692477,
        578551,
        443840,
        313338,
        200888,
        112272,
        47954,
        5290,
        -19833,
        -31877,
        -34971,
        -32557
    );
    constant c_py_step    : t_ints(0 to 8)  :=
    (
        251264,
        1119178,
        2488330,
        3981154,
        5366108,
        6523210,
        7410889,
        8037564,
        8388607
    ); -- then 8388607 (clipped) for the rest of the 30

    -- The model's coefficients: Cookbook low-pass / a0, Q2.16.

    function coeff (
        name : string
    ) return signed is

        constant w0    : real := 2.0 * MATH_PI * g_cutoff_hz / c_sample_rate;
        constant alpha : real := sin(w0) / (2.0 * g_q);
        constant a0    : real := 1.0 + alpha;
        variable v     : real;

    begin

        if (name = "b0" or name = "b2") then
            v := (1.0 - cos(w0)) / 2.0;
        elsif (name = "b1") then
            v := 1.0 - cos(w0);
        elsif (name = "a1") then
            v := -2.0 * cos(w0);
        else
            v := 1.0 - alpha;
        end if;

        return to_signed(integer(round(v / a0 * 65536.0)), 18);

    end function coeff;

    constant m_b0 : signed(17 downto 0) := coeff("b0");
    constant m_b1 : signed(17 downto 0) := coeff("b1");
    constant m_b2 : signed(17 downto 0) := coeff("b2");
    constant m_a1 : signed(17 downto 0) := coeff("a1");
    constant m_a2 : signed(17 downto 0) := coeff("a2");

    signal clk              : std_logic           := '0';
    signal reset            : std_logic           := '1';
    signal sample_in        : signed(23 downto 0) := (others => '0');
    signal sample_in_valid  : std_logic           := '0';
    signal sample_out       : signed(23 downto 0);
    signal sample_out_valid : std_logic;

    signal sim_done : boolean := false;

    -- Outputs as they arrive (written by the checker only).
    signal out_log : t_ints(0 to 9999) := (others => 0);
    signal n_out   : natural           := 0;
    signal n_fail  : natural           := 0;

begin

    clk <= not clk after clk_period / 2 when not sim_done;

    dut : entity work.tone_stage
        generic map (
            g_cutoff_hz   => g_cutoff_hz,
            g_q           => g_q,
            g_sample_rate => c_sample_rate
        )
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_in,
            sample_in_valid  => sample_in_valid,
            sample_out       => sample_out,
            sample_out_valid => sample_out_valid
        );

    -- The model and the checks, on every clock edge.
    checker : process is

        variable x1        : signed(23 downto 0)      := (others => '0');
        variable x2        : signed(23 downto 0)      := (others => '0');
        variable y1        : signed(23 downto 0)      := (others => '0');
        variable y2        : signed(23 downto 0)      := (others => '0');
        variable acc       : signed(44 downto 0);
        variable r         : signed(44 downto 0);
        variable y         : signed(23 downto 0);
        variable expected  : t_ints(0 to 15);                             -- outputs computed, not yet seen
        variable n_exp     : natural                  := 0;
        variable exp_valid : std_logic_vector(1 to 3) := (others => '0'); -- input valid, delayed 1..3

    begin

        wait until rising_edge(clk);

        -- Checks against what the DUT shows after the previous edge.
        assert sample_out_valid = exp_valid(3)
            report "sample_out_valid is " & std_logic'image(sample_out_valid)
                   & ", expected " & std_logic'image(exp_valid(3)) & " (3 clocks after each input)"
            severity failure;

        if (sample_out_valid = '1') then
            assert n_exp > 0
                report "output with no input to match"
                severity failure;
            if (to_integer(sample_out) /= expected(0)) then
                report "output " & integer'image(n_out) & ": " & integer'image(to_integer(sample_out))
                       & ", model " & integer'image(expected(0))
                    severity error;
                n_fail <= n_fail + 1;
            end if;
            out_log(n_out)    <= to_integer(sample_out);
            n_out             <= n_out + 1;
            expected(0 to 14) := expected(1 to 15);
            n_exp             := n_exp - 1;
        end if;

        -- The model steps on this edge, like the DUT.
        if (reset = '1') then
            x1        := (others => '0');
            x2        := (others => '0');
            y1        := (others => '0');
            y2        := (others => '0');
            exp_valid := (others => '0');
            n_exp     := 0;
        else
            exp_valid := sample_in_valid & exp_valid(1 to 2);
            if (sample_in_valid = '1') then
                acc := resize(m_b0 * sample_in, 45) + resize(m_b1 * x1, 45) + resize(m_b2 * x2, 45)
                       - resize(m_a1 * y1, 45) - resize(m_a2 * y2, 45);
                r   := shift_right(acc + 2 ** 15, 16);
                if (r > c_max) then
                    y := to_signed(c_max, 24);
                elsif (r < c_min) then
                    y := to_signed(c_min, 24);
                else
                    y := resize(r, 24);
                end if;
                x2              := x1;
                x1              := sample_in;
                y2              := y1;
                y1              := y;
                expected(n_exp) := to_integer(y);
                n_exp           := n_exp + 1;
            end if;
        end if;

    end process checker;

    stimulus : process is

        variable seed1, seed2 : positive := 11;
        variable r            : real;
        variable gap          : natural;
        variable first        : natural;
        variable peak         : integer;
        variable gain_db      : real;

        -- One sample, then wait so the next comes gap clocks later.

        procedure send (
            constant v       : in integer;
            constant gap_clk : in natural := 8
        ) is
        begin

            sample_in       <= to_signed(v, 24);
            sample_in_valid <= '1';
            wait until rising_edge(clk);
            sample_in_valid <= '0';

            for i in 2 to gap_clk loop

                wait until rising_edge(clk);

            end loop;

        end procedure send;

        -- Lets the last outputs come out.

        procedure drain is
        begin

            for i in 1 to 8 loop

                wait until rising_edge(clk);

            end loop;

        end procedure drain;

        procedure pulse_reset is
        begin

            reset <= '1';
            wait until rising_edge(clk);
            reset <= '0';
            wait until rising_edge(clk);

        end procedure pulse_reset;

        -- Compares outputs first .. first + n - 1 with Python's numbers.

        procedure check_python (
            constant name : in string;
            constant from : in natural;
            constant py   : in t_ints
        ) is
        begin

            for i in py'range loop

                assert out_log(from + i - py'low) = py(i)
                    report name & " output " & integer'image(i - py'low) & ": "
                           & integer'image(out_log(from + i - py'low)) & ", Python "
                           & integer'image(py(i))
                    severity failure;

            end loop;

        end procedure check_python;

        procedure impulse is
        begin

            send(2 ** 22);

            for i in 1 to 15 loop

                send(0);

            end loop;

            drain;

        end procedure impulse;

    begin

        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';
        wait until rising_edge(clk);

        -- 1. Impulse.
        first := n_out;
        impulse;

        if (c_default) then
            check_python("impulse", first, c_py_impulse);
        end if;

        report "1 impulse: ok"
            severity note;

        -- 2. Full-scale steps: the overshoot clips.
        pulse_reset;
        first := n_out;

        for i in 1 to 30 loop

            send(c_max);

        end loop;

        drain;
        peak := c_min;

        for i in first to n_out - 1 loop

            if (out_log(i) > peak) then
                peak := out_log(i);
            end if;

        end loop;

        if (c_default) then
            check_python("step", first, c_py_step);

            for i in first + 9 to first + 29 loop

                assert out_log(i) = c_max
                    report "step: output " & integer'image(i - first) & " not clipped at +full scale"
                    severity failure;

            end loop;

        end if;

        pulse_reset;
        first := n_out;

        for i in 1 to 30 loop

            send(c_min);

        end loop;

        drain;

        if (c_default) then
            assert out_log(first + 20) = c_min
                report "step down: not clipped at -full scale"
                severity failure;
        end if;

        report "2 full-scale steps: ok (peak " & integer'image(peak) & ")"
            severity note;

        -- 3. Reset with a sample in flight, then the impulse again.
        send(3000000, 2);
        reset <= '1';
        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);
        drain;
        first := n_out;
        impulse;

        if (c_default) then
            check_python("impulse after reset", first, c_py_impulse);
        end if;

        report "3 reset mid-stream: ok"
            severity note;

        -- 4. Sines, 0.5 full scale, 960 samples (20 ms) each.
        for f_idx in 0 to 1 loop

            pulse_reset;
            first := n_out;

            for n in 0 to 959 loop

                if (f_idx = 0) then
                    send(integer(round(0.5 * 2.0 ** 23 * sin(2.0 * MATH_PI * 1000.0 * real(n) / c_sample_rate))));
                else
                    send(integer(round(0.5 * 2.0 ** 23 * sin(2.0 * MATH_PI * 10000.0 * real(n) / c_sample_rate))));
                end if;

            end loop;

            drain;
            peak := 0;

            for i in first + 480 to n_out - 1 loop                                                                  -- second half: settled

                if (abs (out_log(i)) > peak) then
                    peak := abs (out_log(i));
                end if;

            end loop;

            gain_db := 20.0 * log10(real(peak + 1) / (0.5 * 2.0 ** 23));                                            -- + 1: never log10(0)

            if (c_default) then
                if (f_idx = 0) then
                    assert abs (gain_db) < 0.5
                        report "1 kHz gain " & real'image(gain_db) & " dB, expected about 0"
                        severity failure;
                else
                    assert gain_db > -25.0 and gain_db < -22.0
                        report "10 kHz gain " & real'image(gain_db) & " dB, expected about -23.5"
                        severity failure;
                end if;
            end if;

            report "4 sine " & integer'image(1000 + 9000 * f_idx) & " Hz: gain " & real'image(gain_db) & " dB"
                severity note;

        end loop;

        -- 5. Random samples, random spacing 4 .. 12 clocks.
        pulse_reset;

        for i in 1 to 3000 loop

            uniform(seed1, seed2, r);
            gap := 4 + integer(trunc(r * 9.0));
            uniform(seed1, seed2, r);
            send(integer(trunc((r - 0.5) * 2.0 ** 24)), gap);

        end loop;

        drain;
        report "5 random: 3000 samples, 4 to 12 clocks apart"
            severity note;

        assert n_fail = 0
            report integer'image(n_fail) & " outputs differ from the model"
            severity failure;
        report "cutoff " & real'image(g_cutoff_hz) & " Hz, Q " & real'image(g_q) & ": "
               & integer'image(n_out) & " outputs checked bit for bit. ALL TESTS PASSED"
            severity note;
        sim_done <= true;
        wait;

    end process stimulus;

end architecture sim;
