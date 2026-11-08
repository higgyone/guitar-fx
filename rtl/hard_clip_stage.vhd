-- hard_clip_stage: hard-clip distortion. Each sample is limited to
-- +/- threshold: anything above +threshold becomes +threshold, anything
-- below -threshold becomes -threshold, everything else passes unchanged.
-- Put a gain_stage (drive) in front to push the signal into the clip.
--
--   sample_in  : Q1.23 (range -1.0 to +1.0 - 2^-23)
--   threshold  : Q0.23 unsigned (0 .. 1.0 - 2^-23), same scale as Q1.23
--                but no sign bit. The type makes a negative threshold
--                impossible; inside it is widened to a positive 24-bit
--                signed ('0' on top), so the largest, 0x7FFFFF, negates
--                safely to -0x7FFFFF. 0 clips every sample to 0.
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
        threshold        : in    unsigned(22 downto 0); -- clip level, Q0.23
        sample_out       : out   signed(23 downto 0);
        sample_out_valid : out   std_logic
    );
end entity hard_clip_stage;

architecture rtl of hard_clip_stage is

    signal s_clipped   : signed(23 downto 0) := (others => '0'); -- clipped sample, Q1.23
    signal s_threshold : signed(23 downto 0) := (others => '0'); -- threshold as Q1.23, always >= 0

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
                if (sample_in > s_threshold) then
                    s_clipped <= s_threshold;
                elsif (sample_in < -s_threshold) then
                    s_clipped <= -s_threshold;
                else
                    s_clipped <= sample_in;
                end if;

                sample_out_valid <= '1';
            end if;                                   -- no else: s_clipped holds its value
        end if;

    end process hard_clip_proc;

    -- Q0.23 unsigned -> Q1.23 signed: a '0' sign bit on top keeps it positive.
    s_threshold <= signed('0' & threshold);

    sample_out <= s_clipped;

end architecture rtl;
