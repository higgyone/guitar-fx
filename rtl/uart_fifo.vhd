----------------------------------------------------------------------------------
-- Company:
-- Engineer:
--
-- Create Date: 15.11.2026 10:42:43
-- Design Name:
-- Module Name: uart_fifo - rtl
-- Project Name:
-- Target Devices:
-- Tool Versions:
-- Description:
--
-- Dependencies:
--
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
--
----------------------------------------------------------------------------------

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
-- library UNISIM;
-- use UNISIM.VComponents.all;

entity uart_fifo is
    generic (
        g_addr_bits : natural := 4 -- 2**g_addr_bits slots: 4 = 16 bytes
    );
    port (
        clk      : in    std_logic;
        reset    : in    std_logic;
        wr_data  : in    std_logic_vector(7 downto 0);
        wr_en    : in    std_logic;
        rd_en    : in    std_logic;
        rd_data  : out   std_logic_vector(7 downto 0);
        empty    : out   std_logic;
        full     : out   std_logic;
        overflow : out   std_logic
    );
end entity uart_fifo;

architecture rtl of uart_fifo is

    type t_mem is array (0 to 2 ** g_addr_bits - 1) of std_logic_vector(7 downto 0);

    signal s_mem      : t_mem;
    signal s_wr_ptr   : unsigned(g_addr_bits - 1 downto 0)  := (others => '0');
    signal s_rd_ptr   : unsigned(g_addr_bits - 1 downto 0)  := (others => '0');
    signal s_count    : natural range 0 to 2 ** g_addr_bits := 0;
    signal s_overflow : std_logic                           := '0';

    signal s_empty    : std_logic;
    signal s_full     : std_logic;
    signal s_do_write : std_logic;
    signal s_do_read  : std_logic;

begin

    uart_fifo_proc : process (clk) is
    begin

        if rising_edge(clk) then
            s_overflow <= '0';                                    -- default: a one-clock pulse, like uart_rx's valid
            if (reset = '1') then
                s_wr_ptr <= (others => '0');
                s_rd_ptr <= (others => '0');
                s_count  <= 0;
            else
                if (s_do_write = '1') then
                    s_mem(to_integer(s_wr_ptr)) <= wr_data;
                    s_wr_ptr                    <= s_wr_ptr + 1;
                end if;
                if (s_do_read = '1') then
                    s_rd_ptr <= s_rd_ptr + 1;
                end if;
                if (s_do_write = '1' and s_do_read = '0') then
                    s_count <= s_count + 1;                       -- a byte in, none out
                elsif (s_do_write = '0' and s_do_read = '1') then
                    s_count <= s_count - 1;                       -- a byte out, none in
                end if;

                if (wr_en = '1' and s_full = '1') then
                    s_overflow <= '1';
                end if;
            end if;
        end if;

    end process uart_fifo_proc;

    s_empty <= '1' when s_count = 0 else
               '0';
    s_full  <= '1' when s_count = 2 ** g_addr_bits else
               '0';

    empty <= s_empty;
    full  <= s_full;

    rd_data  <= s_mem(to_integer(s_rd_ptr)); -- show-ahead: always the oldest byte
    overflow <= s_overflow;

    s_do_write <= wr_en and not(s_full);
    s_do_read  <= rd_en and not(s_empty);

end architecture rtl;
