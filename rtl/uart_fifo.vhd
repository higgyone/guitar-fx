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

begin

end architecture rtl;
