-- uart: the whole UART as one block, 8N1 at 115 200 baud (g_clks_per_bit
-- 853 at 98.305 MHz): uart_rx, uart_fifo and uart_tx.
--
--   rx ──→ [uart_rx] ──→ rx_data, rx_valid, rx_frame_error
--
--   tx_data, tx_valid ──→ [uart_fifo] ──→ [uart_tx] ──→ tx
--                              └──→ tx_full, tx_overflow
--
-- Receive: bytes go straight out, no queue. Whatever reads them must take
-- rx_data on the rx_valid clock (the next byte starts shifting in ~1.5 bits
-- later); the echo or a command decoder does that in a clock or two.
--
-- Transmit: bytes to send are queued in the FIFO (2**g_addr_bits bytes, 16
-- by default) in front of uart_tx, the slow part (86.8 us per byte). The
-- queue lets a sender hand over several bytes at once, and absorbs
-- back-to-back echo from a PC slightly faster than our baud rate. While
-- tx_full is '1' a tx_valid byte is dropped (tx_overflow pulses).
--
-- The only logic here: s_fifo_rd_en = FIFO not empty and uart_tx not busy.
-- It drives both uart_fifo.rd_en ("taken") and uart_tx.data_in_valid
-- ("send"): the FIFO shows its oldest byte ahead (rd_data), and uart_tx
-- raises busy on the edge it accepts it, so one byte leaves per send.
-- (So a burst gets one byte more out than the FIFO holds: the first is taken
-- by uart_tx at once, before the queue fills.)
--
-- Echo test in top.vhd: rx_data -> tx_data, rx_valid -> tx_valid.
-- Pins: rx <- uart_txd_in (A9), tx -> uart_rxd_out (D10).
-- Testbench: sim/uart_tb.vhd (end to end, with PC transmitter and receiver
-- models). Design notes: docs/uart.md.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart is
    generic (
        g_clks_per_bit : natural := 853; -- s_clk clocks per UART bit (98.305 MHz / 115 200)
        g_addr_bits    : natural := 4    -- transmit FIFO size: 2**g_addr_bits bytes, 4 = 16
    );
    port (
        clk            : in    std_logic;                    -- s_clk, 98.305 MHz
        reset          : in    std_logic;                    -- synchronous, active high
        rx             : in    std_logic;                    -- serial line from the pin, idles '1', not synchronised
        tx_data        : in    std_logic_vector(7 downto 0); -- byte to send
        tx_valid       : in    std_logic;                    -- one-clock pulse: queue tx_data (dropped if tx_full)
        tx             : out   std_logic;                    -- serial line to the pin, idles '1'
        rx_data        : out   std_logic_vector(7 downto 0); -- received byte (meaningful on rx_valid)
        rx_valid       : out   std_logic;                    -- one-clock pulse: rx_data holds a good byte
        rx_frame_error : out   std_logic;                    -- one-clock pulse: stop bit was '0', byte discarded
        tx_full        : out   std_logic;                    -- '1': transmit queue full, tx_valid is dropped
        tx_overflow    : out   std_logic                     -- one clock per byte dropped because the queue was full
    );
end entity uart;

architecture rtl of uart is

    -- Wires between the FIFO and uart_tx (internal, not ports).
    signal s_fifo_data  : std_logic_vector(7 downto 0); -- oldest queued byte (show-ahead) -> uart_tx
    signal s_fifo_empty : std_logic;                    -- '1': nothing queued
    signal s_fifo_rd_en : std_logic;                    -- send it now = FIFO "taken"
    signal s_tx_busy    : std_logic;                    -- uart_tx is sending

begin

    uart_tx_inst : entity work.uart_tx
        generic map (
            g_clks_per_bit => g_clks_per_bit
        )
        port map (
            clk           => clk,
            reset         => reset,
            data_in       => s_fifo_data,
            data_in_valid => s_fifo_rd_en,
            tx            => tx,
            busy          => s_tx_busy
        );

    uart_rx_inst : entity work.uart_rx
        generic map (
            g_clks_per_bit => g_clks_per_bit
        )
        port map (
            clk            => clk,
            reset          => reset,
            rx             => rx,
            data_out       => rx_data,
            data_out_valid => rx_valid,
            frame_error    => rx_frame_error
        );

    uart_fifo_inst : entity work.uart_fifo
        generic map (
            g_addr_bits => g_addr_bits
        )
        port map (
            clk      => clk,
            reset    => reset,
            wr_data  => tx_data,
            wr_en    => tx_valid,
            rd_en    => s_fifo_rd_en,
            rd_data  => s_fifo_data,
            empty    => s_fifo_empty,
            full     => tx_full,
            overflow => tx_overflow
        );

    -- Something queued and uart_tx free: send the oldest byte and take it
    -- out of the FIFO, on the same clock.
    s_fifo_rd_en <= not s_fifo_empty and not s_tx_busy;

end architecture rtl;
