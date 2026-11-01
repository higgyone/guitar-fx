library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity gain_stage is
    port (
        clk              : in    std_logic;
        reset            : in    std_logic;
        sample_in        : in    signed(23 downto 0);
        sample_in_valid  : in    std_logic;
        gain             : in    signed(17 downto 0);
        sample_out       : out   signed(23 downto 0);
        sample_out_valid : out   std_logic
    );
end entity gain_stage;

architecture rtl of gain_stage is

    signal s_sample_gain : signed(41 downto 0) := (others => '0'); -- sample x gain result
    signal s_gain_slice  : signed(23 downto 0) := (others => '0'); -- 24 bit slice of the gain result

begin

    gain_proc : process (clk) is
    begin

        if rising_edge(clk) then
            sample_out_valid <= '0';
            if (reset = '1') then
                s_sample_gain <= (others => '0');
            elsif (sample_in_valid = '1') then
                s_sample_gain    <= sample_in * gain; -- sample x gain, Q4.38 (42 bits), registered
                sample_out_valid <= '1';
            end if;                                   -- no else: s_sample_gain holds its value
        end if;

    end process gain_proc;

    s_gain_slice <= s_sample_gain(38 downto 15); -- Q4.38 product → Q1.23: bits 38..15 (truncates 15 LSBs, drops 3 MSBs)
    sample_out   <= s_gain_slice;

end architecture rtl;


