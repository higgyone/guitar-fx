-- Self-checking testbench for uart_tx.
--
-- A model of the PC's UART receiver (process pc_rx) watches tx: it waits
-- for the falling edge of a start bit, waits half a bit, checks the start
-- bit is still low, then samples the 8 data bits (LSB first) one bit time
-- apart in the middle of each bit, and checks the stop bit is high. Each
-- decoded byte is passed to the stimulus process, which compares it with
-- the byte that was sent.
--
-- g_clks_per_bit is 16 here (not 853) so the run is short; the design only
-- counts clocks, so the behaviour is the same at any value.
--
-- Checks:
--   1. tx idles high after reset; busy low.
--   2. Bytes 0x55, 0x00, 0xFF, 0xA5, 0x01, 0x80 each arrive correctly
--      (catches bit order, start/stop swapped, shift direction).
--   3. busy is high for exactly 10 bit times (10 * g_clks_per_bit clocks)
--      and the start bit lasts exactly one bit time.
--   4. data_in_valid while busy is ignored: only the first byte arrives,
--      then the line goes idle.
--   5. A byte sent the clock after busy falls (back-to-back) arrives.
--   6. Long idle (several bit times): tx stays high, nothing is received.
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/uart_tx.vhd sim/uart_tx_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP uart_tx_tb

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_tx_tb is
end entity uart_tx_tb;

architecture sim of uart_tx_tb is

    constant clk_period : time    := 10.172 ns; -- 98.304 MHz (even ps: exact half period)
    constant c_clks     : natural := 16;        -- g_clks_per_bit for the test
    constant c_bit_time : time    := c_clks * clk_period;

    signal clk           : std_logic                    := '0';
    signal reset         : std_logic                    := '1';
    signal data_in       : std_logic_vector(7 downto 0) := (others => '0');
    signal data_in_valid : std_logic                    := '0';
    signal tx            : std_logic;
    signal busy          : std_logic;

    -- From the PC receiver model to the stimulus process.
    signal rx_byte  : std_logic_vector(7 downto 0) := (others => '0'); -- last byte decoded
    signal rx_count : natural                      := 0;               -- bytes decoded so far

begin

    clk <= not clk after clk_period / 2;

    dut : entity work.uart_tx
        generic map (
            g_clks_per_bit => c_clks
        )
        port map (
            clk           => clk,
            reset         => reset,
            data_in       => data_in,
            data_in_valid => data_in_valid,
            tx            => tx,
            busy          => busy
        );

    -- Model of the PC's receiver: decodes 8N1 frames from tx.
    pc_rx : process is

        variable b : std_logic_vector(7 downto 0);

    begin

        wait until reset = '0';

        loop

            wait until tx = '0';                                          -- falling edge of the start bit
            wait for c_bit_time / 2;                                      -- middle of the start bit
            assert tx = '0'
                report "pc_rx: start bit not low at its middle (glitch?)"
                severity failure;

            for i in 0 to 7 loop                                          -- LSB first

                wait for c_bit_time;
                b(i) := tx;

            end loop;

            wait for c_bit_time;                                          -- middle of the stop bit
            assert tx = '1'
                report "pc_rx: stop bit not high (framing error)"
                severity failure;
            rx_byte  <= b;
            rx_count <= rx_count + 1;
            wait for c_bit_time / 4;                                      -- leave the stop bit before looking again

        end loop;

    end process pc_rx;

    stimulus : process is

        -- Sends one byte (one-clock valid pulse), checks busy is exactly 10
        -- bit times, waits for the receiver and checks the decoded byte.

        procedure send_byte (
            constant value : in std_logic_vector(7 downto 0)
        ) is

            variable count_before : natural;
            variable clks_busy    : natural := 0;

        begin

            count_before  := rx_count;
            wait until rising_edge(clk);
            assert busy = '0'
                report "send_byte: busy before sending"
                severity failure;
            data_in       <= value;
            data_in_valid <= '1';
            wait until rising_edge(clk);
            data_in_valid <= '0';

            -- busy rises on the edge just passed, but a signal assigned on an
            -- edge is only visible after it: look from the next edge on.
            -- Each edge then shows busy as set on the edge before, so the
            -- loop counts every clock busy was high.
            wait until rising_edge(clk);

            while busy = '1' loop

                clks_busy := clks_busy + 1;
                wait until rising_edge(clk);
                assert clks_busy <= 11 * c_clks
                    report "send_byte: busy stuck high"
                    severity failure;

            end loop;

            assert clks_busy = 10 * c_clks
                report "busy high for " & integer'image(clks_busy) & " clocks, expected "
                       & integer'image(10 * c_clks)
                severity failure;

            -- The receiver finishes in the middle of the stop bit, which is
            -- before busy falls, so the byte is already there.
            assert rx_count = count_before + 1
                report "byte not received"
                severity failure;
            assert rx_byte = value
                report "sent 0x" & to_hstring(value) & ", received 0x" & to_hstring(rx_byte)
                severity failure;
            report "sent and received 0x" & to_hstring(value)
                severity note;

        end procedure send_byte;

        variable t_fall : time;

    begin

        -- Reset for 3 clocks.
        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';

        -- 1. Idle after reset.
        for i in 1 to 5 loop

            wait until rising_edge(clk);
            assert tx = '1'
                report "tx not idle high after reset"
                severity failure;
            assert busy = '0'
                report "busy high after reset"
                severity failure;

        end loop;

        -- 2. and 3. Bytes, busy length.
        send_byte(x"55");
        send_byte(x"00");
        send_byte(x"FF");
        send_byte(x"A5");
        send_byte(x"01");
        send_byte(x"80");

        -- 3. Start bit length: exactly one bit time. The byte's bit 0 must
        -- be '1' so the line goes high right after the start bit (0xF0
        -- would stay low through d0..d3 and measure 5 bit times).
        wait until rising_edge(clk);
        data_in       <= x"0F";
        data_in_valid <= '1';
        wait until rising_edge(clk);
        data_in_valid <= '0';

        if (tx /= '0') then
            wait until tx = '0';
        end if;

        t_fall := now;
        wait until tx = '1';
        assert now - t_fall = c_bit_time
            report "start bit lasted " & time'image(now - t_fall) & ", expected "
                   & time'image(c_bit_time)
            severity failure;
        wait until busy = '0';
        report "start bit is exactly one bit time"
            severity note;

        -- 4. data_in_valid while busy is ignored.
        wait until rising_edge(clk);
        data_in       <= x"3C";
        data_in_valid <= '1';
        wait until rising_edge(clk);
        data_in       <= x"C3";                 -- second byte, sent while busy
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        data_in_valid <= '0';
        wait until busy = '0';
        assert rx_byte = x"3C"
            report "while busy: received 0x" & to_hstring(rx_byte) & ", expected 0x3C"
            severity failure;

        for i in 1 to 3 * c_clks loop

            wait until rising_edge(clk);
            assert tx = '1' and busy = '0'
                report "a byte sent while busy was not ignored"
                severity failure;

        end loop;

        report "data_in_valid while busy ignored"
            severity note;

        -- 5. Back-to-back: send_byte starts on the clock after busy falls.
        send_byte(x"96");

        -- 6. Long idle: tx stays high, nothing received.
        for i in 1 to 30 * c_clks loop

            wait until rising_edge(clk);
            assert tx = '1'
                report "tx left idle with nothing sent"
                severity failure;

        end loop;

        report "idle: ok"
            severity note;

        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
