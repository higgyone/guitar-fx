-- Self-checking testbench for cmd_decoder.
--
-- No UART here: the testbench drives rx_data / rx_valid / rx_frame_error
-- directly, as uart_rx would (one-clock pulses), with c_byte_gap clocks
-- between the bytes of a command (stands in for one byte time). A fake
-- ctrl_regs answers reg_addr_valid: registers 0x00 .. 0x05 exist.
-- A monitor counts every reply (ACK / NAK / CAN on tx_valid) and every
-- register write, and checks the pulses are one clock wide.
--
-- g_timeout_clks is 200 here (not 98305) so the run is short; c_byte_gap
-- (30) is well under it, c_quiet (300) well over it.
--
-- Checks (each test: the exact number of each reply and of writes):
--   1. Good command 0x01 0x12 0x34: one write (0x01, 0x1234), one ACK.
--   2. Unknown register 0x40: no write, one NAK.
--   3. Missing byte (only 2 sent): no write, one CAN after the timeout.
--   4. Frame error on byte 2, byte 3 still arrives: no write, exactly one
--      CAN (sent only after the line has been quiet for the timeout).
--   5. Frame error then a stream of 6 more bytes inside the timeout: still
--      exactly one CAN.
--   6. Back-to-back: two good commands with only a byte gap between them:
--      two writes (right values), two ACKs.
--   7. Reset in the middle of a command: no write, no reply.
--   8. After every error case, a good command works again (resync).
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

    signal clk            : std_logic                    := '0';
    signal reset          : std_logic                    := '1';
    signal rx_data        : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_valid       : std_logic                    := '0';
    signal rx_frame_error : std_logic                    := '0';
    signal reg_addr_valid : std_logic;
    signal tx_data        : std_logic_vector(7 downto 0);
    signal tx_valid       : std_logic;
    signal reg_addr       : std_logic_vector(7 downto 0);
    signal reg_data       : std_logic_vector(15 downto 0);
    signal reg_write      : std_logic;

    -- Kept by the monitor.
    signal n_ack     : natural                       := 0;
    signal n_nak     : natural                       := 0;
    signal n_can     : natural                       := 0;
    signal n_other   : natural                       := 0;
    signal n_write   : natural                       := 0;
    signal last_addr : std_logic_vector(7 downto 0)  := (others => '0');
    signal last_data : std_logic_vector(15 downto 0) := (others => '0');

begin

    clk <= not clk after clk_period / 2;

    -- Fake ctrl_regs: registers 0x00 .. 0x05 exist.
    reg_addr_valid <= '1' when unsigned(reg_addr) <= 5 else
                      '0';

    dut : entity work.cmd_decoder
        generic map (
            g_timeout_clks => c_timeout
        )
        port map (
            clk            => clk,
            reset          => reset,
            rx_data        => rx_data,
            rx_valid       => rx_valid,
            rx_frame_error => rx_frame_error,
            reg_addr_valid => reg_addr_valid,
            tx_data        => tx_data,
            tx_valid       => tx_valid,
            reg_addr       => reg_addr,
            reg_data       => reg_data,
            reg_write      => reg_write
        );

    -- Counts replies and writes; checks pulse widths.
    monitor : process is

        variable tx_prev : std_logic := '0';
        variable wr_prev : std_logic := '0';

    begin

        wait until rising_edge(clk);
        assert not (tx_valid = '1' and tx_prev = '1')
            report "tx_valid longer than one clock"
            severity failure;
        assert not (reg_write = '1' and wr_prev = '1')
            report "reg_write longer than one clock"
            severity failure;

        if (tx_valid = '1') then
            if (tx_data = c_ack) then
                n_ack <= n_ack + 1;
            elsif (tx_data = c_nak) then
                n_nak <= n_nak + 1;
            elsif (tx_data = c_can) then
                n_can <= n_can + 1;
            else
                n_other <= n_other + 1;
            end if;
        end if;

        if (reg_write = '1') then
            n_write   <= n_write + 1;
            last_addr <= reg_addr;
            last_data <= reg_data;
        end if;

        tx_prev := tx_valid;
        wr_prev := reg_write;

    end process monitor;

    stimulus : process is

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

        -- Checks the counts changed by exactly these amounts since the snapshot.

        procedure expect (
            constant name                      : in string;
            constant a0, n0, c0, w0            : in natural;
            constant d_ack, d_nak, d_can, d_wr : in natural
        ) is
        begin

            assert n_ack = a0 + d_ack and n_nak = n0 + d_nak and n_can = c0 + d_can
                   and n_write = w0 + d_wr and n_other = 0
                report name & ": got ACK " & integer'image(n_ack - a0) & ", NAK "
                       & integer'image(n_nak - n0) & ", CAN " & integer'image(n_can - c0)
                       & ", writes " & integer'image(n_write - w0) & ", other replies "
                       & integer'image(n_other) & "; expected ACK " & integer'image(d_ack)
                       & ", NAK " & integer'image(d_nak) & ", CAN " & integer'image(d_can)
                       & ", writes " & integer'image(d_wr)
                severity failure;
            report name & ": ok"
                severity note;

        end procedure expect;

        -- A good command, checked: one write of (addr, value), one ACK.

        procedure good_cmd (
            constant name  : in string;
            constant addr  : in std_logic_vector(7 downto 0);
            constant value : in std_logic_vector(15 downto 0)
        ) is

            variable a0 : natural;
            variable n0 : natural;
            variable c0 : natural;
            variable w0 : natural;

        begin

            a0 := n_ack; n0 := n_nak; c0 := n_can; w0 := n_write;
            rx_byte(addr);
            rx_byte(value(15 downto 8));
            rx_byte(value(7 downto 0));
            quiet;
            expect(name, a0, n0, c0, w0, 1, 0, 0, 1);
            assert last_addr = addr and last_data = value
                report name & ": wrote 0x" & to_hstring(last_data) & " to 0x"
                       & to_hstring(last_addr) & ", expected 0x" & to_hstring(value)
                       & " to 0x" & to_hstring(addr)
                severity failure;

        end procedure good_cmd;

        variable a0 : natural;
        variable n0 : natural;
        variable c0 : natural;
        variable w0 : natural;

    begin

        for i in 1 to 5 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';
        wait until rising_edge(clk);

        -- 1. Good command.
        good_cmd("1 good command", x"01", x"1234");

        -- 2. Unknown register.
        a0 := n_ack; n0 := n_nak; c0 := n_can; w0 := n_write;
        rx_byte(x"40");
        rx_byte(x"AB");
        rx_byte(x"CD");
        quiet;
        expect("2 unknown register", a0, n0, c0, w0, 0, 1, 0, 0);
        good_cmd("2 then good", x"02", x"0042");

        -- 3. Missing byte.
        a0 := n_ack; n0 := n_nak; c0 := n_can; w0 := n_write;
        rx_byte(x"03");
        rx_byte(x"55");
        quiet;
        expect("3 missing byte", a0, n0, c0, w0, 0, 0, 1, 0);
        good_cmd("3 then good", x"03", x"8001");

        -- 4. Frame error on byte 2; byte 3 still arrives.
        a0 := n_ack; n0 := n_nak; c0 := n_can; w0 := n_write;
        rx_byte(x"04");
        rx_bad;
        rx_byte(x"77");
        quiet;
        expect("4 bad byte 2, byte 3 follows", a0, n0, c0, w0, 0, 0, 1, 0);
        good_cmd("4 then good", x"04", x"FFFF");

        -- 5. Frame error then a stream of bytes inside the timeout.
        a0 := n_ack; n0 := n_nak; c0 := n_can; w0 := n_write;
        rx_bad;

        for i in 1 to 6 loop

            rx_byte(std_logic_vector(to_unsigned(i, 8)));

        end loop;

        quiet;
        expect("5 bad byte then a stream", a0, n0, c0, w0, 0, 0, 1, 0);
        good_cmd("5 then good", x"05", x"0000");

        -- 6. Back-to-back: two commands with only a byte gap between them.
        a0 := n_ack; n0 := n_nak; c0 := n_can; w0 := n_write;
        rx_byte(x"01");
        rx_byte(x"AA");
        rx_byte(x"BB");
        rx_byte(x"02");
        rx_byte(x"CC");
        rx_byte(x"DD");
        quiet;
        expect("6 back-to-back", a0, n0, c0, w0, 2, 0, 0, 2);
        assert last_addr = x"02" and last_data = x"CCDD"
            report "6 back-to-back: last write 0x" & to_hstring(last_data) & " to 0x"
                   & to_hstring(last_addr)
            severity failure;

        -- 7. Reset in the middle of a command.
        a0    := n_ack; n0 := n_nak; c0 := n_can; w0 := n_write;
        rx_byte(x"01");
        rx_byte(x"12");
        reset <= '1';
        wait until rising_edge(clk);
        reset <= '0';
        quiet;
        expect("7 reset mid-command", a0, n0, c0, w0, 0, 0, 0, 0);
        good_cmd("7 then good", x"00", x"0080");

        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
