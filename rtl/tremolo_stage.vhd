----------------------------------------------------------------------------------
-- Company:
-- Engineer:
--
-- Create Date: 12.11.2026 18:28:16
-- Design Name:
-- Module Name: tremelo_stage - rtl
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
    use ieee.math_real.all;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
-- use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
-- library UNISIM;
-- use UNISIM.VComponents.all;

entity tremolo_stage is
    generic (
        g_rate_hz     : real := 5.0;
        g_sample_rate : real := 48000.0
    );
    port (
        clk              : in    std_logic;
        reset            : in    std_logic;
        sample_in        : in    signed(23 downto 0);
        sample_in_valid  : in    std_logic;
        sample_out       : out   signed(23 downto 0);
        sample_out_valid : out   std_logic
    );
end entity tremolo_stage;

architecture rtl of tremolo_stage is

    type t_sin is array (0 to 1023) of signed(17 downto 0);

    function generate_sine_values
    return t_sin is

        variable table : t_sin; -- the table being built

    begin

        for i in 0 to 1023 loop

            table(i) := to_signed(integer(round(sin(MATH_2_PI * real(i) / 1024.0) * real(2 ** 15 - 1))), 18); -- entry i: tanh(k * i / 1024) / tanh(k), as Q1.23

        end loop;

        return table;

    end function generate_sine_values;

    constant c_sin  : t_sin                 := generate_sine_values;
    constant c_step : unsigned(31 downto 0) := to_unsigned(integer(round(g_rate_hz * 2.0 ** 32 / g_sample_rate)), 32);

    signal s_phase         : unsigned(31 downto 0) := (others => '0');
    signal s_valid         : std_logic;
    signal s_address       : unsigned(9 downto 0);
    signal s_current_phase : signed(17 downto 0);

begin

    tremolo_proc : process (clk) is
    begin

        if rising_edge(clk) then
            s_current_phase <= c_sin(to_integer(s_address));

            if (reset = '1') then
            elsif (s_valid = '1') then
                s_phase <= s_phase + c_step;
            end if;
        end if;

    end process tremolo_proc;

    s_address <= s_phase(31 downto 22);

end architecture rtl;
