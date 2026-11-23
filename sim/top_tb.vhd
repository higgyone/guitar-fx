-- System testbench for top: the whole design, driven only through its pins.
--
-- Board model:
--   clk100mhz  100 MHz oscillator; the Clocking Wizard makes the 98.304 MHz
--              system clock from it (in Vivado's simulation the real IP model)
--   reset_btn  BTN0, pressed once in the middle of the run
--   distortion_sw SW0, soft_clip_sw SW1, tremolo_sw SW2 and tone_sw SW3,
--              held for the whole run, from the generic g_mode:
--              0 (default) dry: SW0 '0'. The DAC must play the ADC's
--                samples bit-exact.
--              1 hard clip: SW0 '1', SW1 '0', drive x2.0, threshold 0.125
--                (c_drive, c_threshold, passed to top). expected_out(x):
--                x x drive (rounded and saturated as gain_stage does),
--                clipped to +/- threshold.
--              2 soft clip: SW0 '1', SW1 '1', k = 3.0 (c_soft_drive).
--                expected_out(x): the tanh table worked out here with
--                math_real (as soft_clip_stage_tb does), not from the DUT.
--              3 tremolo: SW0 '0' (dry), SW2 '1', rate 150 Hz (320 frames
--                per LFO cycle; register 0x05 tops out at 187 Hz), depth
--                0.5. The LFO phase isn't modelled, so the check is the
--                envelope: |out| between (1 - depth) x |dry| and |dry|.
--                Before the button the PC has written depth 0 (check 7),
--                so the DAC must play the dry sample exactly; the button
--                resets ctrl_regs, depth goes back to 0.5, and the second
--                stretch must dip.
--              4 tone filter: SW0 '0' (dry), SW3 '1', 3 kHz, Q 0.707. A
--                filter has memory, so expected_out(x) can't say what one
--                sample becomes. Instead tone_model watches the filter's
--                real input inside top (s_mod_sample, via VHDL-2008
--                external names), runs the bit-exact model on it (as
--                tone_stage_tb, from the maths), checks tone_filter's
--                output bit for bit in place, and records the filtered
--                value of each ADC frame's sample; the DAC must then play
--                exactly that value.
--              SW2 and SW3 are '0' in the other modes, so those still check
--              exact output.
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
--      positive and negative outputs. Tremolo: exact frames at depth 0
--      (before the button) and dipped ones (after). Tone filter: outputs that differ
--      from the dry sample, and every filter output checked in place. So
--      each path is exercised through the real chain.
--   7. UART commands (g_uart_clks_per_bit 16), through uart, cmd_decoder
--      and ctrl_regs: soon after lock the PC model sends, back-to-back:
--      read version (0xFF) -> ACK 0x00 0x02; read live state (0x90) -> ACK
--      + SW3 in bit 8, the effects and switches in bits 0..6 (effects =
--      switches, since the PC has not taken control); read an unknown
--      register (0xC0) -> NAK; read tremolo depth (0x84) -> ACK 0x40 0x00
--      (top's 0.5 x 2**15); read tremolo rate (0x85) -> ACK 0xCC 0xCD
--      (top's 150 Hz x 2**32 / 48 kHz / 256 = 52 428.8, rounded); write
--      tremolo depth 0 (0x04) -> ACK. The depth only matters with the
--      tremolo on (mode 3); control is never written, so the switches
--      still decide and checks 4..6 still hold. Checked before the final
--      report.
--
-- The test pattern (test_sample) mixes a 0.9 full-scale sine with +/-
-- full scale and three small values: 2**18 and -(2**18 + 12345) (x2 stays
-- under the clip) and 2**19 (x2 lands exactly on the threshold).
--
-- Run (repo root, PowerShell), Vivado: set top_tb as the simulation top,
-- Run Behavioral Simulation (Vivado compiles the Clocking Wizard's model).
-- For the other runs, set g_mode=1 (hard), 2 (soft), 3 (tremolo) or 4 (tone) in the
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
        g_mode : natural range 0 to 4 := 0 -- 0 dry, 1 hard clip, 2 soft clip, 3 tremolo, 4 tone filter
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
    constant c_trem_rate     : real    := 150.0;                         -- tremolo LFO, Hz (320 frames per cycle)
    constant c_trem_depth    : real    := 0.5;                           -- tremolo depth
    constant c_tone_cutoff   : real    := 3000.0;                        -- tone filter cutoff, Hz
    constant c_tone_q        : real    := 0.707;                         -- tone filter Q
    constant c_no_frame      : integer := integer'low;                   -- "no filter input in this frame"
    constant c_uart_clks     : natural := 16;                            -- g_uart_clks_per_bit for the test
    constant c_uart_bit      : time    := c_uart_clks * 10.172 ns;       -- one UART bit at s_clk 98.305 MHz

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

    -- Soft clip table entry a (0 .. 1024), from the definition:
    -- round(tanh(k * a / 1024) / tanh(k) * (2**23 - 1)).

    function soft_entry (
        a : natural
    ) return integer is
    begin

        return integer(round(tanh(c_soft_drive * real(a) / 1024.0) / tanh(c_soft_drive)
                             * real(2 ** 23 - 1)));

    end function soft_entry;

    -- What the DAC should play for ADC sample x. Dry: x itself.
    -- Soft clip: |x| = not x for x < 0; a = bits 22..13 of |x|, f = bits
    -- 12..0; linear interpolation T(a) + floor((T(a+1) - T(a)) * f / 8192),
    -- inverted back (not) for x < 0.
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
        variable f   : natural;
        variable t   : integer;

    begin

        if (g_mode = 0 or g_mode = 3 or g_mode = 4) then                           -- 4: see tone_model
            return x;
        elsif (g_mode = 2) then
            if (x >= 0) then
                mag := to_signed(x, 24);
            else
                mag := not to_signed(x, 24);
            end if;
            a := to_integer(unsigned(mag(22 downto 13)));
            f := to_integer(unsigned(mag(12 downto 0)));
            t := soft_entry(a) + ((soft_entry(a + 1) - soft_entry(a)) * f) / 8192; -- gap >= 0: "/" = floor
            if (x >= 0) then
                return t;
            else
                return -t - 1;
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

    -- Tone filter coefficient (Cookbook low-pass / a0, Q2.16), from the
    -- maths, for tone_model.

    function tone_coeff (
        name : string
    ) return signed is

        constant w0    : real := 2.0 * MATH_PI * c_tone_cutoff / 48000.0;
        constant alpha : real := sin(w0) / (2.0 * c_tone_q);
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

        return to_signed(integer(round(v / (1.0 + alpha) * 65536.0)), 18);

    end function tone_coeff;

    signal clk100mhz     : std_logic := '0';
    signal reset_btn     : std_logic := '0';
    signal distortion_sw : std_logic := '0'; -- SW0: set from g_mode below
    signal soft_clip_sw  : std_logic := '0'; -- SW1: set from g_mode below
    signal tremolo_sw    : std_logic := '0'; -- SW2: set from g_mode below
    signal tone_sw       : std_logic := '0'; -- SW3: set from g_mode below
    signal ad_sdout      : std_logic := '0';
    signal led_locked    : std_logic;
    signal da_mclk       : std_logic;
    signal da_lrck       : std_logic;
    signal da_sclk       : std_logic;
    signal da_sdin       : std_logic;
    signal ad_mclk       : std_logic;
    signal ad_lrck       : std_logic;
    signal ad_sclk       : std_logic;
    signal uart_txd_in   : std_logic := '1'; -- PC -> FPGA, idles high
    signal uart_rxd_out  : std_logic;        -- FPGA -> PC

    -- UART command check (7): the commands the PC sends, and whether the
    -- replies were right.

    type t_uart_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

    constant c_uart_cmds  : t_uart_bytes(0 to 17) :=
    (
        x"FF",
        x"00",
        x"00",                                                     -- read 0x7F version
        x"90",
        x"00",
        x"00",                                                     -- read 0x10 live state
        x"C0",
        x"00",
        x"00",                                                     -- read 0x40: unknown
        x"84",
        x"00",
        x"00",                                                     -- read 0x04 tremolo depth
        x"85",
        x"00",
        x"00",                                                     -- read 0x05 tremolo rate
        x"04",
        x"00",
        x"00"                                                      -- write 0x04 tremolo depth = 0
    );
    signal   uart_replied : boolean               := false;
    signal   depth0_frame : integer               := integer'high; -- ADC frame when the depth-0 write was ACKed

    type t_sent is array (0 to c_frames + 2) of integer;

    signal sent      : t_sent  := (others => 0);
    signal adc_frame : integer := -1;   -- frames started by the ADC model
    signal press_at  : integer := -100; -- ADC frame in which the button was pressed

    -- Mode 4: per ADC frame, the sample that entered the tone filter in it
    -- and the model's filtered value (c_no_frame: none entered).
    signal tone_in        : t_sent  := (others => c_no_frame);
    signal tone_out       : t_sent  := (others => c_no_frame);
    signal n_tone_checked : natural := 0; -- filter outputs checked in place

begin

    clk100mhz <= not clk100mhz after c_clk100_period / 2;

    -- The switches are held for the whole run (switching is not tested here).
    distortion_sw <= '0' when g_mode = 0 or g_mode = 3 or g_mode = 4 else
                     '1';
    soft_clip_sw  <= '1' when g_mode = 2 else
                     '0';
    tremolo_sw    <= '1' when g_mode = 3 else
                     '0';
    tone_sw       <= '1' when g_mode = 4 else
                     '0';

    dut : entity work.top
        generic map (
            g_mute_samples      => c_mute,
            g_ramp_bits         => c_ramp_bits,
            g_gain              => c_gain,
            g_test_tone         => false,
            g_threshold         => c_threshold,
            g_drive_gain        => c_drive,
            g_soft_drive        => c_soft_drive,
            g_tremolo_rate_hz   => c_trem_rate,
            g_tremolo_depth     => c_trem_depth,
            g_tone_cutoff_hz    => c_tone_cutoff,
            g_tone_q            => c_tone_q,
            g_uart_clks_per_bit => c_uart_clks
        )
        port map (
            clk100mhz     => clk100mhz,
            reset_btn     => reset_btn,
            distortion_sw => distortion_sw,
            soft_clip_sw  => soft_clip_sw,
            tremolo_sw    => tremolo_sw,
            tone_sw       => tone_sw,
            ad_sdout      => ad_sdout,
            led_locked    => led_locked,
            da_mclk       => da_mclk,
            da_lrck       => da_lrck,
            da_sclk       => da_sclk,
            da_sdin       => da_sdin,
            ad_mclk       => ad_mclk,
            ad_lrck       => ad_lrck,
            ad_sclk       => ad_sclk,
            uart_txd_in   => uart_txd_in,
            uart_rxd_out  => uart_rxd_out
        );

    -- 7. UART commands: the PC sends five reads and a write back-to-back on
    -- uart_txd_in soon after lock (well before the button at frame
    -- c_press_at); the replies on uart_rxd_out are checked in uart_pc_rx.
    uart_pc_tx : process is
    begin

        wait until led_locked = '1';
        wait for 5 us;                            -- s_reset released after lock

        for n in c_uart_cmds'range loop

            uart_txd_in <= '0';                   -- start bit
            wait for c_uart_bit;

            for i in 0 to 7 loop                  -- LSB first

                uart_txd_in <= c_uart_cmds(n)(i);
                wait for c_uart_bit;

            end loop;

            uart_txd_in <= '1';                   -- stop bit
            wait for c_uart_bit;

        end loop;

        wait;

    end process uart_pc_tx;

    uart_pc_rx : process is

        variable b      : std_logic_vector(7 downto 0);
        variable live   : std_logic_vector(7 downto 0);
        variable expect : t_uart_bytes(0 to 13);

    begin

        wait until led_locked = '1';

        -- Live state with the switches in charge: effects = switches (bits
        -- 0..3), switches again in bits 4..6 and 8, PC control (bit 7) off.
        live   :=
        (
            0 => distortion_sw,
            1 => soft_clip_sw,
            2 => tremolo_sw,
            3 => tone_sw,
            4 => distortion_sw,
            5 => soft_clip_sw,
            6 => tremolo_sw,
            others => '0'
        );
        expect :=
        (
            x"06",
            x"00",
            x"02",                                                                                -- version: ACK, 2
            x"06",
            "0000000" & tone_sw,
            live,                                                                                 -- live: ACK, value
            x"15",                                                                                -- unknown: NAK
            x"06",
            x"40",
            x"00",                                                                                -- depth: ACK, 0.5
            x"06",
            x"CC",
            x"CD",                                                                                -- rate: ACK, 150 Hz
            x"06"
        );                                                                                        -- write depth 0: ACK

        for n in expect'range loop

            wait until uart_rxd_out = '0';                                                        -- start bit
            wait for c_uart_bit / 2;
            assert uart_rxd_out = '0'
                report "UART: bad start bit"
                severity failure;

            for i in 0 to 7 loop

                wait for c_uart_bit;
                b(i) := uart_rxd_out;

            end loop;

            wait for c_uart_bit;
            assert uart_rxd_out = '1'
                report "UART: framing error"
                severity failure;
            assert b = expect(n)
                report "UART: reply byte " & integer'image(n) & " is 0x" & to_hstring(b)
                       & ", expected 0x" & to_hstring(expect(n))
                severity failure;

            if (n = expect'high) then
                depth0_frame <= adc_frame;                                                        -- depth 0 from here
            end if;

        end loop;

        report "UART: version, live state, NAK, tremolo depth / rate and write replies all right"
            severity note;
        uart_replied <= true;
        wait;

    end process uart_pc_rx;

    -- Mode 4: the tone filter model, on top's own clock and reset, fed with
    -- the filter's real input (VHDL-2008 external names into the DUT).
    -- Direct Form I: five products summed at 45 bits, + 2**15, >> 16,
    -- clipped to Q1.23; the state holds the clipped outputs. Checks every
    -- tone_filter output in place, and records each frame's in / out for
    -- the DAC check.
    tone_model : process is

        alias s_clk     is << signal .top_tb.dut.s_clk : std_logic >>;
        alias s_reset   is << signal .top_tb.dut.s_reset : std_logic >>;
        alias f_in      is << signal .top_tb.dut.s_mod_sample : signed(23 downto 0) >>;
        alias f_in_vld  is << signal .top_tb.dut.s_mod_sample_valid : std_logic >>;
        alias f_out     is << signal .top_tb.dut.s_lowpass_sample : signed(23 downto 0) >>;
        alias f_out_vld is << signal .top_tb.dut.s_lowpass_sample_valid : std_logic >>;

        constant b0 : signed(17 downto 0) := tone_coeff("b0");
        constant b1 : signed(17 downto 0) := tone_coeff("b1");
        constant b2 : signed(17 downto 0) := tone_coeff("b2");
        constant a1 : signed(17 downto 0) := tone_coeff("a1");
        constant a2 : signed(17 downto 0) := tone_coeff("a2");

        variable x1        : signed(23 downto 0) := (others => '0');
        variable x2        : signed(23 downto 0) := (others => '0');
        variable y1        : signed(23 downto 0) := (others => '0');
        variable y2        : signed(23 downto 0) := (others => '0');
        variable acc       : signed(44 downto 0);
        variable r         : signed(44 downto 0);
        variable y         : signed(23 downto 0);
        variable pending   : boolean             := false; -- an output is due
        variable pending_y : integer;
        variable n         : natural             := 0;

    begin

        if (g_mode /= 4) then
            wait;
        end if;

        loop

            wait until rising_edge(s_clk);

            -- The filter's output, against the model.
            if (f_out_vld = '1') then
                assert pending
                    report "tone_filter: output with no input to match"
                    severity failure;
                assert to_integer(f_out) = pending_y
                    report "tone_filter output " & integer'image(to_integer(f_out)) & ", model "
                           & integer'image(pending_y)
                    severity failure;
                pending        := false;
                n              := n + 1;
                n_tone_checked <= n;
            end if;

            -- The model steps on this edge, like the DUT.
            if (s_reset = '1') then
                x1      := (others => '0');
                x2      := (others => '0');
                y1      := (others => '0');
                y2      := (others => '0');
                pending := false;
            elsif (f_in_vld = '1') then
                acc := resize(b0 * f_in, 45) + resize(b1 * x1, 45) + resize(b2 * x2, 45)
                       - resize(a1 * y1, 45) - resize(a2 * y2, 45);
                r   := shift_right(acc + 2 ** 15, 16);
                if (r > 2 ** 23 - 1) then
                    y := to_signed(2 ** 23 - 1, 24);
                elsif (r < -(2 ** 23)) then
                    y := to_signed(-(2 ** 23), 24);
                else
                    y := resize(r, 24);
                end if;
                x2        := x1;
                x1        := f_in;
                y2        := y1;
                y1        := y;
                pending   := true;
                pending_y := to_integer(y);
                if (adc_frame >= 0 and adc_frame <= c_frames + 2) then
                    tone_in(adc_frame)  <= to_integer(f_in);
                    tone_out(adc_frame) <= to_integer(y);
                end if;
            end if;

        end loop;

    end process tone_model;

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
        variable n_dip    : natural   := 0; -- tremolo: frames turned down (< 0.9 x dry)
        variable n_full   : natural   := 0; -- tremolo: frames near full level (> 0.95 x dry)
        variable n_exact  : natural   := 0; -- tremolo: frames exact at depth 0 (before the button)
        variable found    : boolean;        -- tone: the model has this frame's value
        variable n_filt   : natural   := 0; -- tone: frames where the filter changed the sample

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

            -- Tone: the model's filtered value for that frame's sample. The
            -- recorded input must be the sample itself (confirms the frame
            -- mapping); a frame cut short by the button may have none.
            found := true;
            if (g_mode = 4) then
                found := tone_in(adc_frame - 1) = sent(adc_frame - 1);
                if (found) then
                    exp := tone_out(adc_frame - 1);
                end if;
            end if;

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
                    assert abs (got) <= abs (exp) or not found
                        report "frame " & integer'image(adc_frame) & " (mute/ramp): output "
                               & integer'image(got) & " bigger than expected " & integer'image(exp)
                        severity failure;
                    -- Tremolo: the LFO keeps got /= exp, so pass-through is
                    -- reached by time (mute + ramp over).
                    if ((g_mode /= 3 and found and got = exp and exp /= 0 and adc_frame - start >= c_mute)
                        or (g_mode = 3 and adc_frame - start >= c_settle)) then
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
                elsif (g_mode = 3) then
                    -- Tremolo: |out| between (1 - depth) x |dry| and |dry|.
                    assert abs (got) <= abs (exp)
                           and real(abs (got)) >= (1.0 - c_trem_depth) * real(abs (exp)) - 2.0
                        report "frame " & integer'image(adc_frame) & ": tremolo output "
                               & integer'image(got) & " outside " & real'image(1.0 - c_trem_depth)
                               & " .. 1.0 x dry " & integer'image(exp)
                        severity failure;
                    assert (got >= 0) = (exp >= 0) or got = 0
                        report "frame " & integer'image(adc_frame) & ": tremolo changed the sign"
                        severity failure;
                    -- Depth 0 (written over the UART), from two frames after
                    -- the ACK until the button resets it: exactly dry.
                    if (press_at < 0 and adc_frame >= depth0_frame + 2) then
                        assert got = exp
                            report "frame " & integer'image(adc_frame) & ": depth 0 output "
                                   & integer'image(got) & " /= dry " & integer'image(exp)
                            severity failure;
                        n_exact := n_exact + 1;
                    end if;
                    n_pass := n_pass + 1;
                    if (abs (exp) > 2 ** 20) then
                        if (real(abs (got)) < 0.9 * real(abs (exp))) then
                            n_dip := n_dip + 1;
                        elsif (real(abs (got)) > 0.95 * real(abs (exp))) then
                            n_full := n_full + 1;
                        end if;
                    end if;
                else
                    -- After the ramp: exactly expected_out(last frame's ADC
                    -- sample); tone: exactly the model's filtered value.
                    assert found
                        report "frame " & integer'image(adc_frame) & ": no tone filter input recorded for ADC frame "
                               & integer'image(adc_frame - 1) & " (sample " & integer'image(sent(adc_frame - 1)) & ")"
                        severity failure;
                    assert got = exp
                        report "frame " & integer'image(adc_frame) & ": DAC " & integer'image(got)
                               & ", expected " & integer'image(exp) & " (ADC sample "
                               & integer'image(sent(adc_frame - 1)) & " from frame "
                               & integer'image(adc_frame - 1) & ")"
                        severity failure;
                    n_pass := n_pass + 1;
                    if (g_mode = 4) then
                        if (exp /= sent(adc_frame - 1)) then
                            n_filt := n_filt + 1;                                                                      -- tone: the filter changed it
                        end if;
                    elsif (g_mode = 2) then
                        if (exp > 0) then
                            n_clip_p := n_clip_p + 1;                                                                  -- soft: positive outputs
                        elsif (exp < 0) then
                            n_clip_n := n_clip_n + 1;                                                                  -- soft: negative outputs
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
            if (g_mode = 4) then
                -- 6. Tone: the filter really changes the sound, and every
                -- output of it matched the model in place.
                assert n_filt > c_frames / 2 and n_tone_checked > c_frames - 10
                    report "tone coverage: " & integer'image(n_filt) & " frames changed by the filter, "
                           & integer'image(n_tone_checked) & " filter outputs checked"
                    severity failure;
                report "TONE run: " & integer'image(n_pass) & " frames exact at the DAC, in "
                       & integer'image(runs) & " stretches; " & integer'image(n_filt)
                       & " changed by the filter; " & integer'image(n_tone_checked)
                       & " filter outputs checked in place"
                    severity note;
            elsif (g_mode = 3) then
                -- 6. Tremolo: exact at depth 0 (PC write), dipped after the
                -- button put the default depth back.
                assert n_dip > 0 and n_full > 0 and n_exact >= 5
                    report "tremolo coverage: " & integer'image(n_dip) & " dipped, "
                           & integer'image(n_full) & " near full level, "
                           & integer'image(n_exact) & " exact at depth 0"
                    severity failure;
                report "TREMOLO run: " & integer'image(n_pass) & " frames in the envelope, in "
                       & integer'image(runs) & " stretches; " & integer'image(n_exact)
                       & " exact at depth 0, " & integer'image(n_dip) & " dipped, "
                       & integer'image(n_full) & " near full level"
                    severity note;
            elsif (g_mode = 2) then
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
            assert uart_replied
                report "UART: not all command replies came back"
                severity failure;
            report "ALL TESTS PASSED"
                severity note;
            std.env.finish;
        end if;

    end process dac;

end architecture sim;
