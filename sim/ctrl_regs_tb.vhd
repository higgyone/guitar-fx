-- Self-checking testbench for ctrl_regs.
--
-- Drives the cmd_decoder side (reg_addr, reg_data, reg_write) and the
-- switches directly, and checks every output.
--
-- Checks:
--   1. After reset: the defaults read back (0x00..0x03), and the outputs
--      are the defaults converted: out_gain 256 & "00" = 1024 (1/32 in
--      Q3.15), drive 16384 & "00" = 65536 (x2.0), threshold 8192 & 7 zeros
--      = 2**20 (0.125 in Q0.23). PC control off: fx_* follow the switches.
--   2. Address decode: 0x00..0x03 valid + writable; 0x10 and 0x7F valid,
--      read only; 0x04, 0x0F, 0x11, 0x7E not valid. The read flag (bit 7)
--      is ignored: 0x81 answers like 0x01.
--   3. Writes: each register stores reg_data, reads it back, and its output
--      changes to the converted value.
--   4. A write pulse to a read-only or unknown address changes nothing.
--   5. Switches vs PC: control bit 7 = 0 -> fx_* = switches (all 8
--      combinations); bit 7 = 1 -> fx_* = control bits 0..2, whatever the
--      switches do. The live-state register 0x10 matches every time.
--   6. Version at 0x7F = g_version (set to 3 here).
--   7. Reset after writes brings the defaults back.
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/ctrl_regs.vhd sim/ctrl_regs_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP ctrl_regs_tb

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity ctrl_regs_tb is
end entity ctrl_regs_tb;

architecture sim of ctrl_regs_tb is

    constant clk_period : time := 10.172 ns;

    signal clk               : std_logic                     := '0';
    signal reset             : std_logic                     := '1';
    signal reg_addr          : std_logic_vector(7 downto 0)  := (others => '0');
    signal reg_data          : std_logic_vector(15 downto 0) := (others => '0');
    signal reg_write         : std_logic                     := '0';
    signal sw_distortion     : std_logic                     := '0';
    signal sw_soft           : std_logic                     := '0';
    signal sw_tremolo        : std_logic                     := '0';
    signal reg_addr_valid    : std_logic;
    signal reg_addr_writable : std_logic;
    signal reg_rdata         : std_logic_vector(15 downto 0);
    signal fx_distortion     : std_logic;
    signal fx_soft           : std_logic;
    signal fx_tremolo        : std_logic;
    signal out_gain          : signed(17 downto 0);
    signal drive_gain        : signed(17 downto 0);
    signal threshold         : unsigned(22 downto 0);

begin

    clk <= not clk after clk_period / 2;

    dut : entity work.ctrl_regs
        generic map (
            g_version => 3
        )
        port map (
            clk               => clk,
            reset             => reset,
            reg_addr          => reg_addr,
            reg_data          => reg_data,
            reg_write         => reg_write,
            sw_distortion     => sw_distortion,
            sw_soft           => sw_soft,
            sw_tremolo        => sw_tremolo,
            reg_addr_valid    => reg_addr_valid,
            reg_addr_writable => reg_addr_writable,
            reg_rdata         => reg_rdata,
            fx_distortion     => fx_distortion,
            fx_soft           => fx_soft,
            fx_tremolo        => fx_tremolo,
            out_gain          => out_gain,
            drive_gain        => drive_gain,
            threshold         => threshold
        );

    stimulus : process is

        -- Points reg_addr at a register and checks the combinational answers.

        procedure check_addr (
            constant addr     : in natural;
            constant valid    : in std_logic;
            constant writable : in std_logic
        ) is
        begin

            reg_addr <= std_logic_vector(to_unsigned(addr, 8));
            wait for 1 ns;
            assert reg_addr_valid = valid and reg_addr_writable = writable
                report "address 0x" & to_hstring(to_unsigned(addr, 8)) & ": valid "
                       & std_logic'image(reg_addr_valid) & ", writable "
                       & std_logic'image(reg_addr_writable) & "; expected "
                       & std_logic'image(valid) & ", " & std_logic'image(writable)
                severity failure;

        end procedure check_addr;

        -- Reads a register (read flag set, as the decoder would) and checks it.

        procedure check_read (
            constant addr  : in natural;
            constant value : in natural
        ) is
        begin

            reg_addr <= std_logic_vector(to_unsigned(16#80# + addr, 8));
            wait for 1 ns;
            assert reg_addr_valid = '1'
                report "read 0x" & to_hstring(to_unsigned(addr, 8)) & ": not valid"
                severity failure;
            assert unsigned(reg_rdata) = value
                report "read 0x" & to_hstring(to_unsigned(addr, 8)) & ": got 0x"
                       & to_hstring(reg_rdata) & ", expected 0x"
                       & to_hstring(to_unsigned(value, 16))
                severity failure;

        end procedure check_read;

        -- One write pulse, as the decoder gives it.

        procedure write_reg (
            constant addr  : in natural;
            constant value : in natural
        ) is
        begin

            wait until rising_edge(clk);
            reg_addr  <= std_logic_vector(to_unsigned(addr, 8));
            reg_data  <= std_logic_vector(to_unsigned(value, 16));
            reg_write <= '1';
            wait until rising_edge(clk);
            reg_write <= '0';
            wait until rising_edge(clk);

        end procedure write_reg;

        -- Checks the three converted outputs.

        procedure check_outputs (
            constant name : in string;
            constant og   : in integer;
            constant dg   : in integer;
            constant th   : in natural
        ) is
        begin

            wait for 1 ns;
            assert out_gain = og
                report name & ": out_gain " & integer'image(to_integer(out_gain))
                       & ", expected " & integer'image(og)
                severity failure;
            assert drive_gain = dg
                report name & ": drive_gain " & integer'image(to_integer(drive_gain))
                       & ", expected " & integer'image(dg)
                severity failure;
            assert threshold = th
                report name & ": threshold " & integer'image(to_integer(threshold))
                       & ", expected " & integer'image(th)
                severity failure;

        end procedure check_outputs;

        -- Checks fx_* and the live-state register for given expected bits.

        procedure check_fx (
            constant name    : in string;
            constant d, s, t : in std_logic;
            constant pc      : in std_logic
        ) is

            variable live : std_logic_vector(15 downto 0);

        begin

            wait for 1 ns;
            assert fx_distortion = d and fx_soft = s and fx_tremolo = t
                report name & ": fx = " & std_logic'image(fx_distortion)
                       & std_logic'image(fx_soft) & std_logic'image(fx_tremolo)
                       & ", expected " & std_logic'image(d) & std_logic'image(s)
                       & std_logic'image(t)
                severity failure;
            live :=
            (
                0 => d,
                1 => s,
                2 => t,
                4 => sw_distortion,
                5 => sw_soft,
                6 => sw_tremolo,
                7 => pc,
                others => '0'
            );
            check_read(16#10#, to_integer(unsigned(live)));

        end procedure check_fx;

        variable sw : unsigned(2 downto 0);

    begin

        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';
        wait until rising_edge(clk);

        -- 1. Defaults.
        check_read(0, 0);
        check_read(1, 256);
        check_read(2, 16384);
        check_read(3, 8192);
        check_outputs("defaults", 1024, 65536, 2 ** 20);
        report "1 defaults: ok"
            severity note;

        -- 2. Address decode.
        for a in 0 to 3 loop

            check_addr(a, '1', '1');
            check_addr(16#80# + a, '1', '1');                                         -- read flag ignored

        end loop;

        check_addr(16#10#, '1', '0');
        check_addr(16#7F#, '1', '0');
        check_addr(16#FF#, '1', '0');                                                 -- read of 0x7F

        for a in 0 to 127 loop

            if (a > 3 and a /= 16#10# and a /= 16#7F#) then
                check_addr(a, '0', '0');
            end if;

        end loop;

        report "2 address decode: ok"
            severity note;

        -- 3. Writes, read back, converted outputs.
        write_reg(1, 16#1000#);                                                       -- out gain 0.5
        write_reg(2, 16#6000#);                                                       -- drive x3.0
        write_reg(3, 16#7FFF#);                                                       -- threshold just under 0.5
        check_read(1, 16#1000#);
        check_read(2, 16#6000#);
        check_read(3, 16#7FFF#);
        check_outputs("after writes", 16#1000# * 4, 16#6000# * 4, 16#7FFF# * 128);
        -- -1 LSB: a negative gain must stay negative after the "00" padding
        write_reg(1, 16#FFFF#);
        check_outputs("negative gain", -4, 16#6000# * 4, 16#7FFF# * 128);
        report "3 writes: ok"
            severity note;

        -- 4. Writes to read-only / unknown addresses change nothing.
        write_reg(16#10#, 16#ABCD#);
        write_reg(16#7F#, 16#ABCD#);
        write_reg(16#04#, 16#ABCD#);
        write_reg(16#55#, 16#ABCD#);
        check_read(0, 0);
        check_read(1, 16#FFFF#);
        check_read(2, 16#6000#);
        check_read(3, 16#7FFF#);
        check_read(16#7F#, 3);
        report "4 read-only and unknown writes ignored: ok"
            severity note;

        -- 5. Switches vs PC.
        for i in 0 to 7 loop                                                          -- PC control off: switches

            sw            := to_unsigned(i, 3);
            sw_distortion <= sw(0);
            sw_soft       <= sw(1);
            sw_tremolo    <= sw(2);
            wait for 1 ns;
            check_fx("switches " & integer'image(i), sw(0), sw(1), sw(2), '0');

        end loop;

        -- PC control on, distortion + tremolo on, soft off
        write_reg(0, 16#0085#);

        for i in 0 to 7 loop                                                          -- switches must not matter now

            sw            := to_unsigned(i, 3);
            sw_distortion <= sw(0);
            sw_soft       <= sw(1);
            sw_tremolo    <= sw(2);
            wait for 1 ns;
            check_fx("PC control, switches " & integer'image(i), '1', '0', '1', '1');

        end loop;

        write_reg(0, 16#0002#);                                                       -- back to switches (bit 7 = 0)
        check_fx("back to switches", sw_distortion, sw_soft, sw_tremolo, '0');
        report "5 switches vs PC: ok"
            severity note;

        -- 6. Version.
        check_read(16#7F#, 3);
        report "6 version: ok"
            severity note;

        -- 7. Reset brings the defaults back.
        wait until rising_edge(clk);
        reset <= '1';
        wait until rising_edge(clk);
        reset <= '0';
        wait until rising_edge(clk);
        check_read(0, 0);
        check_read(1, 256);
        check_read(2, 16384);
        check_read(3, 8192);
        check_outputs("after reset", 1024, 65536, 2 ** 20);
        report "7 reset: ok"
            severity note;

        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
