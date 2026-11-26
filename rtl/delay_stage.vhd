-- delay_stage: delay / echo (effect #5). A circular buffer in block RAM
-- holds the last 2**g_addr_bits samples; the output adds the sample from
-- delay_samples ago to the dry one, and feeds some of it back in so the
-- echo repeats.
--
--   write: buffer[wr_ptr] = in + feedback x echo   (saturated)
--   out:   in x (1 - mix) + echo x mix             (a crossfade, saturated)
--   echo:  buffer[wr_ptr - delay_samples]
--
--   sample_in     : Q1.23
--   delay_samples : how many samples back the echo is, 0 .. 2**g_addr_bits
--                   - 1 (15 bits: up to 683 ms at 48 kHz). 0 reads the slot
--                   about to be written, i.e. the oldest sample: use >= 1.
--   feedback      : Q.15, how much of the echo goes back in: 0 one repeat,
--                   0.5 each repeat half the last. Clamped here to 0 ..
--                   just below 1.0 (0x7FFF): at 1.0 the echoes never fade
--                   and above it they grow until they clip. The effect
--                   guards itself whoever drives the port; fx.py also
--                   refuses feedback >= 1.0 with a clear error (both,
--                   decided 2026-11-25).
--   mix           : Q.15, 0 dry only .. 1.0 (0x8000) echo only. Clamped to
--                   0 .. 1.0 (above 1.0 the dry gain would go negative).
--   sample_out    : Q1.23, saturated
--
-- Pointers: both g_addr_bits wide, so wr_ptr + 1 and wr_ptr - delay_samples
-- wrap on their own (a power-of-two buffer, no compare). wr_ptr moves on
-- the edge the sample is written: the RAM process on that edge still uses
-- the old value. Moving it earlier would make every echo one sample late.
--
-- Block RAM: written in the inference pattern (registered read, no reset
-- on the array), 1024 x 24 bits per RAMB36, so 2**15 samples = 32 of the
-- A7-35T's 50. The RAM reads every clock, so the echo for the next sample
-- is waiting in s_ram_rdata long before it arrives. Starts as zeros
-- (silence): an initial value, which Vivado puts in the bitstream.
--
-- Timing for one sample (clock 0 = sample_in_valid):
--   0: three gain_stages start (echo x feedback, in x (1 - mix),
--      echo x mix); s_dry holds the input
--   1: write sum (s_dry + echo x feedback, saturated) -> s_wr_data, s_wr_en;
--      output sum (the two mix products, saturated) -> sample_out
--   2: sample_out_valid; RAM written at wr_ptr; wr_ptr + 1
-- Latency 2 clocks; samples must be at least 4 clocks apart (~2083 in the
-- real design). Reset clears the pointer and the gain_stages, not the
-- buffer: old echoes may still come out after a reset.

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
    signal s_mix      : signed(17 downto 0); -- mix after the clamp: use this, not the port

    -- The buffer: 2**g_addr_bits samples. Written in the block RAM pattern
    -- (registered read, no reset on the array) so Vivado builds block RAM.

    type t_ram is array (0 to 2 ** g_addr_bits - 1) of signed(23 downto 0); -- one Q1.23 sample per entry

    -- No reset (block RAM can't be cleared in a clock). The initial value is
    -- loaded into the block RAM with the bitstream: silence at power-up, and
    -- zeros, not 'U', in simulation.
    signal s_ram : t_ram := (others => (others => '0'));

    signal s_wr_ptr    : unsigned(g_addr_bits - 1 downto 0) := (others => '0'); -- where the next sample is written
    signal s_rd_addr   : unsigned(g_addr_bits - 1 downto 0);                    -- where the echo is read: s_wr_ptr - delay_samples
    signal s_wr_en     : std_logic;                                             -- one clock: write s_wr_data at s_wr_ptr
    signal s_wr_data   : signed(23 downto 0);                                   -- what is written: input + feedback x echo
    signal s_ram_rdata : signed(23 downto 0);                                   -- the echo, one clock after s_rd_addr

    signal s_fb_echo       : signed(23 downto 0); -- echo x feedback, from feedback_gain
    signal s_fb_echo_valid : std_logic;           -- one clock: s_fb_echo is new (1 clock after sample_in_valid)
    signal s_dry           : signed(23 downto 0); -- sample_in held, lines up with s_fb_echo for the add

    signal s_dry_gain  : signed(17 downto 0); -- 1 - mix, Q.15: the dry level
    signal s_dry_mix   : signed(23 downto 0); -- in x (1 - mix), from dry_mix_gain
    signal s_echo_mix  : signed(23 downto 0); -- echo x mix, from echo_mix_gain
    signal s_mix_valid : std_logic;           -- one clock: both mix products are new

begin

    -- Feedback clamp: 1.0 (32768) and above would never fade, so cap it just
    -- below; negatives (they would flip the echo each repeat) clamp to 0.
    s_feedback <= to_signed(32767, 18) when feedback >= 32768 else -- 1.0 or more: just below 1.0 (0x7FFF)
                  to_signed(0, 18) when feedback < 0 else          -- negative: no feedback
                  feedback;

    -- Mix clamp: 0 .. 1.0 (1.0 itself is fine: echo only). Above 1.0 the
    -- dry gain 1 - mix would go negative and flip the dry signal.
    s_mix <= to_signed(32768, 18) when mix > 32768 else -- above 1.0: 1.0
             to_signed(0, 18) when mix < 0 else         -- negative: dry only
             mix;

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

    -- What goes back into the buffer: input + feedback x echo. Two Q1.23
    -- values can add up to ~2.0, so add 1 bit wider and saturate back to
    -- 24 bits (like hard_clip_stage). s_wr_en pulses for one clock.
    write_add : process (clk) is

        variable v_sum : signed(24 downto 0); -- the sum, 1 bit wider: can't wrap

    begin

        if rising_edge(clk) then
            s_wr_en <= '0';                                         -- default: no write

            if (s_fb_echo_valid = '1') then                         -- the product is ready
                v_sum := resize(s_fb_echo, 25) + resize(s_dry, 25);

                if (v_sum > to_signed(2 ** 23 - 1, 24)) then        -- above the biggest Q1.23 value
                    s_wr_data <= to_signed(2 ** 23 - 1, 24);
                elsif (v_sum < to_signed(-2 ** 23, 24)) then        -- below the most negative
                    s_wr_data <= to_signed(-2 ** 23, 24);
                else
                    s_wr_data <= resize(v_sum, 24);                 -- fits: back to 24 bits
                end if;

                s_wr_en <= '1';
            end if;
        end if;

    end process write_add;

    -- Write pointer: moves on with the write, on the same edge, so the RAM
    -- process (same edge) still writes at the old address.
    pointer : process (clk) is
    begin

        if rising_edge(clk) then
            if (reset = '1') then
                s_wr_ptr <= (others => '0');
            elsif (s_wr_en = '1') then                          -- a write happens
                s_wr_ptr <= s_wr_ptr + 1;                       -- next slot (wraps on its own)
            end if;
        end if;

    end process pointer;

    -- The mix, a crossfade: sample_out = dry x (1 - mix) + echo x mix.
    -- 1.0 is 32768 in Q.15, so the dry gain is 32768 - mix.
    s_dry_gain <= 32768 - s_mix;

    -- Dry x (1 - mix), 1 clock. sample_in is still valid on its valid clock.
    dry_mix_gain : entity work.gain_stage
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_in,
            sample_in_valid  => sample_in_valid,
            gain             => s_dry_gain,
            sample_out       => s_dry_mix,
            sample_out_valid => s_mix_valid
        );

    -- Echo x mix, 1 clock: same clock in and out as dry_mix_gain, so the two
    -- products arrive together.
    echo_mix_gain : entity work.gain_stage
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => s_ram_rdata,
            sample_in_valid  => sample_in_valid,
            gain             => s_mix,
            sample_out       => s_echo_mix,
            sample_out_valid => open
        );

    -- Add the two products. The weights add up to 1.0, so the sum stays in
    -- range (each product is rounded, so it can be 1 LSB over: saturate
    -- anyway, the same way as write_add).
    mix_add : process (clk) is

        variable v_mix_sum : signed(24 downto 0); -- 1 bit wider: can't wrap

    begin

        if rising_edge(clk) then
            sample_out_valid <= '0';                                         -- default: no new sample

            if (s_mix_valid = '1') then                                      -- both products are ready
                v_mix_sum := resize(s_dry_mix, 25) + resize(s_echo_mix, 25);

                if (v_mix_sum > to_signed(2 ** 23 - 1, 24)) then             -- above the biggest Q1.23 value
                    sample_out <= to_signed(2 ** 23 - 1, 24);
                elsif (v_mix_sum < to_signed(-2 ** 23, 24)) then             -- below the most negative
                    sample_out <= to_signed(-2 ** 23, 24);
                else
                    sample_out <= resize(v_mix_sum, 24);                     -- fits: back to 24 bits
                end if;

                sample_out_valid <= '1';
            end if;
        end if;

    end process mix_add;

end architecture rtl;
