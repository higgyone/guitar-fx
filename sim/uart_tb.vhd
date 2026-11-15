-- End-to-end testbench for the uart block (uart_rx + uart_fifo + uart_tx).
--
-- A model of the PC's transmitter drives rx and a model of the PC's
-- receiver decodes tx (both timed with `wait for`, not the FPGA clock).
-- The testbench can wire rx_data / rx_valid straight back into tx_data /
-- tx_valid (echo, as top.vhd will for the board test), or drive tx_data /
-- tx_valid itself.
--
-- g_clks_per_bit = 32, FIFO 16 bytes (g_addr_bits 4).
--
-- Checks:
--   1. Echo, typed: single bytes with gaps come back unchanged.
--   2. Echo, pasted: 24 bytes back-to-back from a PC 0.5 % FAST. Without
--      the FIFO uart_tx would still be busy when the next byte arrives and
--      bytes would be lost; with it all 24 come back, in order, and no
--      overflow is reported.
--   3. Burst into tx_data (20 bytes on 20 consecutive clocks): the FIFO
--      fills, tx_full goes high, the extra bytes are dropped with one
--      tx_overflow pulse each; what reaches the PC is the first bytes, in
--      order, and bytes received + overflows = 20.
--   4. rx_valid is a one-clock pulse (monitor). tx_overflow is one clock
--      per dropped byte, so bytes dropped on consecutive clocks keep it
--      high for several clocks: it is counted per clock, not checked for
--      width.
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/uart_rx.vhd rtl/uart_tx.vhd `
--       rtl/uart_fifo.vhd rtl/uart.vhd sim/uart_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP uart_tb

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_tb is
end entity uart_tb;

architecture sim of uart_tb is

    constant clk_period : time    := 10.172 ns; -- 98.304 MHz
    constant c_clks     : natural := 32;        -- g_clks_per_bit for the test
    constant c_bit_time : time    := c_clks * clk_period;

    type t_bytes is array (natural range <>) of std_logic_vector(7 downto 0);

    signal clk            : std_logic := '0';
    signal reset          : std_logic := '1';
    signal rx             : std_logic := '1';
    signal tx             : std_logic;
    signal tx_data        : std_logic_vector(7 downto 0);
    signal tx_valid       : std_logic;
    signal rx_data        : std_logic_vector(7 downto 0);
    signal rx_valid       : std_logic;
    signal rx_frame_error : std_logic;
    signal tx_full        : std_logic;
    signal tx_overflow    : std_logic;

    -- Test control: echo ('1') or the testbench drives tx_data / tx_valid.
    signal echo        : std_logic                    := '1';
    signal tb_tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tb_tx_valid : std_logic                    := '0';

    -- Kept by the PC receiver model and the monitor.
    signal pc_rx_bytes    : t_bytes(0 to 63) := (others => (others => '0'));
    signal pc_rx_count    : natural          := 0;
    signal overflow_count : natural          := 0;
    signal full_seen      : boolean          := false;

begin

    clk <= not clk after clk_period / 2;

    -- Echo or testbench-driven transmit side.
    tx_data  <= rx_data when echo = '1' else
                tb_tx_data;
    tx_valid <= rx_valid when echo = '1' else
                tb_tx_valid;

    dut : entity work.uart
        generic map (
            g_clks_per_bit => c_clks,
            g_addr_bits    => 4
        )
        port map (
            clk            => clk,
            reset          => reset,
            rx             => rx,
            tx_data        => tx_data,
            tx_valid       => tx_valid,
            tx             => tx,
            rx_data        => rx_data,
            rx_valid       => rx_valid,
            rx_frame_error => rx_frame_error,
            tx_full        => tx_full,
            tx_overflow    => tx_overflow
        );

    -- Model of the PC's receiver: decodes every frame on tx, in order.
    pc_rx : process is

        variable b : std_logic_vector(7 downto 0);

    begin

        wait until reset = '0';

        loop

            wait until tx = '0';
            wait for c_bit_time / 2;
            assert tx = '0'
                report "pc_rx: bad start bit"
                severity failure;

            for i in 0 to 7 loop

                wait for c_bit_time;
                b(i) := tx;

            end loop;

            wait for c_bit_time;
            assert tx = '1'
                report "pc_rx: framing error on tx"
                severity failure;
            pc_rx_bytes(pc_rx_count) <= b;
            pc_rx_count              <= pc_rx_count + 1;
            wait for c_bit_time / 4;

        end loop;

    end process pc_rx;

    -- Counts overflow pulses, notes tx_full, checks pulse widths.
    monitor : process is

        variable valid_prev : std_logic := '0';

    begin

        wait until rising_edge(clk);
        assert not (rx_valid = '1' and valid_prev = '1')
            report "rx_valid longer than one clock"
            severity failure;
        assert rx_frame_error /= '1'
            report "unexpected rx_frame_error"
            severity failure;

        if (tx_overflow = '1') then
            overflow_count <= overflow_count + 1;
        end if;

        if (tx_full = '1') then
            full_seen <= true;
        end if;

        valid_prev := rx_valid;

    end process monitor;

    stimulus : process is

        -- Model of the PC's transmitter (rate > 1.0 = faster than nominal).

        procedure pc_send (
            constant value : in std_logic_vector(7 downto 0);
            constant rate  : in real := 1.0
        ) is

            constant bit_t : time := c_bit_time / rate;

        begin

            rx <= '0';
            wait for bit_t;

            for i in 0 to 7 loop

                rx <= value(i);
                wait for bit_t;

            end loop;

            rx <= '1';
            wait for bit_t;

        end procedure pc_send;

        -- Waits until the PC has received n bytes in total (with a timeout).

        procedure wait_for_pc (
            constant n       : in natural;
            constant max_bit : in natural
        ) is
        begin

            for i in 1 to max_bit loop

                exit when pc_rx_count >= n;
                wait for c_bit_time;

            end loop;

            assert pc_rx_count >= n
                report "PC received " & integer'image(pc_rx_count) & " bytes, expected "
                       & integer'image(n)
                severity failure;

        end procedure wait_for_pc;

        constant c_typed : t_bytes(0 to 3) := (x"48", x"69", x"0D", x"0A"); -- "Hi\r\n"
        variable start   : natural;
        variable v       : std_logic_vector(7 downto 0);

    begin

        wait for 5 * clk_period + 3.1 ns;
        reset <= '0';
        wait for 2 * c_bit_time;

        -- 1. Echo, typed: gaps between bytes.
        echo <= '1';

        for i in c_typed'range loop

            pc_send(c_typed(i));
            wait for 15 * c_bit_time;

        end loop;

        wait_for_pc(4, 20);

        for i in c_typed'range loop

            assert pc_rx_bytes(i) = c_typed(i)
                report "typed echo: byte " & integer'image(i) & " came back as 0x"
                       & to_hstring(pc_rx_bytes(i)) & ", sent 0x" & to_hstring(c_typed(i))
                severity failure;

        end loop;

        report "echo, typed: 4 bytes back"
            severity note;

        -- 2. Echo, pasted: 24 bytes back-to-back, PC 0.5 % fast.
        start := pc_rx_count;

        for i in 0 to 23 loop

            pc_send(std_logic_vector(to_unsigned(16#20# + i, 8)), 1.005);

        end loop;

        wait_for_pc(start + 24, 60);

        for i in 0 to 23 loop

            v := std_logic_vector(to_unsigned(16#20# + i, 8));
            assert pc_rx_bytes(start + i) = v
                report "pasted echo: byte " & integer'image(i) & " came back as 0x"
                       & to_hstring(pc_rx_bytes(start + i)) & ", sent 0x" & to_hstring(v)
                severity failure;

        end loop;

        assert overflow_count = 0
            report "pasted echo: FIFO overflowed"
            severity failure;
        report "echo, pasted (PC 0.5 % fast): 24 bytes back, in order"
            severity note;

        -- 3. Burst straight into tx_data: 20 bytes on 20 consecutive clocks.
        wait for 5 * c_bit_time;
        echo  <= '0';
        start := pc_rx_count;
        wait until rising_edge(clk);

        for i in 0 to 19 loop

            tb_tx_data  <= std_logic_vector(to_unsigned(16#40# + i, 8));
            tb_tx_valid <= '1';
            wait until rising_edge(clk);

        end loop;

        tb_tx_valid <= '0';
        wait for 25 * 11 * c_bit_time;           -- let everything queued go out
        assert full_seen
            report "burst: tx_full never went high"
            severity failure;
        assert overflow_count > 0
            report "burst: no tx_overflow pulse"
            severity failure;
        assert (pc_rx_count - start) + overflow_count = 20
            report "burst: " & integer'image(pc_rx_count - start) & " sent + "
                   & integer'image(overflow_count) & " dropped /= 20"
            severity failure;

        for i in 0 to pc_rx_count - start - 1 loop

            v := std_logic_vector(to_unsigned(16#40# + i, 8));
            assert pc_rx_bytes(start + i) = v
                report "burst: byte " & integer'image(i) & " is 0x"
                       & to_hstring(pc_rx_bytes(start + i)) & ", expected 0x" & to_hstring(v)
                severity failure;

        end loop;

        report "burst: " & integer'image(pc_rx_count - start) & " bytes sent in order, "
               & integer'image(overflow_count) & " dropped (FIFO full)"
            severity note;

        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process stimulus;

end architecture sim;
