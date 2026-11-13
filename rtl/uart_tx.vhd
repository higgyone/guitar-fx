library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_tx is
    generic (
        g_clks_per_bit : natural := 853 -- s_clk clocks per UART bit (98.305 MHz / 115 200)
    );
    port (
        clk           : in    std_logic;
        reset         : in    std_logic;
        data_in       : in    std_logic_vector(7 downto 0); -- 1. "st_logic_vector"
        data_in_valid : in    std_logic;
        tx            : out   std_logic;                    -- 2. ");" here
        busy          : out   std_logic
    );
end entity uart_tx;

architecture rtl of uart_tx is

    signal s_shift      : std_logic_vector(9 downto 0)          := (others => '1'); -- start bit, 8 data bits, stop bit
    signal s_baud_count : natural range 0 to g_clks_per_bit - 1 := 0;               -- counts the number of clock cycles for each bit
    signal s_bit_count  : natural range 0 to 9                  := 0;               -- counts the number of bits transmitted
    signal s_busy       : std_logic                             := '0';             -- indicates if the UART is busy transmitting

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
