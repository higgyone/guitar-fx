-- Self-checking testbench for i2s_rx, with i2s_clocks making the real
-- strobes and a model of the CS5343 ADC driving sdout.
--
-- ADC model (CS5343 in slave mode, I2S format): watches the sclk and lrck
-- pins from i2s_clocks. On every sclk falling edge it puts the next bit on
-- sdout, 20 ns later (output delay). Each 32-bit slot is:
--   bit 0      the I2S delay bit: sent as NOT b23, so a receiver that
--              shifts it in as part of the sample gets the wrong value
--   bits 1-24  the sample, b23 (MSB) first
--   bits 25-31 padding: alternating 1/0, so it must be ignored
-- Left slot: the next value from c_samples. Right slot: its complement, so
-- a receiver that reads the right slot gets the wrong value.
--
-- Checks:
--   1. Every sample_out_valid: sample_out = the left sample the ADC sent in
--      this frame (edge cases: 0, +1, -1, max, min, 0x555555, 0xAAAAAA, ...).
--   2. sample_out_valid is exactly one clock wide, measured in time (so a
--      pulse that ends at a falling clk edge, half a clock, is caught too).
--   3. Exactly one valid per whole frame; none in a frame where the
--      receiver was reset part-way (no garbage sample).
--   4. sample_out holds its value between valids.
--   5. Enough samples were checked (the test really ran).
--
-- Reset: i2s_clocks and i2s_rx are reset together at the start. Later, only
-- i2s_rx is reset in the middle of a left slot, with the clocks running.
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/i2s_clocks.vhd rtl/i2s_rx.vhd sim/i2s_rx_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP i2s_rx_tb
-- Vivado: set i2s_rx_tb as the simulation top, Run Behavioral Simulation.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity i2s_rx_tb is
end entity i2s_rx_tb;

architecture sim of i2s_rx_tb is

    constant clk_period : time    := 10172 ps; -- ~98.304 MHz, even ps
    constant c_frame    : natural := 2048;     -- clocks per frame
    constant c_frames   : natural := 14;       -- frames to run
    constant c_adc_dly  : time    := 20 ns;    -- ADC output delay after sclk falls

    type t_samples is array (natural range <>) of integer;

    constant c_samples : t_samples :=
    (
        0,
        1,
        -1,
        2 ** 23 - 1,          -- max positive
        -(2 ** 23),           -- min negative
        16#555555#,
        16#2AAAAA# - 2 ** 23, -- 0xAAAAAA as a signed 24-bit value
        16#123456#,
        -16#123456#,
        2 ** 22,              -- 0.5
        -(2 ** 22),           -- -0.5
        12345,
        -54321
    );

    signal clk              : std_logic := '0';
    signal clk_reset        : std_logic := '1';
    signal rx_reset         : std_logic := '1';
    signal mclk             : std_logic;
    signal sclk             : std_logic;
    signal lrck             : std_logic;
    signal sclk_rise        : std_logic;
    signal sclk_fall        : std_logic;
    signal frame_start      : std_logic;
    signal sdout            : std_logic := '0';
    signal sample_out       : signed(23 downto 0);
    signal sample_out_valid : std_logic;

    -- What the ADC model is sending in the current frame.
    signal adc_left  : signed(23 downto 0) := (others => '0');
    signal adc_frame : integer             := -1; -- frames started by the ADC model

    signal sim_done : boolean := false;

begin

    clk <= not clk after clk_period / 2;

    clocks : entity work.i2s_clocks
        port map (
            clk         => clk,
            reset       => clk_reset,
            mclk        => mclk,
            sclk        => sclk,
            lrck        => lrck,
            sclk_rise   => sclk_rise,
            sclk_fall   => sclk_fall,
            frame_start => frame_start
        );

    dut : entity work.i2s_rx
        port map (
            clk              => clk,
            reset            => rx_reset,
            sdout            => sdout,
            sclk_rise        => sclk_rise,
            frame_start      => frame_start,
            sample_out       => sample_out,
            sample_out_valid => sample_out_valid
        );

    -- CS5343 model: a new bit after every sclk falling edge.
    adc : process is

        variable p_lrck : std_logic           := '0';
        variable j      : integer             := -1; -- bit position in the slot, -1 = not started
        variable left   : signed(23 downto 0) := (others => '0');
        variable word   : signed(23 downto 0);
        variable bit_v  : std_logic;
        variable n      : natural             := 0;

    begin

        wait until falling_edge(sclk);

        -- lrck changes on the same edge as sclk falls: a new slot.
        if (lrck /= p_lrck) then
            j := 0;
            if (lrck = '0') then
                -- New frame, left slot: take the next test value.
                left      := to_signed(c_samples(n mod c_samples'length), 24);
                n         := n + 1;
                adc_left  <= left;
                adc_frame <= adc_frame + 1;
            end if;
        elsif (j >= 0) then
            j := j + 1;
        end if;

        p_lrck := lrck;

        if (lrck = '0') then
            word := left;
        else
            word := not left;
        end if;

        if (j < 0) then
            bit_v := '0';                                                      -- before the first slot
        elsif (j = 0) then
            bit_v := not word(23);                                             -- delay bit
        elsif (j <= 24) then
            bit_v := word(24 - j);                                             -- b23 .. b0
        else
            if (j mod 2 = 1) then                                              -- padding 1010...
                bit_v := '1';
            else
                bit_v := '0';
            end if;
        end if;

        sdout <= bit_v after c_adc_dly;

    end process adc;

    stimulus : process is
    begin

        clk_reset <= '1';
        rx_reset  <= '1';

        for i in 1 to 4 loop

            wait until rising_edge(clk);

        end loop;

        clk_reset <= '0';
        rx_reset  <= '0';

        -- Reset only the receiver in the middle of frame 6's left slot
        -- (between bit 10 and bit 11), with the clocks running.
        wait until adc_frame = 6;

        for i in 1 to 10 * 32 + 20 loop

            wait until rising_edge(clk);

        end loop;

        report "resetting i2s_rx in the middle of a left slot"
            severity note;
        rx_reset <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        rx_reset <= '0';

        wait until adc_frame = c_frames;
        wait until rising_edge(clk);
        sim_done <= true;
        wait;

    end process stimulus;

    checker : process is

        variable p_valid    : std_logic := '0';
        variable p_lrck     : std_logic := '0';
        variable p_out      : signed(23 downto 0);
        variable have_out   : boolean   := false;
        variable in_frame   : natural   := 0;     -- valids in this frame
        variable frame_ok   : boolean   := false; -- receiver out of reset all frame
        variable checked    : natural   := 0;
        variable frames_ok  : natural   := 0;
        variable frames_bad : natural   := 0;

    begin

        wait until rising_edge(clk);

        -- 3. At the start of each frame (lrck falling), the frame that just
        -- ended must have had exactly one valid if it was whole, none if
        -- the receiver was reset during it.
        if (p_lrck = '1' and lrck = '0') then
            if (frame_ok) then
                assert in_frame = 1
                    report "frame " & integer'image(adc_frame - 1) & ": expected 1 sample_out_valid, got "
                           & integer'image(in_frame)
                    severity failure;
                frames_ok := frames_ok + 1;
            elsif (adc_frame >= 1) then
                assert in_frame = 0
                    report "frame " & integer'image(adc_frame - 1)
                           & " (receiver reset part-way): expected no sample_out_valid, got "
                           & integer'image(in_frame)
                    severity failure;
                frames_bad := frames_bad + 1;
            end if;
            in_frame := 0;
            frame_ok := (rx_reset = '0');
        end if;

        if (rx_reset = '1') then
            frame_ok := false;
            have_out := false; -- the design may clear sample_out on reset
        end if;

        if (sample_out_valid = '1') then
            -- 2. One clock wide.
            assert p_valid = '0'
                report "sample_out_valid high for more than one clock"
                severity failure;

            -- 1. The right value.
            assert sample_out = adc_left
                report "frame " & integer'image(adc_frame) & ": sample_out = "
                       & integer'image(to_integer(sample_out)) & ", expected "
                       & integer'image(to_integer(adc_left))
                severity failure;

            in_frame := in_frame + 1;
            checked  := checked + 1;
            p_out    := sample_out;
            have_out := true;
        elsif (have_out) then
            -- 4. Holds between valids.
            assert sample_out = p_out
                report "sample_out changed without sample_out_valid"
                severity failure;
        end if;

        p_valid := sample_out_valid;
        p_lrck  := lrck;

        if (sim_done) then
            -- 5. Coverage.
            assert checked >= c_frames - 3 and frames_bad = 1
                report "too few checks: " & integer'image(checked) & " samples, "
                       & integer'image(frames_bad) & " reset frame(s)"
                severity failure;
            report integer'image(checked) & " samples checked over "
                   & integer'image(frames_ok) & " whole frames; "
                   & integer'image(frames_bad) & " frame with a mid-frame reset gave no sample"
                severity note;
            report "ALL TESTS PASSED"
                severity note;
            std.env.finish;
        end if;

    end process checker;

    -- 2. Pulse width of sample_out_valid, in time.
    valid_width : process is

        variable t_up : time;

    begin

        wait until rising_edge(sample_out_valid);
        t_up := now;
        wait until falling_edge(sample_out_valid);
        assert now - t_up = clk_period
            report "sample_out_valid was high for " & time'image(now - t_up)
                   & ", expected one clock (" & time'image(clk_period) & ")"
            severity failure;

    end process valid_width;

end architecture sim;
