-- Loopback testbench: ADC model -> i2s_rx -> i2s_tx -> DAC model.
--
-- The three I2S blocks wired as the top level will wire them, with no
-- effects in between (i2s_rx's sample_out straight into i2s_tx's
-- sample_in): what goes into the ADC must come out of the DAC unchanged,
-- in both slots, exactly one frame later.
--
--   ADC model (CS5343, as in i2s_rx_tb): drives sdout 20 ns after each sclk
--     falling edge. Left slot = the next test sample; delay bit = NOT b23,
--     padding 1010..., right slot = the complement, so any slip shows.
--   i2s_rx: sample ready at k = 24 of the left slot.
--   i2s_tx: catches it, sends it from the next frame_start.
--   DAC model (CS4344, as in i2s_tx_tb): reads sdin on sclk rising edges,
--     rebuilds the left and right words of each frame.
--
-- Checks, every frame from frame 1 on:
--   1. DAC left = DAC right = the sample the ADC sent in the frame before
--      (one frame of latency, no more, no less; nothing dropped/repeated).
--   2. Enough frames were checked.
-- Samples: edge cases (0, +-1, max, min, 0x555555, 0xAAAAAA, +-0.5) then a
-- coarse sine wave, so the sequence changes every frame.
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/i2s_clocks.vhd rtl/i2s_rx.vhd rtl/i2s_tx.vhd sim/i2s_loopback_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP i2s_loopback_tb
-- Vivado: set i2s_loopback_tb as the simulation top, Run Behavioral Simulation.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity i2s_loopback_tb is
end entity i2s_loopback_tb;

architecture sim of i2s_loopback_tb is

    constant clk_period : time    := 10172 ps; -- ~98.304 MHz, even ps
    constant c_adc_dly  : time    := 20 ns;    -- ADC output delay after sclk falls
    constant c_edges    : natural := 11;       -- edge-case samples first
    constant c_frames   : natural := 40;       -- frames to run

    type t_ints is array (natural range <>) of integer;

    constant c_edge_samples : t_ints(0 to c_edges - 1) :=
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
        -(2 ** 22)            -- -0.5
    );

    -- Test sample n: the edge cases, then a sine with a 16-frame period at
    -- 0.9 of full scale.

    function test_sample (
        n : natural
    ) return integer is
    begin

        if (n < c_edges) then
            return c_edge_samples(n);
        else
            return integer(round(0.9 * real(2 ** 23 - 1) * sin(2.0 * math_pi * real(n - c_edges) / 16.0)));
        end if;

    end function test_sample;

    signal clk         : std_logic := '0';
    signal reset       : std_logic := '1';
    signal mclk        : std_logic;
    signal sclk        : std_logic;
    signal lrck        : std_logic;
    signal sclk_rise   : std_logic;
    signal sclk_fall   : std_logic;
    signal frame_start : std_logic;
    signal sdout       : std_logic := '0'; -- ADC -> FPGA
    signal sdin        : std_logic;        -- FPGA -> DAC

    -- i2s_rx -> i2s_tx, as in the top level (no effects yet).
    signal sample       : signed(23 downto 0);
    signal sample_valid : std_logic;

    -- What the ADC model sent, by frame.

    type t_sent is array (0 to c_frames + 1) of integer;

    signal sent      : t_sent  := (others => 0);
    signal adc_frame : integer := -1; -- frames started by the ADC model

    signal frames_checked : natural := 0;

begin

    clk <= not clk after clk_period / 2;

    clocks : entity work.i2s_clocks
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

    rx : entity work.i2s_rx
        port map (
            clk              => clk,
            reset            => reset,
            sdout            => sdout,
            sclk_rise        => sclk_rise,
            frame_start      => frame_start,
            sample_out       => sample,
            sample_out_valid => sample_valid
        );

    tx : entity work.i2s_tx
        port map (
            clk             => clk,
            reset           => reset,
            sample_in       => sample,
            sample_in_valid => sample_valid,
            sclk_fall       => sclk_fall,
            frame_start     => frame_start,
            sdin            => sdin
        );

    reset_proc : process is
    begin

        for i in 1 to 4 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';
        wait;

    end process reset_proc;

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

        if (lrck /= p_lrck) then
            j := 0;
            if (lrck = '0') then
                -- New frame, left slot: the next test sample.
                left := to_signed(test_sample(n), 24);
                if (n <= c_frames + 1) then
                    sent(n) <= test_sample(n);
                end if;
                n         := n + 1;
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
            bit_v := '0';
        elsif (j = 0) then
            bit_v := not word(23);                     -- delay bit
        elsif (j <= 24) then
            bit_v := word(24 - j);                     -- b23 .. b0
        elsif (j mod 2 = 1) then
            bit_v := '1';                              -- padding 1010...
        else
            bit_v := '0';
        end if;

        sdout <= bit_v after c_adc_dly;

    end process adc;

    -- CS4344 model: reads sdin on sclk rising edges; at the end of each
    -- frame's right slot, checks both words against what the ADC sent one
    -- frame earlier.
    dac : process is

        variable p_lrck : std_logic := '0';
        variable k      : integer   := -1;
        variable word   : signed(23 downto 0);
        variable left   : signed(23 downto 0);
        variable got_l  : boolean   := false;
        variable exp    : integer;

    begin

        wait until rising_edge(sclk);

        if (lrck /= p_lrck) then
            k := 0;
            if (lrck = '0') then
                got_l := false;
            end if;
        elsif (k >= 0) then
            k := k + 1;
        end if;

        p_lrck := lrck;

        if (k >= 1 and k <= 24) then
            word(24 - k) := sdin;
        end if;

        if (k = 24 and lrck = '0') then
            left  := word;
            got_l := true;
        end if;

        -- adc_frame is the frame being played now; it carries the sample
        -- the ADC sent in frame adc_frame - 1.
        if (k = 24 and lrck = '1' and got_l and adc_frame >= 1) then
            exp            := sent(adc_frame - 1);
            assert to_integer(left) = exp and to_integer(word) = exp
                report "frame " & integer'image(adc_frame) & ": DAC left = "
                       & integer'image(to_integer(left)) & ", right = "
                       & integer'image(to_integer(word)) & ", expected "
                       & integer'image(exp) & " (ADC sample from frame "
                       & integer'image(adc_frame - 1) & ")"
                severity failure;
            frames_checked <= frames_checked + 1;
        end if;

    end process dac;

    end_run : process is
    begin

        wait until adc_frame = c_frames;
        wait until rising_edge(clk);
        assert frames_checked >= c_frames - 2
            report "only " & integer'image(frames_checked) & " frames checked"
            severity failure;
        report integer'image(frames_checked)
               & " frames: DAC left = right = ADC sample from the frame before"
            severity note;
        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process end_run;

end architecture sim;
