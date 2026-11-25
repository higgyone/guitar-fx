-- delay_stage: delay / echo (effect #5). A circular buffer in block RAM
-- holds the last 2**g_addr_bits samples; the output adds the sample from
-- delay_samples ago to the dry one, and feeds some of it back in so the
-- echo repeats.
--
-- Feedback is clamped here, below 1.0 (0x8000 and up -> 0x7FFF): at 1.0 the
-- echoes never fade and above it they grow until they clip. The effect
-- guards itself whoever drives the port; fx.py also refuses feedback >= 1.0
-- with a clear error (both, decided 2026-11-25).
--
--   (header to be finished once the design is done)

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity delay_stage is
    generic (
        g_addr_bits : natural := 15 -- buffer = 2**15 = 32 768 samples = 683 ms
    );
    port (
        clk              : in    std_logic;
        reset            : in    std_logic;
        sample_in        : in    signed(23 downto 0);
        sample_in_valid  : in    std_logic;
        delay_samples    : in    unsigned(g_addr_bits - 1 downto 0); -- read this many samples back, 0 .. 2**g_addr_bits - 1 (pointer width, so it wraps)
        feedback         : in    signed(17 downto 0);                -- echo fed back in, Q.15: 0 none .. below 1.0 (1.0 = never fades)
        mix              : in    signed(17 downto 0);                -- echo level, Q.15: 0 dry only .. 1.0 (0x8000) echo only
        sample_out       : out   signed(23 downto 0);
        sample_out_valid : out   std_logic
    );
end entity delay_stage;

architecture rtl of delay_stage is

    signal s_feedback : signed(17 downto 0); -- feedback after the clamp: use this, not the port

    -- The buffer: 2**g_addr_bits samples. Written in the block RAM pattern
    -- (registered read, no reset on the array) so Vivado builds block RAM.

    type t_ram is array (0 to 2 ** g_addr_bits - 1) of signed(23 downto 0); -- one Q1.23 sample per entry

    signal s_ram : t_ram; -- no reset and no initial value: starts as zeros (silence)

    signal s_wr_ptr    : unsigned(g_addr_bits - 1 downto 0) := (others => '0'); -- where the next sample is written
    signal s_rd_addr   : unsigned(g_addr_bits - 1 downto 0);                    -- where the echo is read: s_wr_ptr - delay_samples
    signal s_wr_en     : std_logic;                                             -- one clock: write s_wr_data at s_wr_ptr
    signal s_wr_data   : signed(23 downto 0);                                   -- what is written: input + feedback x echo
    signal s_ram_rdata : signed(23 downto 0);                                   -- the echo, one clock after s_rd_addr

    signal s_fb_echo       : signed(23 downto 0); -- echo x feedback, from feedback_gain
    signal s_fb_echo_valid : std_logic;           -- one clock: s_fb_echo is new (1 clock after sample_in_valid)
    signal s_dry           : signed(23 downto 0); -- sample_in held, lines up with s_fb_echo for the add

begin

    -- Feedback clamp: 1.0 (32768) and above would never fade, so cap it just
    -- below; negatives (they would flip the echo each repeat) clamp to 0.
    s_feedback <= to_signed(32767, 18) when feedback >= 32768 else -- 1.0 or more: just below 1.0 (0x7FFF)
                  to_signed(0, 18) when feedback < 0 else          -- negative: no feedback
                  feedback;

    -- Read address: wraps on its own because both are g_addr_bits wide.
    s_rd_addr <= s_wr_ptr - delay_samples;

    -- The block RAM: one write port, one read port, both on the clock.
    ram : process (clk) is
    begin

        if rising_edge(clk) then
            if (s_wr_en = '1') then                       -- write the new sample
                s_ram(to_integer(s_wr_ptr)) <= s_wr_data;
            end if;
            s_ram_rdata <= s_ram(to_integer(s_rd_addr));  -- read: registered, 1 clock late
        end if;

    end process ram;

    -- Feedback multiply: echo x s_feedback, 1 clock (gain_stage rounds and
    -- saturates). Its sample_out_valid is the "go" for the saturating add.
    feedback_gain : entity work.gain_stage
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => s_ram_rdata,
            sample_in_valid  => sample_in_valid,
            gain             => s_feedback,
            sample_out       => s_fb_echo,
            sample_out_valid => s_fb_echo_valid
        );

    -- The input must wait 1 clock to line up with the product for the add.
    dry_delay : process (clk) is
    begin

        if rising_edge(clk) then
            if (sample_in_valid = '1') then
                s_dry <= sample_in;
            end if;
        end if;

    end process dry_delay;

-- TODO (next): saturating add s_dry + s_fb_echo -> s_wr_data / s_wr_en,
-- s_wr_ptr moved on with the write; then the mix (32768 - mix, two
-- gain_stages, plain add) -> sample_out / sample_out_valid.

end architecture rtl;
