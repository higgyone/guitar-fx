-- top: guitar-fx top level for the Arty A7-35T with a Pmod I2S2 on JA.
--
-- Audio path (one sample per frame, 48 kHz, 24-bit, mono = left channel in,
-- the same sample to both channels out):
--
--   ad_sdout -> i2s_rx -> soft_start -> output_gain_stage -> i2s_tx -> da_sdin
--
-- output_gain_stage sets the output level for whatever the DAC feeds. It
-- is last in the chain (effects will go before soft_start), so effects see
-- the guitar's real level whatever the output is plugged into.
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
-- Pins: constraints/Arty-A7-35-Master.xdc. Testbench: sim/top_tb.vhd.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity top is
    generic (
        g_mute_samples : natural                               := 144000; -- 3 s at 48 kHz
        g_ramp_bits    : natural                               := 11;     -- 2,048-sample ramp
        g_gain         : integer range -2 ** 17 to 2 ** 17 - 1 := 1024    -- 1/32 = -30.1 dB in Q3.15
    );
    port (
        clk100mhz  : in    std_logic; -- 100 MHz board clock (E3)
        reset_btn  : in    std_logic; -- BTN0, '1' while pressed
        ad_sdout   : in    std_logic; -- Pmod AD SDOUT (ADC data in)
        led_locked : out   std_logic; -- LD4: MMCM locked
        da_mclk    : out   std_logic; -- Pmod DA row: DAC clocks and data
        da_lrck    : out   std_logic;
        da_sclk    : out   std_logic;
        da_sdin    : out   std_logic;
        ad_mclk    : out   std_logic; -- Pmod AD row: ADC clocks
        ad_lrck    : out   std_logic;
        ad_sclk    : out   std_logic
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

    -- i2s_rx -> soft_start ("out" of i2s_rx).
    signal s_sample_out       : signed(23 downto 0);
    signal s_sample_out_valid : std_logic;
    -- soft_start -> output_gain_stage.
    signal s_soft_sample_out       : signed(23 downto 0);
    signal s_soft_sample_out_valid : std_logic;
    -- output_gain_stage -> i2s_tx ("in" of i2s_tx).
    signal s_sample_in       : signed(23 downto 0);
    signal s_sample_in_valid : std_logic;

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
            sample_in       => s_sample_in,
            sample_in_valid => s_sample_in_valid,
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
            sample_out       => s_sample_out,
            sample_out_valid => s_sample_out_valid
        );

    soft_start_stage : entity work.soft_start
        generic map (
            g_mute_samples => g_mute_samples,
            g_ramp_bits    => g_ramp_bits
        )
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_sample_out,
            sample_in_valid  => s_sample_out_valid,
            sample_out       => s_soft_sample_out,
            sample_out_valid => s_soft_sample_out_valid
        );

    -- Output level: a fixed gain (g_gain), last before the DAC.
    output_gain_stage : entity work.gain_stage
        port map (
            clk              => s_clk,
            reset            => s_reset,
            sample_in        => s_soft_sample_out,
            sample_in_valid  => s_soft_sample_out_valid,
            gain             => to_signed(g_gain, 18),
            sample_out       => s_sample_in,
            sample_out_valid => s_sample_in_valid
        );

    -- Reset synchroniser: two flip-flops on s_clk.
    reset_sync : process (s_clk) is
    begin

        if rising_edge(s_clk) then
            s_reset_meta <= s_reset_raw;  -- FF1 takes the raw input
            s_reset      <= s_reset_meta; -- FF2 (clean)
        end if;

    end process reset_sync;

    s_reset_raw <= reset_btn or not s_locked;
    led_locked  <= s_locked;

    -- One set of I2S clocks for both Pmod rows.
    da_mclk <= s_mclk;
    ad_mclk <= s_mclk;
    da_lrck <= s_lrck;
    da_sclk <= s_sclk;
    ad_lrck <= s_lrck;
    ad_sclk <= s_sclk;

end architecture rtl;
