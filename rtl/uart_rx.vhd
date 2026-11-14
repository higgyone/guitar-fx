-- uart_rx: UART receiver, 8N1 (1 start bit, 8 data bits LSB first, no
-- parity, 1 stop bit).
--
--   rx:  ‾‾‾‾\_start_/ d0 \ d1 / ... \ d7 /‾stop‾‾‾‾ idle
--              ^      ^     ^          ^     ^
--        falling   middle of each bit: sampled here
--        edge      (half a bit after the edge, then every full bit)
--
-- rx is asynchronous (timed by the PC's clock), so it goes through a
-- 2-flip-flop synchroniser (s_rx_meta -> s_rx_sync, both starting '1' =
-- idle) and only s_rx_sync is used after that.
--
-- States:
--   st_idle  wait for the line to go low (start of a start bit)
--   st_start wait half a bit (g_clks_per_bit / 2): still low -> real start
--            bit, now in its middle; high again -> a glitch, back to idle
--   st_data  every full bit, shift the line in at the top of s_data (LSB
--            first, so after 8 bits d0 is in bit 0)
--   st_stop  one more full bit, to the middle of the stop bit: '1' -> a
--            good byte, data_out_valid pulses; '0' -> framing error,
--            frame_error pulses and the byte is discarded. Back to idle at
--            mid-stop, ready for a back-to-back start bit.
--
-- Outputs: data_out is the shift register; it is only meaningful on the
-- clock data_out_valid is '1' (it changes again as the next byte arrives).
-- data_out_valid and frame_error are one-clock pulses.
--
-- g_clks_per_bit = clock frequency / baud rate, rounded: 853 for 115 200
-- baud at 98.305 MHz (+0.04 %). Sampling mid-bit leaves half a bit of
-- margin: the testbench passes with the PC 3 % fast or slow.
--
-- Pins: rx <- uart_txd_in (A9), the USB-UART chip's transmit output.
-- Testbench: sim/uart_rx_tb.vhd. Design notes: docs/uart.md.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_rx is
    generic (
        g_clks_per_bit : natural := 853 -- s_clk clocks per UART bit (98.305 MHz / 115 200)
    );
    port (
        clk            : in    std_logic;                    -- s_clk, 98.305 MHz
        reset          : in    std_logic;                    -- synchronous, active high
        rx             : in    std_logic;                    -- serial line from the pin, idles '1', not synchronised
        data_out       : out   std_logic_vector(7 downto 0); -- received byte
        data_out_valid : out   std_logic;                    -- one-clock pulse: data_out holds a good byte
        frame_error    : out   std_logic                     -- one-clock pulse: stop bit was '0', byte discarded
    );
end entity uart_rx;

architecture rtl of uart_rx is

    type t_state is (st_idle, st_start, st_data, st_stop); -- the list of states

    signal s_state : t_state := st_idle; -- the current state

    -- s_rx_meta, s_rx_sync : 2-FF synchroniser on rx ('1' = idle at start).
    -- s_baud_count : clocks into the current half / full bit.
    -- s_bit_count  : data bit being received, 0 .. 7.
    -- s_data       : shift register; bits arrive at the top, LSB first.
    -- s_valid, s_frame_error : one-clock output pulses (default '0').
    signal s_rx_meta : std_logic := '1';
    signal s_rx_sync : std_logic := '1';

    signal s_baud_count : natural range 0 to g_clks_per_bit - 1 := 0;
    signal s_bit_count  : natural range 0 to 7                  := 0;
    signal s_data       : std_logic_vector(7 downto 0)          := (others => '1');

    signal s_valid       : std_logic := '0';
    signal s_frame_error : std_logic := '0';

begin

    uart_rx_proc : process (clk) is
    begin

        if rising_edge(clk) then
            s_rx_meta <= rx;
            s_rx_sync <= s_rx_meta;

            s_valid       <= '0';                                                        -- default: no pulse
            s_frame_error <= '0';

            if (reset = '1') then
                s_data       <= (others => '1');
                s_baud_count <= 0;
                s_bit_count  <= 0;
                s_state      <= st_idle;
            else

                case s_state is

                    when st_idle =>

                        if (s_rx_sync = '0') then                                        -- start bit detected
                            s_baud_count <= 0;                                           -- time the start bit
                            s_state      <= st_start;
                        end if;

                    when st_start =>

                        if (s_baud_count = g_clks_per_bit / 2 - 1) then                  -- half a bit has passed
                            s_baud_count <= 0;                                           -- time data bit 0
                            if (s_rx_sync = '0') then                                    -- still low: a real start bit
                                s_bit_count <= 0;
                                s_state     <= st_data;
                            else                                                         -- high again: it was a glitch
                                s_state <= st_idle;
                            end if;
                        else
                            s_baud_count <= s_baud_count + 1;                            -- keep counting
                        end if;

                    when st_data =>

                        if (s_baud_count = g_clks_per_bit - 1) then                      -- middle of the next data bit
                            s_baud_count <= 0;
                            s_data       <= s_rx_sync & s_data(7 downto 1);              -- shift the bit in at the top
                            if (s_bit_count = 7) then                                    -- that was d7
                                s_state <= st_stop;
                            else
                                s_bit_count <= s_bit_count + 1;
                            end if;
                        else
                            s_baud_count <= s_baud_count + 1;
                        end if;

                    when st_stop =>

                        if (s_baud_count = g_clks_per_bit - 1) then                      -- middle of the stop bit
                            s_baud_count <= 0;
                            if (s_rx_sync = '1') then                                    -- stop bit is high: good byte
                                s_valid <= '1';
                            else                                                         -- stop low: frame error
                                s_frame_error <= '1';
                            end if;
                            s_state <= st_idle;                                          -- either way, back to idle
                        else
                            s_baud_count <= s_baud_count + 1;
                        end if;

                end case;

            end if;
        end if;

    end process uart_rx_proc;

    data_out       <= s_data;
    data_out_valid <= s_valid;
    frame_error    <= s_frame_error;

end architecture rtl;
