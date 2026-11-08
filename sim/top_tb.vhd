-- System testbench for top: the whole design, driven only through its pins.
--
-- Board model:
--   clk100mhz  100 MHz oscillator; the Clocking Wizard makes the 98.304 MHz
--              system clock from it (in Vivado's simulation the real IP model)
--   reset_btn  BTN0, pressed once in the middle of the run
--   distortion_sw  SW0 and soft_clip_sw SW1, held for the whole run, from
--              the generic g_mode:
--              0 (default) dry: SW0 '0'. The DAC must play the ADC's
--                samples bit-exact.
--              1 hard clip: SW0 '1', SW1 '0', drive x2.0, threshold 0.125
--                (c_drive, c_threshold, passed to top). expected_out(x):
--                x x drive (rounded and saturated as gain_stage does),
--                clipped to +/- threshold.
--              2 soft clip: SW0 '1', SW1 '1', k = 3.0 (c_soft_drive).
--                expected_out(x): the tanh table worked out here with
--                math_real (as soft_clip_stage_tb does), not from the DUT.
--   ADC model  CS5343 on ad_mclk / ad_lrck / ad_sclk / ad_sdout: drives sdout
--              20 ns after each ad_sclk falling edge (I2S, as in i2s_rx_tb)
--   DAC model  CS4344 on da_mclk / da_lrck / da_sclk / da_sdin: reads sdin on
--              da_sclk rising edges and rebuilds both words (as in i2s_tx_tb)
--
-- soft_start's generics are made tiny (mute 6 samples, ramp 4) so the audio
-- appears after a few frames instead of 3 s.
-- The output gain (g_gain) is set to 1.0 instead of the hardware's 1/32, so
-- the DAC must play the ADC's samples exactly (check 4).
--
-- Checks:
--   1. led_locked goes high (the MMCM locked).
--   2. The DA and AD pins carry the same clocks: da_mclk = ad_mclk,
--      da_sclk = ad_sclk, da_lrck = ad_lrck, all the time after lock.
--   3. Clock ratios: mclk = 256 x fs, sclk = 64 x fs (periods measured).
--   4. Audio: DAC left = DAC right in every frame. During mute and ramp the
--      output is no bigger than the expected output; after the ramp, the
--      DAC plays expected_out(the ADC's sample from the frame before),
--      exactly (output gain 1.0), every frame.
--   5. After the button: muted again, then exact again. The button also
--      resets i2s_clocks mid-frame, so the frame it lands in and the next
--      one are not checked.
--   6. Coverage. Hard clip: frames checked must include clipped samples
--      (+threshold and -threshold) and unclipped non-zero ones. Soft clip:
--      positive and negative outputs. So each path is exercised through
--      the real chain.
--
-- The test pattern (test_sample) mixes a 0.9 full-scale sine with +/-
-- full scale and three small values: 2**18 and -(2**18 + 12345) (x2 stays
-- under the clip) and 2**19 (x2 lands exactly on the threshold).
--
-- Run (repo root, PowerShell), Vivado: set top_tb as the simulation top,
-- Run Behavioral Simulation (Vivado compiles the Clocking Wizard's model).
-- For the other runs, set g_mode=1 (hard) or g_mode=2 (soft) in the
-- simulation settings (Generics/Parameters). xsim CLI: xelab top_tb
-- -L unisim -generic_top g_mode=2 (the .bat launcher splits "x=y", so put
-- the xelab arguments in a file and pass -f file).
-- GHDL can't simulate the Clocking Wizard IP (its model is Verilog).

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity top_tb is
    generic (
        g_mode : natural range 0 to 2 := 0 -- 0 dry, 1 hard clip, 2 soft clip
    );
end entity top_tb;

architecture sim of top_tb is

    constant c_clk100_period : time    := 10 ns;
    constant c_adc_dly       : time    := 20 ns;
    constant c_mute          : natural := 6;                             -- g_mute_samples for the test
    constant c_ramp_bits     : natural := 2;                             -- ramp = 4 samples
    constant c_gain          : integer := 2 ** 15;                       -- output gain 1.0 (Q3.15)
    constant c_settle        : natural := c_mute + 2 ** c_ramp_bits + 4; -- frames to reach pass-through
    constant c_press_at      : natural := 30;                            -- frame where the button is pressed
    constant c_frames        : natural := 60;                            -- frames to run
    constant c_drive         : integer := 2 ** 16;                       -- drive x2.0 (Q3.15)
    constant c_threshold     : integer := 2 ** 20;                       -- clip at 0.125 (Q0.23)
    constant c_soft_drive    : real    := 3.0;                           -- soft clip k

    -- Test sample n: a sine, 16 frames per cycle, 0.9 of full scale, with
    -- full-scale values and small values now and then.

    function test_sample (
        n : natural
    ) return integer is
    begin

        if (n mod 13 = 5) then
            return 2 ** 23 - 1;
        elsif (n mod 13 = 11) then
            return -(2 ** 23);
        elsif (n mod 13 = 2) then
            return 2 ** 18;            -- x2 = 0.0625: under the clip
        elsif (n mod 13 = 8) then
            return -(2 ** 18 + 12345); -- x2 under the clip, odd value
        elsif (n mod 13 = 3) then
            return 2 ** 19;            -- x2 = 0.125: exactly on the threshold
        else
            return integer(round(0.9 * real(2 ** 23 - 1) * sin(2.0 * math_pi * real(n) / 16.0)));
        end if;

    end function test_sample;

    -- Soft clip table entry a (0 .. 1023), from the definition:
    -- round(tanh(k * a / 1024) / tanh(k) * (2**23 - 1)).

    function soft_entry (
        a : natural
    ) return integer is
    begin

        return integer(round(tanh(c_soft_drive * real(a) / 1024.0) / tanh(c_soft_drive)
                             * real(2 ** 23 - 1)));

    end function soft_entry;

    -- What the DAC should play for ADC sample x. Dry: x itself.
    -- Soft clip: address = bits 22..13 of |x| (|x| = not x for x < 0), then
    -- the table entry, inverted back (not) for x < 0.
    -- Hard clip: x x c_drive the way gain_stage does it (Q1.23 x Q3.15 =
    -- Q4.38, add 2**14 to round, keep bits 38..15, saturate to Q1.23), then
    -- clipped to +/- c_threshold as hard_clip_stage does.

    function expected_out (
        x : integer
    ) return integer is

        variable p   : signed(41 downto 0);
        variable y   : integer;
        variable mag : signed(23 downto 0);
        variable a   : natural;

    begin

        if (g_mode = 0) then
            return x;
        elsif (g_mode = 2) then
            if (x >= 0) then
                mag := to_signed(x, 24);
            else
                mag := not to_signed(x, 24);
            end if;
            a := to_integer(unsigned(mag(22 downto 13)));
            if (x >= 0) then
                return soft_entry(a);
            else
                return -soft_entry(a) - 1;
            end if;
        end if;

        p := to_signed(x, 24) * to_signed(c_drive, 18) + to_signed(2 ** 14, 42);

        if (p(41 downto 38) = "0000" or p(41 downto 38) = "1111") then
            y := to_integer(p(38 downto 15));
        elsif (p(41) = '0') then
            y := 2 ** 23 - 1;
        else
            y := -(2 ** 23);
        end if;

        if (y > c_threshold) then
            return c_threshold;
        elsif (y < -c_threshold) then
            return -c_threshold;
        else
            return y;
        end if;

    end function expected_out;

    signal clk100mhz     : std_logic := '0';
    signal reset_btn     : std_logic := '0';
    signal distortion_sw : std_logic := '0'; -- SW0: set from g_mode below
    signal soft_clip_sw  : std_logic := '0'; -- SW1: set from g_mode below
    signal ad_sdout      : std_logic := '0';
    signal led_locked    : std_logic;
    signal da_mclk       : std_logic;
    signal da_lrck       : std_logic;
    signal da_sclk       : std_logic;
    signal da_sdin       : std_logic;
    signal ad_mclk       : std_logic;
    signal ad_lrck       : std_logic;
    signal ad_sclk       : std_logic;

    type t_sent is array (0 to c_frames + 2) of integer;

    signal sent      : t_sent  := (others => 0);
    signal adc_frame : integer := -1;   -- frames started by the ADC model
    signal press_at  : integer := -100; -- ADC frame in which the button was pressed

begin

    clk100mhz <= not clk100mhz after c_clk100_period / 2;

    -- The switches are held for the whole run (switching is not tested here).
    distortion_sw <= '0' when g_mode = 0 else
                     '1';
    soft_clip_sw  <= '1' when g_mode = 2 else
                     '0';

    dut : entity work.top
        generic map (
            g_mute_samples => c_mute,
            g_ramp_bits    => c_ramp_bits,
            g_gain         => c_gain,
            g_test_tone    => false,
            g_threshold    => c_threshold,
            g_drive_gain   => c_drive,
            g_soft_drive   => c_soft_drive
        )
        port map (
            clk100mhz     => clk100mhz,
            reset_btn     => reset_btn,
            distortion_sw => distortion_sw,
            soft_clip_sw  => soft_clip_sw,
            ad_sdout      => ad_sdout,
            led_locked    => led_locked,
            da_mclk       => da_mclk,
            da_lrck       => da_lrck,
            da_sclk       => da_sclk,
            da_sdin       => da_sdin,
            ad_mclk       => ad_mclk,
            ad_lrck       => ad_lrck,
            ad_sclk       => ad_sclk
        );

    -- 1. The MMCM must lock; the button is pressed at frame c_press_at.
    board : process is
    begin

        wait until led_locked = '1' for 1 ms;
        assert led_locked = '1'
            report "led_locked never went high (Clocking Wizard did not lock)"
            severity failure;
        report "MMCM locked at " & time'image(now)
            severity note;

        wait until adc_frame = c_press_at;
        wait for 3 us;
        report "pressing reset_btn"
            severity note;
        press_at  <= adc_frame;
        reset_btn <= '1';
        wait for 1 us;
        reset_btn <= '0';
        wait;

    end process board;

    -- 2. Both Pmod rows get the same clocks.
    pins : process is
    begin

        wait until led_locked = '1';

        loop

            wait on da_mclk, ad_mclk, da_sclk, ad_sclk, da_lrck, ad_lrck;
            assert da_mclk = ad_mclk and da_sclk = ad_sclk and da_lrck = ad_lrck
                report "DA and AD pins differ: mclk " & std_logic'image(da_mclk) & "/"
                       & std_logic'image(ad_mclk) & ", sclk " & std_logic'image(da_sclk)
                       & "/" & std_logic'image(ad_sclk) & ", lrck "
                       & std_logic'image(da_lrck) & "/" & std_logic'image(ad_lrck)
                severity failure;

        end loop;

    end process pins;

    -- 3. Clock ratios, measured after lock. Exact in clocks, so compare
    -- periods with a 1 ps tolerance per mclk period for rounding.
    ratios : process is

        variable t0     : time;
        variable t_mclk : time;
        variable t_sclk : time;
        variable t_lrck : time;

    begin

        wait until adc_frame = 2;
        wait until rising_edge(da_mclk);
        t0     := now;
        wait until rising_edge(da_mclk);
        t_mclk := now - t0;
        wait until rising_edge(da_sclk);
        t0     := now;
        wait until rising_edge(da_sclk);
        t_sclk := now - t0;
        wait until rising_edge(da_lrck);
        t0     := now;
        wait until rising_edge(da_lrck);
        t_lrck := now - t0;
        assert abs (t_sclk - 4 * t_mclk) <= 4 ps and abs (t_lrck - 256 * t_mclk) <= 256 ps
            report "clock ratios wrong: mclk " & time'image(t_mclk) & ", sclk "
                   & time'image(t_sclk) & ", lrck " & time'image(t_lrck)
            severity failure;
        report "fs = " & real'image(1.0e12 / real(t_lrck / 1 ps)) & " Hz, mclk = 256 x fs, sclk = 64 x fs"
            severity note;
        wait;

    end process ratios;

    -- CS5343 model on the AD row.
    adc : process is

        variable p_lrck : std_logic           := '0';
        variable j      : integer             := -1;
        variable left   : signed(23 downto 0) := (others => '0');
        variable word   : signed(23 downto 0);
        variable bit_v  : std_logic;
        variable n      : natural             := 0;

    begin

        wait until falling_edge(ad_sclk);

        if (ad_lrck /= p_lrck) then
            j := 0;
            if (ad_lrck = '0') then
                left := to_signed(test_sample(n), 24);
                if (n <= c_frames + 2) then
                    sent(n) <= test_sample(n);
                end if;
                n         := n + 1;
                adc_frame <= adc_frame + 1;
            end if;
        elsif (j >= 0) then
            j := j + 1;
        end if;

        p_lrck := ad_lrck;

        if (ad_lrck = '0') then
            word := left;
        else
            word := not left;
        end if;

        if (j < 0) then
            bit_v := '0';
        elsif (j = 0) then
            bit_v := not word(23);
        elsif (j <= 24) then
            bit_v := word(24 - j);
        elsif (j mod 2 = 1) then
            bit_v := '1';
        else
            bit_v := '0';
        end if;

        ad_sdout <= bit_v after c_adc_dly;

    end process adc;

    -- CS4344 model on the DA row, and the audio checks (4, 5).
    dac : process is

        variable p_lrck   : std_logic := '0';
        variable k        : integer   := -1;
        variable word     : signed(23 downto 0);
        variable left     : signed(23 downto 0);
        variable got_l    : boolean   := false;
        variable exp, got : integer;
        variable phase    : natural   := 0; -- 0 settling, 1 pass-through
        variable start    : integer   := 0; -- frame the current settling began
        variable n_pass   : natural   := 0;
        variable runs     : natural   := 0; -- pass-through stretches reached
        variable n_clip_p : natural   := 0; -- distortion: frames checked at +threshold
        variable n_clip_n : natural   := 0; -- distortion: frames checked at -threshold
        variable n_lin    : natural   := 0; -- distortion: unclipped non-zero frames checked

    begin

        wait until rising_edge(da_sclk);

        if (da_lrck /= p_lrck) then
            k := 0;
            if (da_lrck = '0') then
                got_l := false;
            end if;
        elsif (k >= 0) then
            k := k + 1;
        end if;

        p_lrck := da_lrck;

        if (k >= 1 and k <= 24) then
            word(24 - k) := da_sdin;
        end if;

        if (k = 24 and da_lrck = '0') then
            left  := word;
            got_l := true;
        end if;

        -- End of the right slot's data: check this frame.
        if (k = 24 and da_lrck = '1' and got_l and adc_frame >= 1) then
            got := to_integer(left);
            exp := expected_out(sent(adc_frame - 1));

            -- The button resets i2s_clocks too, so the frame it lands in and
            -- the next are cut short: skip them, and restart the settling
            -- (mute, ramp) from there.
            if (adc_frame >= press_at and adc_frame <= press_at + 1) then
                phase := 0;
                start := adc_frame;
            else
                assert to_integer(word) = got
                    report "frame " & integer'image(adc_frame) & ": left " & integer'image(got)
                           & " /= right " & integer'image(to_integer(word))
                    severity failure;

                if (phase = 0) then
                    -- Mute / ramp: never bigger than the expected output.
                    assert abs (got) <= abs (exp)
                        report "frame " & integer'image(adc_frame) & " (mute/ramp): output "
                               & integer'image(got) & " bigger than expected " & integer'image(exp)
                        severity failure;
                    if (got = exp and exp /= 0 and adc_frame - start >= c_mute) then
                        phase := 1;
                        runs  := runs + 1;
                        report "pass-through from frame " & integer'image(adc_frame)
                            severity note;
                    else
                        assert adc_frame - start <= c_settle
                            report "no pass-through " & integer'image(c_settle)
                                   & " frames after reset (mute + ramp should be over)"
                            severity failure;
                    end if;
                else
                    -- After the ramp: exactly expected_out(last frame's ADC sample).
                    assert got = exp
                        report "frame " & integer'image(adc_frame) & ": DAC " & integer'image(got)
                               & ", expected " & integer'image(exp) & " (ADC sample "
                               & integer'image(sent(adc_frame - 1)) & " from frame "
                               & integer'image(adc_frame - 1) & ")"
                        severity failure;
                    n_pass := n_pass + 1;
                    if (g_mode = 2) then
                        if (exp > 0) then
                            n_clip_p := n_clip_p + 1;                                                     -- soft: positive outputs
                        elsif (exp < 0) then
                            n_clip_n := n_clip_n + 1;                                                     -- soft: negative outputs
                        end if;
                    elsif (exp = c_threshold) then
                        n_clip_p := n_clip_p + 1;
                    elsif (exp = -c_threshold) then
                        n_clip_n := n_clip_n + 1;
                    elsif (exp /= 0) then
                        n_lin := n_lin + 1;
                    end if;
                end if;
            end if;
        end if;

        if (adc_frame = c_frames and k = 25 and da_lrck = '1') then
            assert runs = 2 and n_pass >= c_frames - 2 * c_settle - 4
                report "coverage: " & integer'image(runs) & " pass-through stretch(es), "
                       & integer'image(n_pass) & " frames checked"
                severity failure;
            if (g_mode = 2) then
                -- 6. Soft clip: both signs exercised.
                assert n_clip_p > 0 and n_clip_n > 0
                    report "soft clip coverage: " & integer'image(n_clip_p) & " positive, "
                           & integer'image(n_clip_n) & " negative"
                    severity failure;
                report "SOFT CLIP run: " & integer'image(n_pass) & " frames exact, in "
                       & integer'image(runs) & " stretches; " & integer'image(n_clip_p)
                       & " positive, " & integer'image(n_clip_n) & " negative"
                    severity note;
            elsif (g_mode = 1) then
                -- 6. Hard clip: both sides of the clip exercised.
                assert n_clip_p > 0 and n_clip_n > 0 and n_lin > 0
                    report "distortion coverage: " & integer'image(n_clip_p) & " at +threshold, "
                           & integer'image(n_clip_n) & " at -threshold, "
                           & integer'image(n_lin) & " unclipped"
                    severity failure;
                report "HARD CLIP run: " & integer'image(n_pass) & " frames exact, in "
                       & integer'image(runs) & " stretches; " & integer'image(n_clip_p)
                       & " at +threshold, " & integer'image(n_clip_n) & " at -threshold, "
                       & integer'image(n_lin) & " unclipped non-zero"
                    severity note;
            else
                report "DRY run: " & integer'image(n_pass) & " frames of exact pass-through checked, in "
                       & integer'image(runs) & " stretches (before and after the button)"
                    severity note;
            end if;
            report "ALL TESTS PASSED"
                severity note;
            std.env.finish;
        end if;

    end process dac;

end architecture sim;
