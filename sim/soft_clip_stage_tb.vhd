-- Self-checking testbench for soft_clip_stage.
--
-- Each test sends one sample (one-clock sample_in_valid pulse), waits for
-- sample_out_valid, and compares sample_out with the expected value.
-- Latency-tolerant (any pipeline depth up to timeout_cycles); reports the
-- measured latency.
--
-- Expected value, worked out here from the definition, not from the DUT:
--   |x| = x for x >= 0, (not x) for x < 0
--         (not x = -x - 1: never overflows, so -1.0 is fine)
--   a = bits 22..13 of |x| (table entry), f = bits 12..0 (how far to a+1)
--   T(i) = round(tanh(k * i / 1024) / tanh(k) * (2**23 - 1)), i = 0 .. 1024
--   t = T(a) + floor((T(a+1) - T(a)) * f / 8192)    (linear interpolation)
--   expected = t for x >= 0, (not t) = -t - 1 for x < 0
--
-- Test groups:
--   1. Spot values: zero, small, mid, full scale, -1.0; low bits now
--      matter (same entry, bigger f, bigger output); inputs below one
--      table step are no longer zero (no dead zone).
--   2. Every one of the 1024 table entries, positive and negative, with
--      changing low bits.
--   3. Shape: odd symmetry (out(not x) = not out(x)), monotonic over the
--      sweep, the top is full scale, and small inputs are boosted by about
--      k / tanh(k) (the curve's slope at zero).
--   4. sample_out holds between samples; reset clears it.
--
-- Run (repo root, PowerShell, GHDL):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/soft_clip_stage.vhd sim/soft_clip_stage_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP soft_clip_stage_tb
-- Or xsim: xvhdl -2008 (both files) -> xelab soft_clip_stage_tb -> xsim -R

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity soft_clip_stage_tb is
end entity soft_clip_stage_tb;

architecture sim of soft_clip_stage_tb is

    constant clk_period     : time    := 10 ns; -- 100 MHz
    constant timeout_cycles : natural := 20;    -- max latency accepted
    constant c_drive        : real    := 3.0;   -- k, passed to the DUT

    constant sample_max : integer := 2 ** 23 - 1;
    constant sample_min : integer := -(2 ** 23);

    -- Table entry a (0 .. 1024) from the definition.

    function entry (
        a : natural
    ) return integer is
    begin

        return integer(round(tanh(c_drive * real(a) / 1024.0) / tanh(c_drive) * real(sample_max)));

    end function entry;

    -- Expected output for input x.

    function expected_out (
        x : integer
    ) return integer is

        variable xs  : signed(23 downto 0);
        variable mag : signed(23 downto 0);
        variable a   : natural;
        variable f   : natural;
        variable t   : integer;

    begin

        xs := to_signed(x, 24);

        if (x >= 0) then
            mag := xs;
        else
            mag := not xs;
        end if;

        a := to_integer(unsigned(mag(22 downto 13)));
        f := to_integer(unsigned(mag(12 downto 0)));
        -- The gap is never negative, so integer "/" (rounds toward zero)
        -- is the same as floor, i.e. dropping the bottom 13 bits.
        t := entry(a) + ((entry(a + 1) - entry(a)) * f) / 8192;

        if (x >= 0) then
            return t;
        else
            return -t - 1;
        end if;

    end function expected_out;

    signal clk              : std_logic           := '0';
    signal reset            : std_logic           := '1';
    signal sample_in        : signed(23 downto 0) := (others => '0');
    signal sample_in_valid  : std_logic           := '0';
    signal sample_out       : signed(23 downto 0);
    signal sample_out_valid : std_logic;

begin

    clk <= not clk after clk_period / 2;

    dut : entity work.soft_clip_stage
        generic map (
            g_drive => c_drive
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

        variable n_checks : natural := 0;

        -- Sends sample x, waits for the output, checks it against
        -- expected_out(x), and returns what the DUT gave.

        procedure send (
            constant name : in string;
            constant x    : in integer;
            variable got  : out integer
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
                    report name & ": no sample_out_valid within "
                           & integer'image(timeout_cycles) & " clocks"
                    severity failure;

            end loop;

            got      := to_integer(sample_out);
            assert got = expected_out(x)
                report name & ": input " & integer'image(x) & ", expected "
                       & integer'image(expected_out(x)) & ", got " & integer'image(got)
                severity failure;
            n_checks := n_checks + 1;

            wait until rising_edge(clk);
            assert sample_out_valid = '0'
                report name & ": sample_out_valid longer than one clock"
                severity failure;

            for i in 1 to 2 loop

                wait until rising_edge(clk);

            end loop;

        end procedure send;

        variable got   : integer;
        variable got_n : integer;
        variable prev  : integer;
        variable x     : integer;

    begin

        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';

        -- Group 1: spot values.
        send("zero", 0, got);
        assert got = 0
            report "zero: output not 0"
            severity failure;
        send("one LSB", 1, got);
        send("minus one LSB", -1, got);                                                      -- not(-1) = 0: address 0, output not 0 = -1
        send("small +", 2 ** 18, got);
        send("small -", -(2 ** 18), got);
        send("mid +", 2 ** 22, got);
        send("mid -", -(2 ** 22), got);
        -- Full scale interpolates almost all the way to entry 1024 (exactly
        -- 2**23 - 1), so it is within one LSB-ish of full scale.
        send("full scale +", sample_max, got);
        assert real(got) > 0.99999 * real(sample_max)
            report "full scale +: not near full scale, got " & integer'image(got)
            severity failure;
        send("-1.0", sample_min, got_n);
        assert got_n = -got - 1
            report "-1.0: expected not(full scale +), got " & integer'image(got_n)
            severity failure;
        send("low bits matter a", 300 * 2 ** 13, got);
        send("low bits matter b", 300 * 2 ** 13 + 2 ** 13 - 1, got_n);
        assert got_n > got
            report "low bits matter: bigger f did not give a bigger output"
            severity failure;
        assert got = entry(300)
            report "low bits matter: f = 0 should give exactly entry 300"
            severity failure;
        -- Below one table step (2**13): the old staircase gave 0 here.
        send("no dead zone +", 1000, got);
        assert got > 0
            report "no dead zone: input 1000 gave " & integer'image(got)
            severity failure;
        send("no dead zone -", -1001, got_n);                                                -- = not 1000
        assert got_n = -got - 1
            report "no dead zone: negative side not symmetric"
            severity failure;
        report "group 1 (spot values): ok"
            severity note;

        -- Group 2 + 3: every entry, both signs, with changing low bits;
        -- odd symmetry and monotonic.
        prev := -1;

        for a in 0 to 1023 loop

            x    := a * 2 ** 13 + (a * 37) mod 2 ** 13;
            send("entry +", x, got);
            send("entry -", -x - 1, got_n);                                                  -- = not x
            assert got_n = -got - 1
                report "odd symmetry at entry " & integer'image(a) & ": out(x) = "
                       & integer'image(got) & ", out(not x) = " & integer'image(got_n)
                severity failure;
            assert got >= prev
                report "not monotonic at entry " & integer'image(a)
                severity failure;
            prev := got;

        end loop;

        report "groups 2-3 (all 1024 entries, both signs, symmetric, monotonic): ok"
            severity note;

        -- Group 3: small-signal boost ~ k / tanh(k) (curve slope at zero).
        send("boost", 16 * 2 ** 13, got);                                                    -- entry 16, x = 1/64
        assert abs (real(got) / real(16 * 2 ** 13) - c_drive / tanh(c_drive)) < 0.02
            report "small-signal gain " & real'image(real(got) / real(16 * 2 ** 13))
                   & ", expected about " & real'image(c_drive / tanh(c_drive))
            severity failure;
        report "boost: small-signal gain " & real'image(real(got) / real(16 * 2 ** 13))
            severity note;

        -- Group 4a: hold between samples.
        send("hold: set up", 2 ** 21, got);
        sample_in <= to_signed(-(2 ** 22), 24);

        for i in 1 to 10 loop

            wait until rising_edge(clk);
            assert to_integer(sample_out) = got
                report "hold: sample_out changed without sample_in_valid"
                severity failure;

        end loop;

        report "hold: ok"
            severity note;

        -- Group 4b: reset clears the output.
        reset <= '1';

        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        assert to_integer(sample_out) = 0
            report "reset: sample_out not 0, got " & integer'image(to_integer(sample_out))
            severity failure;
        assert sample_out_valid = '0'
            report "reset: valid high"
            severity failure;
        reset <= '0';
        send("after reset", -(2 ** 21), got);
        report "reset: ok"
            severity note;

        report integer'image(n_checks) & " samples checked. ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
