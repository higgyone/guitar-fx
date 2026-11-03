library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity soft_start is
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
end entity soft_start;

architecture rtl of soft_start is

    type t_state is (st_mute, st_ramp, st_run); -- the list of states

    signal s_state : t_state := st_mute; -- the current state

    signal s_counter : natural range 0 to g_mute_samples - 1 := 0; -- samples counted in the current state

    signal s_gain : signed(17 downto 0) := (others => '0'); -- gain for the gain_stage, Q3.15

begin

    gain_stage0 : entity work.gain_stage
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_in,
            sample_in_valid  => sample_in_valid,
            gain             => s_gain,
            sample_out       => sample_out,
            sample_out_valid => sample_out_valid
        );

    soft_start_proc : process (clk) is
    begin

        if rising_edge(clk) then
            if (reset = '1') then
                s_counter <= 0;
                s_gain    <= (others => '0');
                s_state   <= st_mute;
            elsif (sample_in_valid = '1') then

                case s_state is

                    when st_mute =>

                        s_gain <= (others => '0');
                        -- last mute sample reached
                        if (s_counter = g_mute_samples - 1) then
                            s_counter <= 0;
                            s_state   <= st_ramp;
                        else
                            s_counter <= s_counter + 1;
                        end if;

                    when st_ramp =>

                        -- last ramp sample reached
                        if (s_counter = 2 ** g_ramp_bits - 1) then
                            s_counter <= 0;
                            s_gain    <= to_signed(2 ** 15, 18);                               -- increment gain to 1.0
                            s_state   <= st_run;
                        else
                            s_counter <= s_counter + 1;
                            -- Ramp gain = counter x 2^(15 - g_ramp_bits), Q3.15.
                            -- Gain must climb from 0 to 1.0 = 2^15 (32,768) in
                            -- 2^g_ramp_bits samples, so each sample adds
                            -- 2^15 / 2^g_ramp_bits = 2^(15 - g_ramp_bits).
                            -- Default g_ramp_bits = 11: 2,048 samples (42.7 ms),
                            -- step 2^4 = 16. Power-of-2 lengths keep the step a
                            -- whole number (2,400 samples would need 13.65), and
                            -- x 2^n is a left shift, so no multiplier is used.
                            s_gain <= to_signed(s_counter * 2 ** (15 - g_ramp_bits), 18);
                        end if;

                    when st_run =>

                        s_gain <= to_signed(2 ** 15, 18);                                      -- gain = 1.0, Q3.15

                end case;

            end if;
        end if;

    end process soft_start_proc;

end architecture rtl;
