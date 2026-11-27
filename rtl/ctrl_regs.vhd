-- ctrl_regs: the settings the PC can write and read over the UART, and the
-- switch-or-PC choice for the effects. Written by cmd_decoder (one write per
-- 3-byte command); read back the same way.
--
-- Register map (16-bit values, as the PC sends them):
--   0x00 R/W control: bit 0 distortion on, bit 1 soft clip (else hard),
--                     bit 2 tremolo on, bit 3 tone filter on,
--                     bit 4 delay on (PC only), bit 7 PC control
--   0x01 R/W output gain, Q3.13   -> out_gain   = value & "00"      (Q3.15)
--   0x02 R/W drive gain,  Q3.13   -> drive_gain = value & "00"      (Q3.15)
--   0x03 R/W clip threshold, Q0.16 -> threshold = value & 7 zeros   (Q0.23)
--   0x04 R/W tremolo depth, Q1.15 unsigned, 0 .. 1.0 (0x8000)
--            -> tremolo_depth = "00" & value (18-bit signed Q.15)
--   0x05 R/W tremolo rate, phase step / 256 (step 0.00286 Hz, max 187 Hz)
--            -> tremolo_step = 8 zeros & value & 8 zeros (32 bits)
--   0x06 R/W delay time, in samples (48 kHz), 1 .. 0x7FFF (683 ms)
--            -> delay_samples = bits 14..0; 0x8000 and above clamp to
--               0x7FFF (the register keeps what was written)
--   0x07 R/W delay feedback, Q1.15 unsigned, 0 .. below 1.0
--            -> delay_feedback = "00" & value (delay_stage clamps >= 1.0)
--   0x08 R/W delay mix, Q1.15 unsigned, 0 dry .. 1.0 (0x8000) echo only
--            -> delay_mix = "00" & value
--   0x10 R   live state: bits 0..3 the effects actually on, bits 4..6 the
--            switches SW0..SW2, bit 7 PC control, bit 8 the switch SW3,
--            bit 9 the delay actually on
--   0x7F R   version (g_version)
-- Padding with zeros at the bottom adds fraction bits: same value, the sign
-- bit stays on top. Any other register: not valid (cmd_decoder replies NAK);
-- writing 0x10 or 0x7F: not writable (NAK too).
--
-- reg_addr bit 7 is cmd_decoder's read flag; the register number is bits
-- 6..0. reg_addr_valid, reg_addr_writable and reg_rdata answer straight
-- away (no clock), so they are ready long before the command's third byte.
--
-- Switches or PC: while bit 7 of 0x00 is '0' (the default), fx_* follow the
-- board switches (sw_*); once the PC sets it, fx_* follow bits 0..4.
-- The delay has no switch (all four are taken): it is off unless the PC
-- turns it on.
--
-- Reset (and power-up) sets every register to its default generic, given in
-- the register formats above; the defaults match the pedal's fixed settings
-- before the UART, so with no PC it behaves exactly as before.
--
-- Testbench: sim/ctrl_regs_tb.vhd. Design notes: docs/uart.md, section 5.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity ctrl_regs is
    generic (
        g_default_ctrl      : natural := 0;     -- bit 7 = 0: switches decide
        g_default_out_gain  : natural := 256;   -- Q3.13: 1/32
        g_default_drive     : natural := 16384; -- Q3.13: x2.0
        g_default_threshold : natural := 8192;  -- Q0.16: 0.125
        g_default_depth     : natural := 16384; -- Q1.15: 0.5
        g_default_rate      : natural := 1748;  -- step / 256: 5 Hz at 48 kHz
        g_default_delay     : natural := 12000; -- samples: 250 ms at 48 kHz
        g_default_feedback  : natural := 16384; -- Q1.15: 0.5
        g_default_mix       : natural := 16384; -- Q1.15: 0.5
        g_version           : natural := 3      -- read back at 0x7F (3: the delay registers)
    );
    port (
        clk   : in    std_logic; -- s_clk, 98.305 MHz
        reset : in    std_logic; -- synchronous, active high
        -- from cmd_decoder: a write, and the register being addressed
        reg_addr  : in    std_logic_vector(7 downto 0);  -- bit 7 = read flag, 6..0 = register
        reg_data  : in    std_logic_vector(15 downto 0); -- value to write
        reg_write : in    std_logic;                     -- one-clock pulse: store reg_data
        -- the board switches, already synchronised in top
        sw_distortion : in    std_logic; -- SW0
        sw_soft       : in    std_logic; -- SW1
        sw_tremolo    : in    std_logic; -- SW2
        sw_tone       : in    std_logic; -- SW3
        -- to cmd_decoder: answers about reg_addr, no clock
        reg_addr_valid    : out   std_logic;                     -- '1': the register exists
        reg_addr_writable : out   std_logic;                     -- '1': it can be written
        reg_rdata         : out   std_logic_vector(15 downto 0); -- its value, for a read
        -- to the effects
        fx_distortion  : out   std_logic;             -- effective: switch or PC
        fx_soft        : out   std_logic;
        fx_tremolo     : out   std_logic;
        fx_tone        : out   std_logic;
        out_gain       : out   signed(17 downto 0);   -- Q3.15, to output_gain_stage
        drive_gain     : out   signed(17 downto 0);   -- Q3.15, to drive_gain_stage
        threshold      : out   unsigned(22 downto 0); -- Q0.23, to clip_stage
        tremolo_depth  : out   signed(17 downto 0);   -- Q.15, to tremolo_stage
        tremolo_step   : out   unsigned(31 downto 0); -- phase step, to tremolo_stage
        fx_delay       : out   std_logic;             -- effective: PC only, no switch
        delay_samples  : out   unsigned(14 downto 0); -- samples back, to delay_stage
        delay_feedback : out   signed(17 downto 0);   -- Q.15, to delay_stage
        delay_mix      : out   signed(17 downto 0)    -- Q.15, to delay_stage
    );
end entity ctrl_regs;

architecture rtl of ctrl_regs is

    -- Stored registers 0x00 .. 0x08 (16 bits each, as the PC sends them),
    -- starting at the defaults (power-up; reset sets them again).
    signal s_reg_ctrl           : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(g_default_ctrl, 16));
    signal s_reg_out_gain       : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(g_default_out_gain, 16));
    signal s_reg_drive          : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(g_default_drive, 16));
    signal s_reg_threshold      : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(g_default_threshold, 16));
    signal s_reg_tremolo_depth  : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(g_default_depth, 16));
    signal s_reg_tremolo_rate   : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(g_default_rate, 16));
    signal s_reg_delay          : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(g_default_delay, 16));
    signal s_reg_delay_feedback : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(g_default_feedback, 16));
    signal s_reg_delay_mix      : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(g_default_mix, 16));

    signal s_addr       : natural range 0 to 127;        -- register number: reg_addr bits 6..0
    signal s_pc_control : std_logic;                     -- register 0x00 bit 7
    signal s_live       : std_logic_vector(15 downto 0); -- register 0x10: the live state

begin

    s_addr <= to_integer(unsigned(reg_addr(6 downto 0)));

    -- Writes (clocked): reset loads the defaults; a reg_write pulse stores
    -- reg_data in the register s_addr names. Read-only and unknown numbers
    -- store nothing (cmd_decoder only writes valid, writable ones anyway).
    write_proc : process (clk) is
    begin

        if rising_edge(clk) then
            if (reset = '1') then
                s_reg_ctrl           <= std_logic_vector(to_unsigned(g_default_ctrl, 16));
                s_reg_out_gain       <= std_logic_vector(to_unsigned(g_default_out_gain, 16));
                s_reg_drive          <= std_logic_vector(to_unsigned(g_default_drive, 16));
                s_reg_threshold      <= std_logic_vector(to_unsigned(g_default_threshold, 16));
                s_reg_tremolo_depth  <= std_logic_vector(to_unsigned(g_default_depth, 16));
                s_reg_tremolo_rate   <= std_logic_vector(to_unsigned(g_default_rate, 16));
                s_reg_delay          <= std_logic_vector(to_unsigned(g_default_delay, 16));
                s_reg_delay_feedback <= std_logic_vector(to_unsigned(g_default_feedback, 16));
                s_reg_delay_mix      <= std_logic_vector(to_unsigned(g_default_mix, 16));
            elsif (reg_write = '1') then

                case s_addr is

                    when 0 =>

                        s_reg_ctrl <= reg_data;

                    when 1 =>

                        s_reg_out_gain <= reg_data;

                    when 2 =>

                        s_reg_drive <= reg_data;

                    when 3 =>

                        s_reg_threshold <= reg_data;

                    when 4 =>

                        s_reg_tremolo_depth <= reg_data;

                    when 5 =>

                        s_reg_tremolo_rate <= reg_data;

                    when 6 =>

                        s_reg_delay <= reg_data;

                    when 7 =>

                        s_reg_delay_feedback <= reg_data;

                    when 8 =>

                        s_reg_delay_mix <= reg_data;

                    when others =>

                        null;             -- read-only or unknown

                end case;

            end if;
        end if;

    end process write_proc;

    -- Reads (no clock): answers about reg_addr straight away. Every output
    -- is given a default first, so each one is assigned on every path;
    -- without that, synthesis would build a latch to hold the old value.
    read_proc : process (all) is
    begin

        reg_rdata         <= (others => '0');
        reg_addr_valid    <= '0';
        reg_addr_writable <= '0';

        case s_addr is

            when 0 =>

                reg_rdata         <= s_reg_ctrl;
                reg_addr_valid    <= '1';
                reg_addr_writable <= '1';

            when 1 =>

                reg_rdata         <= s_reg_out_gain;
                reg_addr_valid    <= '1';
                reg_addr_writable <= '1';

            when 2 =>

                reg_rdata         <= s_reg_drive;
                reg_addr_valid    <= '1';
                reg_addr_writable <= '1';

            when 3 =>

                reg_rdata         <= s_reg_threshold;
                reg_addr_valid    <= '1';
                reg_addr_writable <= '1';

            when 4 =>

                reg_rdata         <= s_reg_tremolo_depth;
                reg_addr_valid    <= '1';
                reg_addr_writable <= '1';

            when 5 =>

                reg_rdata         <= s_reg_tremolo_rate;
                reg_addr_valid    <= '1';
                reg_addr_writable <= '1';

            when 6 =>

                reg_rdata         <= s_reg_delay;
                reg_addr_valid    <= '1';
                reg_addr_writable <= '1';

            when 7 =>

                reg_rdata         <= s_reg_delay_feedback;
                reg_addr_valid    <= '1';
                reg_addr_writable <= '1';

            when 8 =>

                reg_rdata         <= s_reg_delay_mix;
                reg_addr_valid    <= '1';
                reg_addr_writable <= '1';

            when 16#10# =>                                                      -- live state: read only

                reg_rdata      <= s_live;
                reg_addr_valid <= '1';

            when 16#7F# =>                                                      -- version: read only

                reg_rdata      <= std_logic_vector(to_unsigned(g_version, 16));
                reg_addr_valid <= '1';

            when others =>

                null;                                                           -- unknown: stays not valid

        end case;

    end process read_proc;

    -- Switches or PC: control bit 7 picks where each effect's on/off comes
    -- from (a 2-input mux per effect).
    s_pc_control  <= s_reg_ctrl(7);
    fx_distortion <= s_reg_ctrl(0) when s_pc_control = '1' else
                     sw_distortion;
    fx_soft       <= s_reg_ctrl(1) when s_pc_control = '1' else
                     sw_soft;
    fx_tremolo    <= s_reg_ctrl(2) when s_pc_control = '1' else
                     sw_tremolo;
    fx_tone       <= s_reg_ctrl(3) when s_pc_control = '1' else
                     sw_tone;
    fx_delay      <= s_reg_ctrl(4) when s_pc_control = '1' else
                     '0';

    -- Settings to the effects: zeros at the bottom add fraction bits; zeros
    -- on top widen an unsigned value (the depth is unsigned until "00" makes
    -- it a positive signed number). The step is in turns per sample:
    -- register Q0.24, step Q0.32 (2**32 = one turn).
    out_gain       <= signed(s_reg_out_gain) & "00";                          -- Q3.13 -> Q3.15
    drive_gain     <= signed(s_reg_drive) & "00";                             -- Q3.13 -> Q3.15
    threshold      <= unsigned(s_reg_threshold) & "0000000";                  -- Q0.16 -> Q0.23
    tremolo_depth  <= signed("00" & s_reg_tremolo_depth);                     -- Q1.15 -> Q.15
    tremolo_step   <= unsigned("00000000" & s_reg_tremolo_rate & "00000000"); -- Q0.24 -> Q0.32
    delay_feedback <= signed("00" & s_reg_delay_feedback);                    -- Q1.15 -> Q.15
    delay_mix      <= signed("00" & s_reg_delay_mix);                         -- Q1.15 -> Q.15

    -- Delay time clamp: the register is 16 bits, delay_samples 15. Bit 15
    -- set means 32768 or more, so give the maximum (0x7FFF, 683 ms) rather
    -- than drop the bit and wrap to a short delay.
    delay_samples <= (others => '1') when s_reg_delay(15) = '1' else
                     unsigned(s_reg_delay(14 downto 0));

    -- Register 0x10: what the effects are really doing, and the switches.
    s_live <=
    (
        0      => fx_distortion,
        1      => fx_soft,
        2      => fx_tremolo,
        3      => fx_tone,
        4      => sw_distortion,
        5      => sw_soft,
        6      => sw_tremolo,
        7      => s_pc_control,
        8      => sw_tone,
        9      => fx_delay,
        others => '0'
    );

end architecture rtl;
