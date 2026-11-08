-- top: guitar-fx top level for the Arty A7-35T with a Pmod I2S2 on JA.
--
-- Audio path (one sample per frame, 48 kHz, 24-bit, mono = left channel in,
-- the same sample to both channels out):
--
--   ad_sdout -> i2s_rx -+-> drive_gain_stage -> clip_stage -+-> bypass mux
--                       +---------------- bypass -----------+       |
--        da_sdin <- i2s_tx <- output_gain_stage <- soft_start <------+
--
-- Distortion (effect #2): drive_gain_stage (a gain_stage, g_drive_gain)
-- pushes the signal into clip_stage (hard_clip_stage, g_threshold). SW0
-- (distortion_sw, synchronised to s_clk) picks the clipped signal ('1') or
-- the bypass ('0'). Effects go before soft_start, so its mute and fade-in
-- apply to the effected signal.
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
-- top_tb makes them tiny). g_gain is output_gain_stage's gain in Q3.15
-- (1.0 = 32768): default 1024 = 1/32 = -30.1 dB, line level for the PC's
-- USB mic input; top_tb uses 1.0 so it can check exact pass-through.
-- g_drive_gain (Q3.15) and g_threshold (Q0.23) set the distortion. Defaults
-- x2.0 and 0.125, for this guitar through the preamp at G = 3 (a hard strum
-- reaches the drive at ~0.33 of full scale): a strum is driven ~5x (+14 dB)
-- over the clip, and notes clean up as they decay below ~0.06. The output is
-- then about the threshold, so SW0 up is quieter than SW0 down. x1.0 with
-- the maximum threshold (2**23 - 1) makes the distortion do nothing.
--
-- Test tone: g_test_tone = true sends tone_gen's 1 kHz, -20 dBFS sine
-- straight to i2s_tx instead of the audio path, to check the DAC and line
-- out with nothing plugged into the line in. Leave it false for normal use.
-- Pins: constraints/Arty-A7-35-Master.xdc. Testbench: sim/top_tb.vhd.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity top is
    generic (
        g_mute_samples : natural                               := 144000;  -- 3 s at 48 kHz
        g_ramp_bits    : natural                               := 11;      -- 2,048-sample ramp
        g_gain         : integer range -2 ** 17 to 2 ** 17 - 1 := 1024;    -- 1/32 = -30.1 dB in Q3.15
        g_test_tone    : boolean                               := false;   -- true: 1 kHz test tone to the DAC
        g_threshold    : integer range 0 to 2 ** 23 - 1        := 2 ** 20; -- clip level, Q0.23; 2**20 = 0.125 (max 2**23 - 1 = no clipping)
        g_drive_gain   : integer range -2 ** 17 to 2 ** 17 - 1 := 2 ** 16  -- drive before the clip, Q3.15; 2**16 = x2.0 (2**15 = x1.0)
    );
    port (
        clk100mhz     : in    std_logic; -- 100 MHz board clock (E3)
        reset_btn     : in    std_logic; -- BTN0, '1' while pressed
        distortion_sw : in    std_logic; -- SW0, '1' = distortion on
        ad_sdout      : in    std_logic; -- Pmod AD SDOUT (ADC data in)
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

    -- i2s_rx -> drive_gain_stage and the bypass mux.
    signal s_rx_sample       : signed(23 downto 0);
    signal s_rx_sample_valid : std_logic;
    -- drive_gain_stage -> clip_stage.
    signal s_drive_sample       : signed(23 downto 0);
    signal s_drive_sample_valid : std_logic;
    -- clip_stage -> bypass mux.
    signal s_clip_sample       : signed(23 downto 0);
    signal s_clip_sample_valid : std_logic;
    -- bypass mux -> soft_start.
    signal s_fx_sample       : signed(23 downto 0);
    signal s_fx_sample_valid : std_logic;
    -- soft_start -> output_gain_stage.
    signal s_soft_sample       : signed(23 downto 0);
    signal s_soft_sample_valid : std_logic;
    -- output_gain_stage -> the test-tone switch.
    signal s_gain_sample       : signed(23 downto 0);
    signal s_gain_sample_valid : std_logic;
    -- tone_gen -> the test-tone switch.
    signal s_tone_sample       : signed(23 downto 0);
    signal s_tone_sample_valid : std_logic;
    -- The test-tone switch -> i2s_tx.
    signal s_tx_sample       : signed(23 downto 0);
    signal s_tx_sample_valid : std_logic;

    -- Distortion switch (SW0) synchroniser. Starts at '0' (bypassed), the
    -- plain state, until the real switch position arrives two clocks later.
    signal s_distortion_raw  : std_logic;        -- distortion_sw as read (not on s_clk)
    signal s_distortion_meta : std_logic := '0'; -- FF1: may go metastable
    signal s_distortion      : std_logic := '0'; -- FF2: clean switch state, '1' = distortion on

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

    -- Distortion, part 1, drive: a fixed gain (g_drive_gain) that pushes the
    -- signal up into the clip. Default x2.0.
    drive_gain_stage : entity work.gain_stage
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_rx_sample,
            sample_in_valid  => s_rx_sample_valid,
            gain             => to_signed(g_drive_gain, 18),
            sample_out       => s_drive_sample,
            sample_out_valid => s_drive_sample_valid
        );

    -- Distortion, part 2, clip: flattens every sample beyond +/- g_threshold.
    -- Default 0.125.
    clip_stage : entity work.hard_clip_stage
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_drive_sample,
            sample_in_valid  => s_drive_sample_valid,
            threshold        => to_unsigned(g_threshold, 23),
            sample_out       => s_clip_sample,
            sample_out_valid => s_clip_sample_valid
        );

    soft_start_stage : entity work.soft_start
        generic map (
            g_mute_samples => g_mute_samples,
            g_ramp_bits    => g_ramp_bits
        )
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_fx_sample,
            sample_in_valid  => s_fx_sample_valid,
            sample_out       => s_soft_sample,
            sample_out_valid => s_soft_sample_valid
        );

    -- Output level: a fixed gain (g_gain), last before the DAC.
    output_gain_stage : entity work.gain_stage
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_soft_sample,
            sample_in_valid  => s_soft_sample_valid,
            gain             => to_signed(g_gain, 18),
            sample_out       => s_gain_sample,
            sample_out_valid => s_gain_sample_valid
        );

    -- Test tone: a 1 kHz sine, one sample per frame.
    tone_stage : entity work.tone_gen
        port map (
            clk              => s_clk,
            reset            => s_reset,
            frame_start      => s_frame_start,
            sample_out       => s_tone_sample,
            sample_out_valid => s_tone_sample_valid
        );

    -- The test-tone switch: g_test_tone picks what i2s_tx sends. It is a
    -- generic, so synthesis keeps only the chosen side.
    s_tx_sample       <= s_tone_sample when g_test_tone else
                         s_gain_sample;
    s_tx_sample_valid <= s_tone_sample_valid when g_test_tone else
                         s_gain_sample_valid;

    -- Reset synchroniser: two flip-flops on s_clk.
    reset_sync : process (s_clk) is
    begin

        if rising_edge(s_clk) then
            s_reset_meta <= s_reset_raw;  -- FF1 takes the raw input
            s_reset      <= s_reset_meta; -- FF2 (clean)
        end if;

    end process reset_sync;

    -- Distortion switch synchroniser: two flip-flops on s_clk, as reset_sync.
    -- The slide switch is not on s_clk, so it can change at any moment.
    distortion_sync : process (s_clk) is
    begin

        if rising_edge(s_clk) then
            s_distortion_meta <= s_distortion_raw;  -- FF1 takes the raw input
            s_distortion      <= s_distortion_meta; -- FF2 (clean)
        end if;

    end process distortion_sync;

    s_distortion_raw <= distortion_sw;
    s_reset_raw      <= reset_btn or not s_locked;
    led_locked       <= s_locked;

    -- Bypass mux: SW0 picks the distorted signal (clip_stage, '1') or the
    -- dry one straight from i2s_rx ('0'). Sample and valid switch together.
    -- The distorted path is 2 clocks later than the dry one; that's fine,
    -- soft_start only acts on valid.
    s_fx_sample       <= s_clip_sample when s_distortion = '1' else
                         s_rx_sample;
    s_fx_sample_valid <= s_clip_sample_valid when s_distortion = '1' else
                         s_rx_sample_valid;

    -- One set of I2S clocks for both Pmod rows.
    da_mclk <= s_mclk;
    ad_mclk <= s_mclk;
    da_lrck <= s_lrck;
    da_sclk <= s_sclk;
    ad_lrck <= s_lrck;
    ad_sclk <= s_sclk;

end architecture rtl;
