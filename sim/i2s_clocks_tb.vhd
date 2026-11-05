-- Self-checking testbench for i2s_clocks.
--
-- The testbench keeps its own count of clocks since reset (n, 0 .. 2047) and
-- works out every expected output from it with integer maths, not from
-- counter bits, so it does not copy the design. Outputs are sampled mid-clock
-- (falling edge of clk), clear of the rising edge where the counter changes.
--
--   1. Every clock: mclk, sclk, lrck and the three strobes match the model.
--   2. Strobe timing: each strobe is high on the clock just BEFORE its edge,
--      and every edge has its strobe (sclk_rise -> sclk 0->1,
--      sclk_fall -> sclk 1->0, frame_start -> lrck 1->0, the new frame).
--   3. I2S rule: lrck only changes where sclk falls.
--   4. Frequencies: measured periods of mclk, sclk and lrck are exactly
--      8, 32 and 2048 clocks (12.288 MHz, 3.072 MHz, 48 kHz at 98.304 MHz).
--   5. Per frame: 64 sclk_rise, 64 sclk_fall, 1 frame_start.
--   6. Reset part-way through a frame: back to count 0, then runs normally.
--
-- Clock: 10.172 ns (98.31 MHz). The ideal 98.304 MHz period, 10.1725 ns,
-- is not a whole number of ps (xsim's time step); the half period must be
-- whole ps too, so the period is even. The test checks periods in clocks,
-- so the exact value does not matter.
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/i2s_clocks.vhd sim/i2s_clocks_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP i2s_clocks_tb
-- Vivado: set i2s_clocks_tb as the simulation top, Run Behavioral Simulation.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity i2s_clocks_tb is
end entity i2s_clocks_tb;

architecture sim of i2s_clocks_tb is

    constant clk_period : time    := 10172 ps; -- ~98.31 MHz (even, so /2 is exact)
    constant c_frame    : natural := 2048;     -- clocks per LRCK period (one sample)

    signal clk         : std_logic := '0';
    signal reset       : std_logic := '1';
    signal mclk        : std_logic;
    signal sclk        : std_logic;
    signal lrck        : std_logic;
    signal sclk_rise   : std_logic;
    signal sclk_fall   : std_logic;
    signal frame_start : std_logic;

    signal sim_done : boolean := false;

    -- '1' if (n / div) is odd: the square wave a divide-by-(2*div) makes.

    function square (
        n : natural;
        div : positive
    ) return std_logic is
    begin

        if ((n / div) mod 2 = 1) then
            return '1';
        else
            return '0';
        end if;

    end function square;

    function to_sl (
        b : boolean
    ) return std_logic is
    begin

        if (b) then
            return '1';
        else
            return '0';
        end if;

    end function to_sl;

begin

    clk <= not clk after clk_period / 2;

    dut : entity work.i2s_clocks
        port map (
            clk         => clk,
            reset       => reset,
            mclk        => mclk,
            sclk        => sclk,
            lrck        => lrck,
            sclk_rise   => sclk_rise,
            sclk_fall   => sclk_fall,
            frame_start => frame_start
        );

    -- Reset for a few clocks, run 2.5 frames, reset again in the middle of a
    -- frame, then run 2 more frames.
    stimulus : process is
    begin

        reset <= '1';

        for i in 1 to 4 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';

        for i in 1 to 2 * c_frame + c_frame / 2 + 123 loop

            wait until rising_edge(clk);

        end loop;

        report "reset part-way through a frame"
            severity note;
        reset <= '1';

        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';

        for i in 1 to 2 * c_frame + 10 loop

            wait until rising_edge(clk);

        end loop;

        wait;

    end process stimulus;

    -- Checks 1, 2, 3 and 5, every clock.
    checker : process is

        variable n       : natural := 0; -- expected counter value this clock
        variable first   : boolean := true;
        variable checked : natural := 0;

        -- Values one clock ago (to see edges).
        variable p_sclk, p_lrck : std_logic;
        variable p_rise         : std_logic;
        variable p_fall         : std_logic;
        variable p_frame        : std_logic;
        variable p_reset        : std_logic;

        -- Strobe counts in the current frame (between two frame_starts).
        variable n_rise   : natural := 0;
        variable n_fall   : natural := 0;
        variable n_frame  : natural := 0;
        variable in_frame : boolean := false;
        variable frames   : natural := 0;

        procedure check (
            constant name : in string;
            constant got  : in std_logic;
            constant exp  : in std_logic
        ) is
        begin

            assert got = exp
                report name & " wrong at count " & integer'image(n) & ": expected "
                       & std_logic'image(exp) & ", got " & std_logic'image(got)
                severity failure;

        end procedure check;

    begin

        wait until falling_edge(clk);

        -- 1. Every output against the model.
        check("mclk",        mclk,        square(n, 4));
        check("sclk",        sclk,        square(n, 16));
        check("lrck",        lrck,        square(n, 1024));
        check("sclk_rise",   sclk_rise,   to_sl(n mod 32 = 15));
        check("sclk_fall",   sclk_fall,   to_sl(n mod 32 = 31));
        check("frame_start", frame_start, to_sl(n = c_frame - 1));
        checked := checked + 1;

        -- 2. and 3. Edges against last clock's strobes. Skipped on the clock
        -- after a reset, where the counter jumps instead of counting.
        if (not first and p_reset = '0') then
            if (p_rise = '1') then
                assert p_sclk = '0' and sclk = '1'
                    report "sclk_rise was high but sclk did not rise on the next clock"
                    severity failure;
            end if;

            if (p_sclk = '0' and sclk = '1') then
                assert p_rise = '1'
                    report "sclk rose without sclk_rise the clock before"
                    severity failure;
            end if;

            if (p_fall = '1') then
                assert p_sclk = '1' and sclk = '0'
                    report "sclk_fall was high but sclk did not fall on the next clock"
                    severity failure;
            end if;

            if (p_sclk = '1' and sclk = '0') then
                assert p_fall = '1'
                    report "sclk fell without sclk_fall the clock before"
                    severity failure;
            end if;

            if (p_frame = '1') then
                assert p_lrck = '1' and lrck = '0'
                    report "frame_start was high but lrck did not fall (new frame) on the next clock"
                    severity failure;
            end if;

            if (p_lrck = '1' and lrck = '0') then
                assert p_frame = '1'
                    report "lrck fell (new frame) without frame_start the clock before"
                    severity failure;
            end if;

            if (lrck /= p_lrck) then
                assert p_sclk = '1' and sclk = '0'
                    report "I2S: lrck changed where sclk did not fall"
                    severity failure;
            end if;
        end if;

        -- 5. Strobes per frame. A frame starts on the clock after
        -- frame_start; a reset abandons the frame being counted.
        if (reset = '1') then
            in_frame := false;
        elsif (first or p_reset = '1' or p_frame = '1') then
            if (in_frame and p_frame = '1') then
                assert n_rise = 64 and n_fall = 64 and n_frame = 1
                    report "per frame: expected 64 / 64 / 1 sclk_rise / sclk_fall / frame_start, got "
                           & integer'image(n_rise) & " / " & integer'image(n_fall)
                           & " / " & integer'image(n_frame)
                    severity failure;
                frames := frames + 1;
            end if;
            -- A whole frame starts at count 0 (after frame_start or reset).
            in_frame := (n = 0);
            n_rise   := 0;
            n_fall   := 0;
            n_frame  := 0;
        end if;

        if (sclk_rise = '1') then
            n_rise := n_rise + 1;
        end if;

        if (sclk_fall = '1') then
            n_fall := n_fall + 1;
        end if;

        if (frame_start = '1') then
            n_frame := n_frame + 1;
        end if;

        -- Remember this clock, then work out next clock's count. reset only
        -- changes just after a rising edge, so the value seen now is the one
        -- the design sees at the next rising edge.
        p_sclk  := sclk;
        p_lrck  := lrck;
        p_rise  := sclk_rise;
        p_fall  := sclk_fall;
        p_frame := frame_start;
        p_reset := reset;
        first   := false;

        if (reset = '1') then
            n := 0;
        else
            n := (n + 1) mod c_frame;
        end if;

        if (sim_done) then
            assert frames >= 3
                report "per-frame check ran on only " & integer'image(frames) & " frame(s)"
                severity failure;
            report "every-clock checks: " & integer'image(checked) & " clocks; "
                   & "per-frame checks: " & integer'image(frames) & " frames"
                severity note;
            wait;
        end if;

    end process checker;

    -- 4. Periods, measured in clocks between rising edges. Starts after the
    -- first reset and stops at the second, so the counts are clean.
    periods : process is

        variable t0     : time;
        variable got_ns : real;

        procedure measure (
            signal   s      : in std_logic;
            constant name   : in string;
            constant clocks : in positive;
            constant mhz    : in real
        ) is
        begin

            wait until rising_edge(s);
            t0     := now;
            wait until rising_edge(s);
            assert now - t0 = clocks * clk_period
                report name & " period: expected " & integer'image(clocks) & " clocks, got "
                       & time'image(now - t0)
                severity failure;
            got_ns := real((now - t0) / 1 ps) / 1000.0;
            report name & " period = " & integer'image(clocks) & " clocks = "
                   & real'image(got_ns) & " ns (" & real'image(mhz)
                   & " MHz at 98.304 MHz)"
                severity note;

        end procedure measure;

    begin

        wait until falling_edge(reset);
        measure(mclk, "mclk", 8,    12.288);
        measure(sclk, "sclk", 32,   3.072);
        measure(lrck, "lrck", 2048, 0.048);
        wait;

    end process periods;

    -- Ends the run once the stimulus is done.
    end_run : process is
    begin

        wait until falling_edge(reset);
        wait until falling_edge(reset);

        for i in 1 to 2 * c_frame + 5 loop

            wait until rising_edge(clk);

        end loop;

        sim_done <= true;
        wait until falling_edge(clk);
        wait until falling_edge(clk);
        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process end_run;

end architecture sim;
