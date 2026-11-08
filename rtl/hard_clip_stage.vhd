-- hard_clip_stage: hard-clip distortion. Each sample is limited to
-- +/- threshold: anything above +threshold becomes +threshold, anything
-- below -threshold becomes -threshold, everything else passes unchanged.
-- Put a gain_stage (drive) in front to push the signal into the clip.
--
--   sample_in  : Q1.23 (range -1.0 to +1.0 - 2^-23)
--   threshold  : Q1.23, must be POSITIVE (0 .. 0x7FFFFF). 0 clips every
--                sample to 0. A negative value is wrong: e.g. 0x800000
--                (-1.0) negates to itself in 24 bits, so -threshold is also
--                -1.0 and every sample comes out as -1.0.
--   sample_out : Q1.23, clipped
--
-- Latency: 1 clock. sample_out_valid pulses for one clock, one clock after
-- sample_in_valid. sample_out holds its value between samples.
-- The clamp is worked out before the register, so a change of threshold
-- only shows in sample_out at the next sample.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity hard_clip_stage is
    port (
        clk              : in    std_logic;
        reset            : in    std_logic;
        sample_in        : in    signed(23 downto 0);
        sample_in_valid  : in    std_logic;
        threshold        : in    signed(23 downto 0); -- (Q1.23, positive)
        sample_out       : out   signed(23 downto 0);
        sample_out_valid : out   std_logic
    );
end entity hard_clip_stage;

architecture rtl of hard_clip_stage is

    signal s_clipped : signed(23 downto 0) := (others => '0'); -- clipped sample, Q1.23

begin

    -- Clips the sample and registers it when a new sample arrives, and
    -- raises sample_out_valid for that one clock.
    hard_clip_proc : process (clk) is
    begin

        if rising_edge(clk) then
            sample_out_valid <= '0';                  -- default: low; set high below for one clock
            if (reset = '1') then
                s_clipped <= (others => '0');
            elsif (sample_in_valid = '1') then
                if (sample_in > threshold) then
                    s_clipped <= threshold;
                elsif (sample_in < -threshold) then
                    s_clipped <= -threshold;
                else
                    s_clipped <= sample_in;
                end if;

                sample_out_valid <= '1';
            end if;                                   -- no else: s_clipped holds its value
        end if;

    end process hard_clip_proc;

    sample_out <= s_clipped;

end architecture rtl;
