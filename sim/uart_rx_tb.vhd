-- Self-checking testbench for uart_rx.
--
-- A model of the PC's UART transmitter (procedure uart_send) drives rx with
-- 8N1 frames, timed with `wait for` (not the FPGA clock), so the line edges
-- fall at arbitrary points between clock edges, as with a real PC. A
-- monitor process counts the data_out_valid and frame_error pulses, keeps
-- the last byte and checks each pulse is one clock wide.
--
-- g_clks_per_bit is 32 here (not 853) so the run is short. 32 rather than
-- 16 keeps the clock-step and synchroniser delay small against a bit time,
-- so the +/-3 % baud tests test the design, not the test's rounding.
--
-- Checks:
--   1. Idle line after reset: no pulses.
--   2. Bytes 0x55 0xAA 0x00 0xFF 0x01 0x80 0xA5 0x3C, each received once,
--      correct value (catches bit order, half-bit data sampling, shift
--      direction, a counter that never reaches its limit).
--   3. Back-to-back: 4 bytes with no idle between frames.
--   4. Baud 3 % fast and 3 % slow: still received correctly.
--   5. Glitch: a low pulse of a quarter bit is not a start bit (no pulse),
--      and a normal byte afterwards is received.
--   6. Framing error: stop bit low → frame_error pulse, no data_out_valid.
--      (Its stop bit is held low for 0.6 bit then released, so the line is
--      high again by the time the receiver is back in idle.)
--   7. Reset in the middle of a frame: the rest of that frame is not taken
--      as a byte; the next byte is received.
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/uart_rx.vhd sim/uart_rx_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP uart_rx_tb

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_rx_tb is
end entity uart_rx_tb;

architecture sim of uart_rx_tb is

    constant clk_period : time    := 10.172 ns; -- 98.304 MHz (even ps: exact half period)
    constant c_clks     : natural := 32;        -- g_clks_per_bit for the test
    constant c_bit_time : time    := c_clks * clk_period;

    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal rx             : std_logic := '1'; -- line idles high
    signal data_out       : std_logic_vector(7 downto 0);
    signal data_out_valid : std_logic;
    signal frame_error    : std_logic;

    -- Kept by the monitor process.
    signal valid_count : natural                      := 0;
    signal fe_count    : natural                      := 0;
    signal last_byte   : std_logic_vector(7 downto 0) := (others => '0');

begin

    clk <= not clk after clk_period / 2;

    dut : entity work.uart_rx
        generic map (
            g_clks_per_bit => c_clks
        )
        port map (
            clk            => clk,
            reset          => reset,
            rx             => rx,
            data_out       => data_out,
            data_out_valid => data_out_valid,
            frame_error    => frame_error
        );

    -- Counts the output pulses and checks each is one clock wide.
    monitor : process is

        variable valid_prev : std_logic := '0';
        variable fe_prev    : std_logic := '0';

    begin

        wait until rising_edge(clk);

        if (data_out_valid = '1') then
            assert valid_prev = '0'
                report "data_out_valid longer than one clock"
                severity failure;
            assert frame_error = '0'
                report "data_out_valid and frame_error together"
                severity failure;
            valid_count <= valid_count + 1;
            last_byte   <= data_out;
        end if;

        if (frame_error = '1') then
            assert fe_prev = '0'
                report "frame_error longer than one clock"
                severity failure;
            fe_count <= fe_count + 1;
        end if;

        valid_prev := data_out_valid;
        fe_prev    := frame_error;

    end process monitor;

    stimulus : process is

        -- Model of the PC's transmitter: one 8N1 frame on rx.
        --   rate      : 1.0 exact, 1.03 = 3 % fast (shorter bits), 0.97 slow
        --   stop_bit  : '1' normal, '0' for a framing error
        --   stop_frac : how long the stop bit level is held, in bits

        procedure uart_send (
            constant value     : in std_logic_vector(7 downto 0);
            constant rate      : in real      := 1.0;
            constant stop_bit  : in std_logic := '1';
            constant stop_frac : in real      := 1.0
        ) is

            constant bit_t : time := c_bit_time / rate;

        begin

            rx <= '0';           -- start bit
            wait for bit_t;

            for i in 0 to 7 loop -- LSB first

                rx <= value(i);
                wait for bit_t;

            end loop;

            rx <= stop_bit;      -- stop bit
            wait for bit_t * stop_frac;
            rx <= '1';           -- idle

        end procedure uart_send;

        -- Sends one byte, then waits a bit time and checks it arrived once.

        procedure send_and_check (
            constant value : in std_logic_vector(7 downto 0);
            constant rate  : in real := 1.0
        ) is

            variable n : natural;

        begin

            n := valid_count;
            uart_send(value, rate);
            wait for c_bit_time;
            assert valid_count = n + 1
                report "0x" & to_hstring(value) & ": " & integer'image(valid_count - n)
                       & " data_out_valid pulses, expected 1"
                severity failure;
            assert last_byte = value
                report "sent 0x" & to_hstring(value) & ", received 0x" & to_hstring(last_byte)
                severity failure;
            report "received 0x" & to_hstring(value)
                severity note;

        end procedure send_and_check;

        variable n_valid : natural;
        variable n_fe    : natural;

    begin

        -- Reset, offset from the clock so the line edges are not aligned.
        wait for 5 * clk_period + 3.1 ns;
        reset <= '0';

        -- 1. Idle line: nothing received.
        wait for 5 * c_bit_time;
        assert valid_count = 0 and fe_count = 0
            report "pulses from an idle line"
            severity failure;

        -- 2. Bytes.
        send_and_check(x"55");
        send_and_check(x"AA");
        send_and_check(x"00");
        send_and_check(x"FF");
        send_and_check(x"01");
        send_and_check(x"80");
        send_and_check(x"A5");
        send_and_check(x"3C");

        -- 3. Back-to-back: no idle between frames.
        n_valid := valid_count;
        uart_send(x"12");
        uart_send(x"34");
        uart_send(x"56");
        uart_send(x"78");
        wait for c_bit_time;
        assert valid_count = n_valid + 4
            report "back-to-back: " & integer'image(valid_count - n_valid)
                   & " bytes received, expected 4"
            severity failure;
        assert last_byte = x"78"
            report "back-to-back: last byte 0x" & to_hstring(last_byte)
            severity failure;
        report "back-to-back: 4 bytes received"
            severity note;

        -- 4. Baud rate error.
        send_and_check(x"C3", 1.03);
        send_and_check(x"5A", 0.97);
        report "3 % fast and slow: ok"
            severity note;

        -- 5. Glitch: a quarter-bit low pulse.
        n_valid := valid_count;
        n_fe    := fe_count;
        rx      <= '0';
        wait for c_bit_time / 4;
        rx      <= '1';
        wait for 12 * c_bit_time;
        assert valid_count = n_valid and fe_count = n_fe
            report "a glitch was taken as a start bit"
            severity failure;
        send_and_check(x"69");
        report "glitch ignored"
            severity note;

        -- 6. Framing error: stop bit low.
        n_valid := valid_count;
        n_fe    := fe_count;
        uart_send(x"E7", 1.0, '0', 0.6);
        wait for 2 * c_bit_time;
        assert fe_count = n_fe + 1
            report "framing error: no frame_error pulse"
            severity failure;
        assert valid_count = n_valid
            report "framing error: byte was passed on as valid"
            severity failure;
        send_and_check(x"81");
        report "framing error flagged, byte discarded"
            severity note;

        -- 7. Reset in the middle of a frame.
        n_valid := valid_count;
        rx      <= '0';                                                    -- start bit
        wait for c_bit_time;
        rx      <= '1';                                                    -- d0 = 1 ...
        wait for 2 * c_bit_time;
        wait until rising_edge(clk);
        reset   <= '1';                                                    -- reset mid-frame
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        reset   <= '0';
        wait for 10 * c_bit_time;                                          -- line idle '1' from d0 on
        assert valid_count = n_valid
            report "reset mid-frame: a byte was still produced"
            severity failure;
        send_and_check(x"42");
        report "reset mid-frame: ok"
            severity note;

        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
