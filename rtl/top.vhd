-- top: guitar-fx top level for the Arty A7-35T with a Pmod I2S2 on JA.
--
-- Audio path (one sample per frame, 48 kHz, 24-bit, mono = left channel in,
-- the same sample to both channels out):
--
--   ad_sdout -> i2s_rx -+-> drive_gain_stage -> clip_stage -+-> distortion
--                       +-> soft_clip ----------------------+   mux (SW0, SW1)
--                       +---------------- bypass -----------+    |
--                                                                 v
--                                         +---------- tremolo <---+
--                            tremolo mux <+                       |
--                             (SW2)   |   +------- bypass --------+
--                                     v
--                     +-- tone_filter -+
--          tone mux <-+                +-- (from the tremolo mux)
--           (SW3)  |  +---- bypass ----+
--                  v
--      da_sdin <- i2s_tx <- output_gain_stage <- soft_start
--
-- Distortion (effect #2), two kinds:
--   hard: drive_gain_stage (a gain_stage, g_drive_gain) pushes the signal
--         into clip_stage (hard_clip_stage, g_threshold).
--   soft: soft_clip (soft_clip_stage, a tanh lookup table, drive
--         g_soft_drive). Fed straight from i2s_rx: a gain_stage in front
--         would itself hard-clip at full scale.
-- The mux picks one, from two on/off bits that ctrl_regs gives (from the
-- switches, or from the PC once it takes control; see UART below):
--   distortion (SW0) off                -> dry (soft/hard ignored)
--   distortion on, soft (SW1) on        -> soft clip
--   distortion on, soft (SW1) off       -> hard clip
--
-- Tremolo (effect #3): tremolo (tremolo_stage) turns the volume up and down
-- g_tremolo_rate_hz times a second (power-up default; the PC can change it),
-- dipping to 1 - g_tremolo_depth. It
-- comes after the distortion: a clipper squashes level changes, so a
-- tremolo in front of it would be mostly flattened out.
--   tremolo (SW2, or the PC) on -> tremolo, off -> passed straight through
--
-- Tone (effect #4): tone_filter (tone_stage, a biquad low-pass) cuts the
-- treble above g_tone_cutoff_hz, 12 dB per octave. Last of the effects, so
-- it tames the fizz of whichever distortion is on, like a guitar's tone
-- knob after a pedal.
--   tone (SW3, or the PC) on -> filtered, off -> passed straight through
--
-- Effects go before soft_start, so its mute and fade-in apply to the
-- effected signal.
--
-- output_gain_stage sets the output level for whatever the DAC feeds. It
-- is last in the chain, so effects see the guitar's real level whatever the
-- output is plugged into.
--
-- Signal names: each sample / valid pair is named after the block that
-- drives it (s_rx_sample is i2s_rx's output, s_gain_sample is
-- output_gain_stage's, and so on).
--
-- Clocks: the Clocking Wizard IP (clk_wiz_audio, made by
-- scripts/create_project.tcl) turns the 100 MHz board clock into the
-- 98.304 MHz system clock s_clk (actual 98.305). Everything runs on s_clk;
-- i2s_clocks divides it into MCLK / SCLK / LRCK, sent to both Pmod rows (the
-- ADC and the DAC share one set of clocks), and the strobes the blocks use.
-- The MMCM's own reset is tied to '0'; led_locked shows its locked output.
--
-- Reset: s_reset is '1' while BTN0 (reset_btn) is pressed or the MMCM is not
-- locked yet. Two flip-flops on s_clk synchronise it (the button is not on
-- s_clk), so every block leaves reset on the same clock edge. It starts at
-- '1', so the design powers up in reset.
--
-- Generics: g_mute_samples and g_ramp_bits pass straight through to
-- soft_start (defaults are the hardware values: 3 s mute, 42.7 ms ramp;
-- top_tb makes them tiny). g_gain, g_drive_gain and g_threshold are now the
-- power-up defaults of ctrl_regs' registers 0x01..0x03, which the PC can
-- change (passed in as g_gain / 2**2 etc.: the registers are Q3.13 and
-- Q0.16, so their bottom 2 / 7 bits are dropped). g_gain is the output gain in Q3.15
-- (1.0 = 32768): default 1024 = 1/32 = -30.1 dB, line level for the PC's
-- USB mic input; top_tb uses 1.0 so it can check exact pass-through.
-- g_drive_gain (Q3.15) and g_threshold (Q0.23) set the distortion. Defaults
-- x2.0 and 0.125, for this guitar through the preamp at G = 3 (a hard strum
-- reaches the drive at ~0.33 of full scale): a strum is driven ~5x (+14 dB)
-- over the clip, and notes clean up as they decay below ~0.06. The output is
-- then about the threshold, so SW0 up is quieter than SW0 down. x1.0 with
-- the maximum threshold (2**23 - 1) makes the hard clip do nothing.
-- g_soft_drive (real, k in tanh(k x) / tanh(k)) sets the soft clip:
-- ~1 barely bends, 3 (default) overdrive, 10 near a hard clip. Quiet notes
-- come out about k / tanh(k) louder, so the soft clip is louder than dry.
-- g_tremolo_rate_hz (real, Hz) and g_tremolo_depth (real, 0.0 none .. 1.0
-- dips to silence) are the power-up tremolo settings, registers 0x05 and
-- 0x04 (defaults 5 Hz and 0.5, -6 dB dips). The real maths runs here, at
-- build time: depth x 2**15 (Q1.15), and rate x 2**32 / 48 kHz / 256 (the
-- phase step / 256).
-- g_tone_cutoff_hz (real, the -3 dB point) and g_tone_q (real, 0.707 =
-- smooth, higher = a peak at the cutoff) set the tone filter: defaults
-- 3 kHz and 0.707.
--
-- Test tone: g_test_tone = true sends tone_gen's 1 kHz, -20 dBFS sine
-- straight to i2s_tx instead of the audio path, to check the DAC and line
-- out with nothing plugged into the line in. Leave it false for normal use.
--
-- PC control over the UART: the Arty's USB-UART, uart_txd_in (A9, PC ->
-- FPGA) and uart_rxd_out (D10, FPGA -> PC), 115 200 baud 8N1.
--   uart (uart_rx + transmit FIFO + uart_tx) -> cmd_decoder (3-byte
--   commands, replies ACK / NAK / CAN, reads reply ACK + 2 bytes) ->
--   ctrl_regs (registers: 0x00 control, 0x01 output gain, 0x02 drive,
--   0x03 threshold, 0x10 live state, 0x7F version).
-- ctrl_regs gives the effects their on/off bits (the switches while
-- register 0x00 bit 7 is '0', which is how it starts; the PC's bits once
-- it sets bit 7) and their gains and threshold. With no PC commands the
-- pedal behaves exactly as with the switches and generics alone.
-- PC side: model/fx.py (write / read / status). Protocol and register map:
-- docs/uart.md section 5. g_uart_clks_per_bit = s_clk / baud rate: 853 for
-- 115 200 at 98.305 MHz (+0.04 %); top_tb makes it small.
--
-- Pins: constraints/Arty-A7-35-Master.xdc. Testbench: sim/top_tb.vhd.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity top is
    generic (
        g_mute_samples      : natural                               := 144000;  -- 3 s at 48 kHz
        g_ramp_bits         : natural                               := 11;      -- 2,048-sample ramp
        g_gain              : integer range -2 ** 17 to 2 ** 17 - 1 := 1024;    -- 1/32 = -30.1 dB in Q3.15
        g_test_tone         : boolean                               := false;   -- true: 1 kHz test tone to the DAC
        g_threshold         : integer range 0 to 2 ** 23 - 1        := 2 ** 20; -- clip level, Q0.23; 2**20 = 0.125 (max 2**23 - 1 = no clipping)
        g_drive_gain        : integer range -2 ** 17 to 2 ** 17 - 1 := 2 ** 16; -- drive before the clip, Q3.15; 2**16 = x2.0 (2**15 = x1.0)
        g_soft_drive        : real                                  := 3.0;     -- soft clip drive k (tanh), 3.0 = overdrive
        g_tremolo_rate_hz   : real                                  := 5.0;     -- tremolo speed, Hz
        g_tremolo_depth     : real                                  := 0.5;     -- how far the tremolo dips: 0.0 none .. 1.0 to silence
        g_tone_cutoff_hz    : real                                  := 3000.0;  -- tone filter cutoff (-3 dB), Hz
        g_tone_q            : real                                  := 0.707;   -- tone filter Q: 0.707 = smooth (Butterworth)
        g_uart_clks_per_bit : natural                               := 853      -- clocks per UART bit (115 200 baud)
    );
    port (
        clk100mhz     : in    std_logic; -- 100 MHz board clock (E3)
        reset_btn     : in    std_logic; -- BTN0, '1' while pressed
        distortion_sw : in    std_logic; -- SW0, '1' = distortion on
        soft_clip_sw  : in    std_logic; -- SW1, '1' = soft clip, '0' = hard clip (when SW0 = '1')
        tremolo_sw    : in    std_logic; -- SW2, '1' = tremolo on
        tone_sw       : in    std_logic; -- SW3, '1' = tone filter on
        ad_sdout      : in    std_logic; -- Pmod AD SDOUT (ADC data in)
        uart_txd_in   : in    std_logic; -- USB-UART: PC -> FPGA (A9)
        uart_rxd_out  : out   std_logic; -- USB-UART: FPGA -> PC (D10)
        led_locked    : out   std_logic; -- LD4: MMCM locked
        da_mclk       : out   std_logic; -- Pmod DA row: DAC clocks and data
        da_lrck       : out   std_logic;
        da_sclk       : out   std_logic;
        da_sdin       : out   std_logic;
        ad_mclk       : out   std_logic; -- Pmod AD row: ADC clocks
        ad_lrck       : out   std_logic;
        ad_sclk       : out   std_logic
    );
end entity top;

architecture rtl of top is

    -- Clocking Wizard IP: a component, because the IP is not a VHDL entity in
    -- work (it is built out of context, and its simulation model is Verilog).
    component clk_wiz_audio is
        port (
            clk_out1 : out   std_logic;
            reset    : in    std_logic;
            locked   : out   std_logic;
            clk_in1  : in    std_logic
        );
    end component clk_wiz_audio;

    signal s_clk    : std_logic; -- 98.304 MHz system clock
    signal s_locked : std_logic;

    signal s_reset_raw  : std_logic;        -- button or not locked (not on s_clk)
    signal s_reset_meta : std_logic := '1'; -- FF1: may go metastable
    signal s_reset      : std_logic := '1'; -- FF2: clean reset, to every block

    -- From i2s_clocks.
    signal s_mclk        : std_logic;
    signal s_sclk        : std_logic;
    signal s_lrck        : std_logic;
    signal s_sclk_rise   : std_logic;
    signal s_sclk_fall   : std_logic;
    signal s_frame_start : std_logic;

    -- i2s_rx -> drive_gain_stage, soft_clip and the distortion mux.
    signal s_rx_sample       : signed(23 downto 0);
    signal s_rx_sample_valid : std_logic;
    -- drive_gain_stage -> clip_stage.
    signal s_drive_sample       : signed(23 downto 0);
    signal s_drive_sample_valid : std_logic;
    -- clip_stage -> the distortion mux.
    signal s_clip_sample       : signed(23 downto 0);
    signal s_clip_sample_valid : std_logic;
    -- soft_clip -> the distortion mux.
    signal s_soft_clip_sample       : signed(23 downto 0);
    signal s_soft_clip_sample_valid : std_logic;
    -- The distortion mux -> tremolo and the tremolo mux.
    signal s_fx_sample       : signed(23 downto 0);
    signal s_fx_sample_valid : std_logic;
    -- tremolo -> the tremolo mux.
    signal s_tremolo_sample       : signed(23 downto 0);
    signal s_tremolo_sample_valid : std_logic;
    -- The tremolo mux -> tone_filter and the tone mux ("mod": the
    -- modulation effects).
    signal s_mod_sample       : signed(23 downto 0);
    signal s_mod_sample_valid : std_logic;
    -- tone_filter -> the tone mux.
    signal s_lowpass_sample       : signed(23 downto 0);
    signal s_lowpass_sample_valid : std_logic;
    -- The tone mux -> soft_start ("eq": the tone-shaping stage).
    signal s_eq_sample       : signed(23 downto 0);
    signal s_eq_sample_valid : std_logic;
    -- soft_start -> output_gain_stage.
    signal s_soft_sample       : signed(23 downto 0);
    signal s_soft_sample_valid : std_logic;
    -- output_gain_stage -> the test-tone switch.
    signal s_gain_sample       : signed(23 downto 0);
    signal s_gain_sample_valid : std_logic;
    -- tone_gen -> the test-tone switch.
    signal s_test_tone_sample       : signed(23 downto 0);
    signal s_test_tone_sample_valid : std_logic;
    -- The test-tone switch -> i2s_tx.
    signal s_tx_sample       : signed(23 downto 0);
    signal s_tx_sample_valid : std_logic;

    -- Switch synchronisers (SW0 .. SW3). All start at '0' (dry; hard clip
    -- selected; no tremolo; no tone filter), the plain state, until the real
    -- switch positions arrive two clocks later.
    signal s_distortion_raw  : std_logic;        -- distortion_sw as read (not on s_clk)
    signal s_distortion_meta : std_logic := '0'; -- FF1: may go metastable
    signal s_distortion      : std_logic := '0'; -- FF2: clean SW0, '1' = distortion on

    signal s_soft_select_raw  : std_logic;        -- soft_clip_sw as read (not on s_clk)
    signal s_soft_select_meta : std_logic := '0'; -- FF1: may go metastable
    signal s_soft_select      : std_logic := '0'; -- FF2: clean SW1, '1' = soft clip, '0' = hard

    signal s_tremolo_raw  : std_logic;        -- tremolo_sw as read (not on s_clk)
    signal s_tremolo_meta : std_logic := '0'; -- FF1: may go metastable
    signal s_tremolo      : std_logic := '0'; -- FF2: clean SW2, '1' = tremolo on

    signal s_tone_raw  : std_logic;        -- tone_sw as read (not on s_clk)
    signal s_tone_meta : std_logic := '0'; -- FF1: may go metastable
    signal s_tone      : std_logic := '0'; -- FF2: clean SW3, '1' = tone filter on

    -- uart -> cmd_decoder: bytes from the PC.
    signal s_uart_rx_data        : std_logic_vector(7 downto 0); -- byte from the PC
    signal s_uart_rx_valid       : std_logic;                    -- one-clock pulse: a good byte
    signal s_uart_rx_frame_error : std_logic;                    -- one-clock pulse: a bad byte

    -- cmd_decoder -> uart: reply bytes to the PC (ACK / NAK / CAN, read values).
    signal s_cmd_tx_data  : std_logic_vector(7 downto 0); -- byte to the PC
    signal s_cmd_tx_valid : std_logic;                    -- one-clock pulse: queue it

    -- cmd_decoder -> ctrl_regs: the register addressed, and a write.
    signal s_cmd_reg_addr  : std_logic_vector(7 downto 0);  -- bit 7 read flag, 6..0 register
    signal s_cmd_reg_data  : std_logic_vector(15 downto 0); -- value to write
    signal s_cmd_reg_write : std_logic;                     -- one-clock pulse: write it

    -- ctrl_regs -> cmd_decoder: answers about s_cmd_reg_addr (no clock).
    signal s_ctrl_addr_valid    : std_logic;                     -- the register exists
    signal s_ctrl_addr_writable : std_logic;                     -- it can be written
    signal s_ctrl_rdata         : std_logic_vector(15 downto 0); -- its value, for a read

    -- ctrl_regs -> the effects: on/off (switches or PC) and the settings.
    signal s_fx_distortion : std_logic;             -- '1' = distortion on
    signal s_fx_soft       : std_logic;             -- '1' = soft clip, '0' = hard
    signal s_fx_tremolo    : std_logic;             -- '1' = tremolo on
    signal s_fx_tone       : std_logic;             -- '1' = tone filter on
    signal s_out_gain      : signed(17 downto 0);   -- output gain, Q3.15
    signal s_drive_gain    : signed(17 downto 0);   -- drive before the clip, Q3.15
    signal s_threshold     : unsigned(22 downto 0); -- clip level, Q0.23
    signal s_tremolo_depth : signed(17 downto 0);   -- tremolo depth, Q.15
    signal s_tremolo_step  : unsigned(31 downto 0); -- tremolo step, Q0.32

begin

    clock_audio : component clk_wiz_audio
        port map (
            clk_out1 => s_clk,
            reset    => '0',
            locked   => s_locked,
            clk_in1  => clk100mhz
        );

    i2s_clocks_stage : entity work.i2s_clocks
        port map (
            clk         => s_clk,
            reset       => s_reset,
            mclk        => s_mclk,
            sclk        => s_sclk,
            lrck        => s_lrck,
            sclk_rise   => s_sclk_rise,
            sclk_fall   => s_sclk_fall,
            frame_start => s_frame_start
        );

    i2s_tx_stage : entity work.i2s_tx
        port map (
            clk             => s_clk,
            reset           => s_reset,
            sample_in       => s_tx_sample,
            sample_in_valid => s_tx_sample_valid,
            sclk_fall       => s_sclk_fall,
            frame_start     => s_frame_start,
            sdin            => da_sdin
        );

    i2s_rx_stage : entity work.i2s_rx
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sdout            => ad_sdout,
            sclk_rise        => s_sclk_rise,
            frame_start      => s_frame_start,
            sample_out       => s_rx_sample,
            sample_out_valid => s_rx_sample_valid
        );

    -- Distortion, part 1, drive: a gain (s_drive_gain from ctrl_regs) that
    -- pushes the signal up into the clip. Default x2.0 (g_drive_gain).
    drive_gain_stage : entity work.gain_stage
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_rx_sample,
            sample_in_valid  => s_rx_sample_valid,
            gain             => s_drive_gain,
            sample_out       => s_drive_sample,
            sample_out_valid => s_drive_sample_valid
        );

    -- Distortion, part 2, clip: flattens every sample beyond +/- s_threshold
    -- (from ctrl_regs). Default 0.125 (g_threshold).
    clip_stage : entity work.hard_clip_stage
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_drive_sample,
            sample_in_valid  => s_drive_sample_valid,
            threshold        => s_threshold,
            sample_out       => s_clip_sample,
            sample_out_valid => s_clip_sample_valid
        );

    -- Soft clip: tanh lookup table, drive g_soft_drive. Fed straight from
    -- i2s_rx (no gain_stage in front, which would hard-clip at full scale).
    soft_clip : entity work.soft_clip_stage
        generic map (
            g_drive => g_soft_drive
        )
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_rx_sample,
            sample_in_valid  => s_rx_sample_valid,
            sample_out       => s_soft_clip_sample,
            sample_out_valid => s_soft_clip_sample_valid
        );

    -- Tremolo: an LFO-driven gain on whatever the distortion mux sends.
    -- Rate and depth come from ctrl_regs. The step is worked out for 48 kHz
    -- (the real rate is 48.0025 kHz: 0.005 % slow, inaudible).
    tremolo : entity work.tremolo_stage
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_fx_sample,
            sample_in_valid  => s_fx_sample_valid,
            rate_step        => s_tremolo_step,
            depth            => s_tremolo_depth,
            sample_out       => s_tremolo_sample,
            sample_out_valid => s_tremolo_sample_valid
        );

    -- Tone: a biquad low-pass on whatever the tremolo mux sends. Its
    -- g_sample_rate is left at 48 kHz, as for the tremolo (0.005 % off).
    tone_filter : entity work.tone_stage
        generic map (
            g_cutoff_hz => g_tone_cutoff_hz,
            g_q         => g_tone_q
        )
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_mod_sample,
            sample_in_valid  => s_mod_sample_valid,
            sample_out       => s_lowpass_sample,
            sample_out_valid => s_lowpass_sample_valid
        );

    soft_start_stage : entity work.soft_start
        generic map (
            g_mute_samples => g_mute_samples,
            g_ramp_bits    => g_ramp_bits
        )
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_eq_sample,
            sample_in_valid  => s_eq_sample_valid,
            sample_out       => s_soft_sample,
            sample_out_valid => s_soft_sample_valid
        );

    -- Output level: a gain (s_out_gain from ctrl_regs), last before the DAC.
    -- Default 1/32 (g_gain).
    output_gain_stage : entity work.gain_stage
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_soft_sample,
            sample_in_valid  => s_soft_sample_valid,
            gain             => s_out_gain,
            sample_out       => s_gain_sample,
            sample_out_valid => s_gain_sample_valid
        );

    -- Test tone: a 1 kHz sine, one sample per frame.
    test_tone : entity work.tone_gen
        port map (
            clk              => s_clk,
            reset            => s_reset,
            frame_start      => s_frame_start,
            sample_out       => s_test_tone_sample,
            sample_out_valid => s_test_tone_sample_valid
        );

    -- USB-UART: rx <- uart_txd_in (from the PC), tx -> uart_rxd_out (to the
    -- PC). Received bytes go to cmd_decoder; its replies come back in on
    -- tx_data / tx_valid and are queued in the transmit FIFO.
    uart_stage : entity work.uart
        generic map (
            g_clks_per_bit => g_uart_clks_per_bit
        )
        port map (
            clk            => s_clk,
            reset          => s_reset,
            rx             => uart_txd_in,
            tx_data        => s_cmd_tx_data,
            tx_valid       => s_cmd_tx_valid,
            tx             => uart_rxd_out,
            rx_data        => s_uart_rx_data,
            rx_valid       => s_uart_rx_valid,
            rx_frame_error => s_uart_rx_frame_error,
            tx_full        => open,
            tx_overflow    => open
        );

    -- The test-tone switch: g_test_tone picks what i2s_tx sends. It is a
    -- generic, so synthesis keeps only the chosen side.
    s_tx_sample       <= s_test_tone_sample when g_test_tone else
                         s_gain_sample;
    s_tx_sample_valid <= s_test_tone_sample_valid when g_test_tone else
                         s_gain_sample_valid;

    -- Command decoder: decodes the PC's commands, and answers them. It
    -- sends the register writes to ctrl_regs, and the register reads back to
    -- the PC. It also sends the register numbers to ctrl_regs, so it can
    -- answer whether the register exists and is writable.
    cmd_stage : entity work.cmd_decoder
        port map (
            clk               => s_clk,
            reset             => s_reset,
            rx_data           => s_uart_rx_data,
            rx_valid          => s_uart_rx_valid,
            rx_frame_error    => s_uart_rx_frame_error,
            tx_data           => s_cmd_tx_data,
            tx_valid          => s_cmd_tx_valid,
            reg_addr          => s_cmd_reg_addr,
            reg_data          => s_cmd_reg_data,
            reg_write         => s_cmd_reg_write,
            reg_addr_valid    => s_ctrl_addr_valid,
            reg_addr_writable => s_ctrl_addr_writable,
            reg_rdata         => s_ctrl_rdata
        );

    -- Control registers: the power-up defaults are top's generics, converted
    -- to the 16-bit register formats (dropping n fraction bits = / 2**n; the
    -- tremolo's reals scaled and rounded: depth Q1.15, rate = step / 256).
    ctrl_stage : entity work.ctrl_regs
        generic map (
            g_default_out_gain  => g_gain / 2 ** 2,
            g_default_drive     => g_drive_gain / 2 ** 2,
            g_default_threshold => g_threshold / 2 ** 7,
            g_default_depth     => integer(round(g_tremolo_depth * 32768.0)),
            g_default_rate      => integer(round(g_tremolo_rate_hz * 2.0 ** 32 / 48000.0 / 256.0))
        )
        port map (
            clk               => s_clk,
            reset             => s_reset,
            reg_addr          => s_cmd_reg_addr,
            reg_data          => s_cmd_reg_data,
            reg_write         => s_cmd_reg_write,
            sw_distortion     => s_distortion,
            sw_soft           => s_soft_select,
            sw_tremolo        => s_tremolo,
            sw_tone           => s_tone,
            reg_addr_valid    => s_ctrl_addr_valid,
            reg_addr_writable => s_ctrl_addr_writable,
            reg_rdata         => s_ctrl_rdata,
            fx_distortion     => s_fx_distortion,
            fx_soft           => s_fx_soft,
            fx_tremolo        => s_fx_tremolo,
            fx_tone           => s_fx_tone,
            out_gain          => s_out_gain,
            drive_gain        => s_drive_gain,
            threshold         => s_threshold,
            tremolo_depth     => s_tremolo_depth,
            tremolo_step      => s_tremolo_step
        );

    -- Reset synchroniser: two flip-flops on s_clk.
    reset_sync : process (s_clk) is
    begin

        if rising_edge(s_clk) then
            s_reset_meta <= s_reset_raw;  -- FF1 takes the raw input
            s_reset      <= s_reset_meta; -- FF2 (clean)
        end if;

    end process reset_sync;

    -- Switch synchronisers (SW0 .. SW3): two flip-flops each on s_clk, as
    -- reset_sync. The slide switches are not on s_clk, so they can change at
    -- any moment.
    switch_sync : process (s_clk) is
    begin

        if rising_edge(s_clk) then
            s_distortion_meta <= s_distortion_raw;    -- FF1 takes the raw input
            s_distortion      <= s_distortion_meta;   -- FF2 (clean)

            s_soft_select_meta <= s_soft_select_raw;  -- FF1 takes the raw input
            s_soft_select      <= s_soft_select_meta; -- FF2 (clean)

            s_tremolo_meta <= s_tremolo_raw;          -- FF1 takes the raw input
            s_tremolo      <= s_tremolo_meta;         -- FF2 (clean)

            s_tone_meta <= s_tone_raw;                -- FF1 takes the raw input
            s_tone      <= s_tone_meta;               -- FF2 (clean)
        end if;

    end process switch_sync;

    s_distortion_raw  <= distortion_sw;
    s_soft_select_raw <= soft_clip_sw;
    s_tremolo_raw     <= tremolo_sw;
    s_tone_raw        <= tone_sw;
    s_reset_raw       <= reset_btn or not s_locked;
    led_locked        <= s_locked;

    -- Distortion mux, from ctrl_regs' bits (switch or PC): distortion off ->
    -- dry, straight from i2s_rx (soft ignored); distortion on -> soft picks
    -- soft clip ('1') or hard clip ('0'). Sample and valid switch together.
    -- The paths have different delays (hard 2 clocks, soft 3, dry 0); that's
    -- fine, the blocks after only act on valid.
    -- The last branch has no condition, so every setting has an answer (no
    -- latch).
    s_fx_sample <= s_rx_sample when s_fx_distortion = '0' else  -- distortion off: dry
                   s_soft_clip_sample when s_fx_soft = '1' else -- soft on: soft clip
                   s_clip_sample;                               -- soft off: hard clip

    s_fx_sample_valid <= s_rx_sample_valid when s_fx_distortion = '0' else
                         s_soft_clip_sample_valid when s_fx_soft = '1' else
                         s_clip_sample_valid;

    -- Tremolo mux, from ctrl_regs' bit (switch or PC): off -> the distortion
    -- mux's output, straight through; on -> the tremolo's. The tremolo runs
    -- all the time, so switching is instant (its LFO keeps its place either
    -- way).
    s_mod_sample <= s_fx_sample when s_fx_tremolo = '0' else -- tremolo off
                    s_tremolo_sample;                        -- tremolo on

    s_mod_sample_valid <= s_fx_sample_valid when s_fx_tremolo = '0' else
                          s_tremolo_sample_valid;

    -- Tone mux, from SW3 or the PC (ctrl_regs): off -> the tremolo mux's output,
    -- straight through; on -> the filtered one. The filter runs all the
    -- time, so its state is always up to date and switching is instant.
    s_eq_sample <= s_mod_sample when s_fx_tone = '0' else -- tone filter off
                   s_lowpass_sample;                      -- tone filter on

    s_eq_sample_valid <= s_mod_sample_valid when s_fx_tone = '0' else
                         s_lowpass_sample_valid;

    -- One set of I2S clocks for both Pmod rows.
    da_mclk <= s_mclk;
    ad_mclk <= s_mclk;
    da_lrck <= s_lrck;
    da_sclk <= s_sclk;
    ad_lrck <= s_lrck;
    ad_sclk <= s_sclk;

end architecture rtl;
