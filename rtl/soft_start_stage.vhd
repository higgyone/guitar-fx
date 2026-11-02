library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity soft_start_stage is
    generic (
        g_mute_samples : natural := 144000; -- samples muted after reset, 144,000 = 3 s at 48 kHz.
        g_ramp_bits    : natural := 11      -- ramp length = 2^g_ramp_bits samples, 11 → 2,048 = 42.7 ms.
    );
    port (
        clk              : in    std_logic;
        reset            : in    std_logic;
        sample_in        : in    signed(23 downto 0);
        sample_in_valid  : in    std_logic;
        sample_out       : out   signed(23 downto 0);
        sample_out_valid : out   std_logic
    );
end entity soft_start_stage;
