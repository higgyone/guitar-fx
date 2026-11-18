-- Self-checking testbench for cmd_decoder (writes and reads).
--
-- No UART here: the testbench drives rx_data / rx_valid / rx_frame_error
-- directly, as uart_rx would (one-clock pulses), with c_byte_gap clocks
-- between the bytes of a command (stands in for one byte time).
--
-- Fake ctrl_regs (register number = reg_addr bits 6..0):
--   0x00 .. 0x05  valid, writable, read value 0xA000 + number
--   0x10          valid, read only, read value s_live & s_live: an 8-bit
--                 counter that steps every clock, in both bytes, so the high
--                 and low bytes of one value are always equal. A read reply
--                 whose two bytes come from different clocks would show
--                 different bytes: this checks the decoder sends a snapshot.
--   others        not valid
--
-- A monitor logs every reply byte (tx_valid) in order, and every register
-- write; it checks both pulses are one clock wide. Each test checks the
-- exact reply bytes and the number of writes since the test started.
--
-- g_timeout_clks is 200 here (not 98305) so the run is short; c_byte_gap
-- (30) is well under it, c_quiet (300) well over it.
--
-- Checks:
--    1. Good write 0x01 0x12 0x34: one write (0x01, 0x1234), reply ACK.
--    2. Write to an unknown register 0x40: no write, NAK.
--    3. Missing byte (only 2 sent): no write, one CAN after the timeout.
--    4. Frame error on byte 2, byte 3 still arrives: no write, one CAN.
--    5. Frame error then a stream of 6 bytes inside the timeout: one CAN.
--    6. Back-to-back: two writes with only a byte gap: two writes, two ACKs.
--    7. Reset in the middle of a command: no write, no reply.
--    8. Read 0x81 (register 0x01): reply ACK 0xA0 0x01, no write.
--    9. Read 0x90 (read-only 0x10, changing value): ACK + two bytes that
--       are equal (one snapshot), no write.
--   10. Write to read-only 0x10: NAK, no write.
--   11. Read of an unknown register (0xC0 = read of 0x40): NAK.
--   12. A read straight after a write, back-to-back: ACK, then ACK + value.
--   After each error case, a good command works again (resync).
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/cmd_decoder.vhd sim/cmd_decoder_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP cmd_decoder_tb

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity cmd_decoder_tb is
end entity cmd_decoder_tb;

architecture sim of cmd_decoder_tb is

    constant clk_period : time    := 10.172 ns;
    constant c_timeout  : natural := 200; -- g_timeout_clks for the test
    constant c_byte_gap : natural := 30;  -- clocks between bytes of one command
    constant c_quiet    : natural := 300; -- clocks of silence: longer than the timeout

    constant c_ack : std_logic_vector(7 downto 0) := x"06";
    constant c_nak : std_logic_vector(7 downto 0) := x"15";
    constant c_can : std_logic_vector(7 downto 0) := x"18";

    type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

    signal clk               : std_logic                    := '0';
    signal reset             : std_logic                    := '1';
    signal rx_data           : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_valid          : std_logic                    := '0';
    signal rx_frame_error    : std_logic                    := '0';
    signal reg_addr_valid    : std_logic;
    signal reg_addr_writable : std_logic;
    signal reg_rdata         : std_logic_vector(15 downto 0);
    signal tx_data           : std_logic_vector(7 downto 0);
    signal tx_valid          : std_logic;
    signal reg_addr          : std_logic_vector(7 downto 0);
    signal reg_data          : std_logic_vector(15 downto 0);
    signal reg_write         : std_logic;

    -- Fake ctrl_regs.
    signal fake_num : natural range 0 to 127;
    signal s_live   : unsigned(7 downto 0) := (others => '0');

    -- Kept by the monitor.
    signal tx_log    : t_bytes(0 to 255)             := (others => (others => '0'));
    signal tx_count  : natural                       := 0;
    signal n_write   : natural                       := 0;
    signal last_addr : std_logic_vector(7 downto 0)  := (others => '0');
    signal last_data : std_logic_vector(15 downto 0) := (others => '0');

begin

    clk <= not clk after clk_period / 2;

    -- Fake ctrl_regs: see the header.
    fake_num          <= to_integer(unsigned(reg_addr(6 downto 0)));
    reg_addr_valid    <= '1' when fake_num <= 5 or fake_num = 16 else
                         '0';
    reg_addr_writable <= '1' when fake_num <= 5 else
                         '0';
    reg_rdata         <= std_logic_vector(s_live & s_live) when fake_num = 16 else
                         std_logic_vector(to_unsigned(16#A000# + fake_num, 16));

    live : process (clk) is
    begin

        if rising_edge(clk) then
            s_live <= s_live + 1;
        end if;

    end process live;

    dut : entity work.cmd_decoder
        generic map (
            g_timeout_clks => c_timeout
        )
        port map (
            clk               => clk,
            reset             => reset,
            rx_data           => rx_data,
            rx_valid          => rx_valid,
            rx_frame_error    => rx_frame_error,
            reg_addr_valid    => reg_addr_valid,
            reg_addr_writable => reg_addr_writable,
            reg_rdata         => reg_rdata,
            tx_data           => tx_data,
            tx_valid          => tx_valid,
            reg_addr          => reg_addr,
            reg_data          => reg_data,
            reg_write         => reg_write
        );

    -- Logs every reply byte and every write; checks reg_write is one clock.
    -- (tx_valid may be high on consecutive clocks: a read reply is 3 bytes.)
    monitor : process is

        variable wr_prev : std_logic := '0';

    begin

        wait until rising_edge(clk);

        if (tx_valid = '1') then
            tx_log(tx_count) <= tx_data;
            tx_count         <= tx_count + 1;
        end if;

        assert not (reg_write = '1' and wr_prev = '1')
            report "reg_write longer than one clock"
            severity failure;

        if (reg_write = '1') then
            n_write   <= n_write + 1;
            last_addr <= reg_addr;
            last_data <= reg_data;
        end if;

        wr_prev := reg_write;

    end process monitor;

    stimulus : process is

        variable t0 : natural; -- tx_count at the start of a test
        variable w0 : natural; -- n_write at the start of a test

        procedure start_test is
        begin

            t0 := tx_count;
            w0 := n_write;

        end procedure start_test;

        -- One received byte (one-clock rx_valid), then the byte gap.

        procedure rx_byte (
            constant value : in std_logic_vector(7 downto 0)
        ) is
        begin

            rx_data  <= value;
            rx_valid <= '1';
            wait until rising_edge(clk);
            rx_valid <= '0';

            for i in 1 to c_byte_gap loop

                wait until rising_edge(clk);

            end loop;

        end procedure rx_byte;

        -- One bad byte (one-clock rx_frame_error), then the byte gap.

        procedure rx_bad is
        begin

            rx_frame_error <= '1';
            wait until rising_edge(clk);
            rx_frame_error <= '0';

            for i in 1 to c_byte_gap loop

                wait until rising_edge(clk);

            end loop;

        end procedure rx_bad;

        procedure quiet is
        begin

            for i in 1 to c_quiet loop

                wait until rising_edge(clk);

            end loop;

        end procedure quiet;

        -- Checks the reply bytes and the number of writes since start_test.

        procedure expect (
            constant name    : in string;
            constant replies : in t_bytes;
            constant writes  : in natural
        ) is
        begin

            assert tx_count - t0 = replies'length
                report name & ": " & integer'image(tx_count - t0) & " reply bytes, expected "
                       & integer'image(replies'length)
                severity failure;

            for i in replies'range loop

                assert tx_log(t0 + i - replies'low) = replies(i)
                    report name & ": reply byte " & integer'image(i - replies'low) & " is 0x"
                           & to_hstring(tx_log(t0 + i - replies'low)) & ", expected 0x"
                           & to_hstring(replies(i))
                    severity failure;

            end loop;

            assert n_write - w0 = writes
                report name & ": " & integer'image(n_write - w0) & " writes, expected "
                       & integer'image(writes)
                severity failure;
            report name & ": ok"
                severity note;

        end procedure expect;

        -- A good write, checked: one write of (addr, value), reply ACK.

        procedure good_write (
            constant name  : in string;
            constant addr  : in std_logic_vector(7 downto 0);
            constant value : in std_logic_vector(15 downto 0)
        ) is
        begin

            start_test;
            rx_byte(addr);
            rx_byte(value(15 downto 8));
            rx_byte(value(7 downto 0));
            quiet;
            expect(name, (0 => c_ack), 1);
            assert last_addr = addr and last_data = value
                report name & ": wrote 0x" & to_hstring(last_data) & " to 0x"
                       & to_hstring(last_addr) & ", expected 0x" & to_hstring(value)
                       & " to 0x" & to_hstring(addr)
                severity failure;

        end procedure good_write;

    begin

        for i in 1 to 5 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';
        wait until rising_edge(clk);

        -- 1. Good write.
        good_write("1 good write", x"01", x"1234");

        -- 2. Write to an unknown register.
        start_test;
        rx_byte(x"40");
        rx_byte(x"AB");
        rx_byte(x"CD");
        quiet;
        expect("2 unknown register", (0 => c_nak), 0);
        good_write("2 then good", x"02", x"0042");

        -- 3. Missing byte.
        start_test;
        rx_byte(x"03");
        rx_byte(x"55");
        quiet;
        expect("3 missing byte", (0 => c_can), 0);
        good_write("3 then good", x"03", x"8001");

        -- 4. Frame error on byte 2; byte 3 still arrives.
        start_test;
        rx_byte(x"04");
        rx_bad;
        rx_byte(x"77");
        quiet;
        expect("4 bad byte 2, byte 3 follows", (0 => c_can), 0);
        good_write("4 then good", x"04", x"FFFF");

        -- 5. Frame error then a stream of bytes inside the timeout.
        start_test;
        rx_bad;

        for i in 1 to 6 loop

            rx_byte(std_logic_vector(to_unsigned(i, 8)));

        end loop;

        quiet;
        expect("5 bad byte then a stream", (0 => c_can), 0);
        good_write("5 then good", x"05", x"0000");

        -- 6. Back-to-back writes.
        start_test;
        rx_byte(x"01");
        rx_byte(x"AA");
        rx_byte(x"BB");
        rx_byte(x"02");
        rx_byte(x"CC");
        rx_byte(x"DD");
        quiet;
        expect("6 back-to-back writes", (c_ack, c_ack), 2);
        assert last_addr = x"02" and last_data = x"CCDD"
            report "6 back-to-back: last write 0x" & to_hstring(last_data) & " to 0x"
                   & to_hstring(last_addr)
            severity failure;

        -- 7. Reset in the middle of a command.
        start_test;
        rx_byte(x"01");
        rx_byte(x"12");
        reset <= '1';
        wait until rising_edge(clk);
        reset <= '0';
        quiet;
        expect("7 reset mid-command", (1 to 0 => x"00"), 0);
        good_write("7 then good", x"00", x"0080");

        -- 8. Read register 0x01: ACK, then 0xA001.
        start_test;
        rx_byte(x"81");
        rx_byte(x"00");
        rx_byte(x"00");
        quiet;
        expect("8 read 0x01", (c_ack, x"A0", x"01"), 0);

        -- 9. Read the changing read-only register 0x10: one snapshot.
        start_test;
        rx_byte(x"90");
        rx_byte(x"00");
        rx_byte(x"00");
        quiet;
        assert tx_count - t0 = 3 and tx_log(t0) = c_ack
            report "9 read 0x10: no ACK + 2 bytes"
            severity failure;
        assert tx_log(t0 + 1) = tx_log(t0 + 2)
            report "9 read 0x10: bytes 0x" & to_hstring(tx_log(t0 + 1)) & " and 0x"
                   & to_hstring(tx_log(t0 + 2))
                   & " differ: high and low came from different clocks (no snapshot)"
            severity failure;
        expect("9 read 0x10 (snapshot)", (c_ack, tx_log(t0 + 1), tx_log(t0 + 2)), 0);

        -- 10. Write to the read-only register 0x10.
        start_test;
        rx_byte(x"10");
        rx_byte(x"12");
        rx_byte(x"34");
        quiet;
        expect("10 write to read-only", (0 => c_nak), 0);

        -- 11. Read of an unknown register.
        start_test;
        rx_byte(x"C0");
        rx_byte(x"00");
        rx_byte(x"00");
        quiet;
        expect("11 read unknown", (0 => c_nak), 0);

        -- 12. A write then a read, back-to-back.
        start_test;
        rx_byte(x"03");
        rx_byte(x"BE");
        rx_byte(x"EF");
        rx_byte(x"83");
        rx_byte(x"00");
        rx_byte(x"00");
        quiet;
        expect("12 write then read", (c_ack, c_ack, x"A0", x"03"), 1);

        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
