-- uart_tx: UART transmitter, 8N1 (1 start bit, 8 data bits LSB first, no
-- parity, 1 stop bit).
--
--   idle  start  d0  d1 ... d7  stop  idle
--   ‾‾‾‾‾\_____/‾‾‾\___ ... ___/‾‾‾‾‾‾‾‾‾‾‾
--
-- A one-clock data_in_valid pulse while not busy sends data_in. busy is '1'
-- from that clock for exactly 10 bit times (10 * g_clks_per_bit clocks);
-- data_in_valid is ignored while busy, so the sender must wait for busy to
-- go low. tx idles high (also during and straight after reset).
--
-- How: a 10-bit shift register is loaded with '1' & data_in & '0' (stop,
-- data, start) and tx is its bit 0. Every g_clks_per_bit clocks it shifts
-- right with a '1' coming in at the top, so it sends start, d0 .. d7, stop
-- and is then all '1's, which leaves the line idle with no extra logic.
--
-- g_clks_per_bit = clock frequency / baud rate, rounded: 853 for 115 200
-- baud at 98.305 MHz (actual 115 246 baud, +0.04 %). The testbench uses a
-- small value to run quickly.
--
-- Pins: tx -> uart_rxd_out (D10), the USB-UART chip's receive input.
-- Testbench: sim/uart_tx_tb.vhd. Design notes: docs/uart.md.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_tx is
    generic (
        g_clks_per_bit : natural := 853 -- s_clk clocks per UART bit (98.305 MHz / 115 200)
    );
    port (
        clk           : in    std_logic;                    -- s_clk, 98.305 MHz
        reset         : in    std_logic;                    -- synchronous, active high
        data_in       : in    std_logic_vector(7 downto 0); -- byte to send
        data_in_valid : in    std_logic;                    -- one-clock pulse: send data_in (ignored while busy)
        tx            : out   std_logic;                    -- serial line, idles '1'
        busy          : out   std_logic                     -- '1' while a byte is being sent
    );
end entity uart_tx;

architecture rtl of uart_tx is

    -- s_shift      : frame being sent; bit 0 drives tx. All '1' = idle.
    -- s_baud_count : clocks into the current bit, 0 .. g_clks_per_bit - 1.
    -- s_bit_count  : bit being sent: 0 start, 1 .. 8 data, 9 stop.
    -- s_busy       : '1' while sending.
    signal s_shift      : std_logic_vector(9 downto 0)          := (others => '1');
    signal s_baud_count : natural range 0 to g_clks_per_bit - 1 := 0;
    signal s_bit_count  : natural range 0 to 9                  := 0;
    signal s_busy       : std_logic                             := '0';

begin

    uart_tx_proc : process (clk) is
    begin

        if rising_edge(clk) then
            if (reset = '1') then
                s_shift      <= (others => '1');
                s_baud_count <= 0;
                s_bit_count  <= 0;
                s_busy       <= '0';
            elsif (s_busy = '0') then
                if (data_in_valid = '1') then
                    s_shift      <= '1' & data_in & '0';         -- load stop bit, data bits, and start bit
                    s_baud_count <= 0;
                    s_bit_count  <= 0;
                    s_busy       <= '1';
                end if;
            else
                if (s_baud_count = g_clks_per_bit - 1) then
                    s_baud_count <= 0;
                    s_shift      <= '1' & s_shift(9 downto 1);   -- '1' enters at bit 9, old bit 0 falls off
                    if (s_bit_count = 9) then
                        s_busy      <= '0';                      -- transmission complete
                        s_bit_count <= 0;
                    else
                        s_bit_count <= s_bit_count + 1;
                    end if;
                else
                    s_baud_count <= s_baud_count + 1;
                end if;
            end if;
        end if;

    end process uart_tx_proc;

    tx   <= s_shift(0);
    busy <= s_busy;

end architecture rtl;
