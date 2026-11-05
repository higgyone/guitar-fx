-- Self-checking testbench for i2s_tx, with i2s_clocks making the real
-- strobes and a model of the CS4344 DAC reading sdin.
--
-- DAC model (CS4344, I2S format): on every sclk rising edge it reads sdin.
-- Counting rising edges k from each lrck change: k = 0 is the I2S delay
-- bit, k = 1 .. 24 are b23 .. b0, k = 25 .. 31 padding. It rebuilds the left
-- and the right 24-bit words of every frame.
--
-- Stimulus: one sample per frame on sample_in / sample_in_valid, at a
-- different point in each frame: mid-left-slot (where i2s_rx's output
-- lands), on the frame_start clock itself, the clock after it, on the
-- m = 32 clock (right slot reload), the last clock before frame_start, ...
--
-- Expected (the spec, not the design): a frame sends the last sample that
-- arrived BEFORE its frame_start clock, in BOTH slots. A sample arriving on
-- the frame_start clock itself is sent one frame later.
--
-- Checks:
--   1. Left word = right word = expected sample, every whole frame
--      (edge cases: 0, +1, -1, max, min, 0x555555, 0xAAAAAA, ...).
--   2. sdin = '0' on the delay bits and the padding.
--   3. sdin never changes near an sclk rising edge (stable 30 ns before
--      and after, where the DAC samples): it must change on sclk falling.
--   4. After a reset of i2s_tx in the middle of a frame (clocks running),
--      later frames are right again.
--   5. Enough frames were checked.
--
-- Run (repo root, PowerShell):
--   ghdl -a --std=08 -Wall --workdir=$env:TEMP rtl/i2s_clocks.vhd rtl/i2s_tx.vhd sim/i2s_tx_tb.vhd
--   ghdl -r --std=08 --workdir=$env:TEMP i2s_tx_tb
-- Vivado: set i2s_tx_tb as the simulation top, Run Behavioral Simulation.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity i2s_tx_tb is
end entity i2s_tx_tb;

architecture sim of i2s_tx_tb is

    constant clk_period : time    := 10172 ps; -- ~98.304 MHz, even ps
    constant c_frames   : natural := 22;       -- frames to run
    constant c_reset_at : natural := 12;       -- frame with the mid-frame reset
    constant c_stable   : time    := 30 ns;    -- sdin stable around sclk rising

    type t_ints is array (natural range <>) of integer;

    constant c_samples : t_ints :=
    (
        2 ** 23 - 1,          -- max positive
        -(2 ** 23),           -- min negative
        -1,
        1,
        16#555555#,
        16#2AAAAA# - 2 ** 23, -- 0xAAAAAA as a signed 24-bit value
        16#123456#,
        -16#123456#,
        2 ** 22,              -- 0.5
        -(2 ** 22),           -- -0.5
        0,
        12345,
        -54321
    );

    -- When sample_in_valid comes, in clocks after the frame_start clock.
    -- -1 = on the frame_start clock itself; 1023 = the m = 32 sclk_fall
    -- clock (right slot reload); 2046 = the last clock before frame_start.
    constant c_offsets : t_ints := (790, -1, 0, 1023, 500, 2046, 1500, 10);

    signal clk             : std_logic           := '0';
    signal clk_reset       : std_logic           := '1';
    signal tx_reset        : std_logic           := '1';
    signal mclk            : std_logic;
    signal sclk            : std_logic;
    signal lrck            : std_logic;
    signal sclk_rise       : std_logic;
    signal sclk_fall       : std_logic;
    signal frame_start     : std_logic;
    signal sample_in       : signed(23 downto 0) := (others => '0');
    signal sample_in_valid : std_logic           := '0';
    signal sdin            : std_logic;

    -- Expected sample of the current frame, from the spec model.
    signal exp_sample : signed(23 downto 0) := (others => '0');
    signal frame_no   : integer             := -1;    -- frame_starts seen
    signal frame_ok   : boolean             := false; -- no tx reset in this frame

    signal frames_checked : natural := 0;

begin

    clk <= not clk after clk_period / 2;

    clocks : entity work.i2s_clocks
        port map (
            clk         => clk,
            reset       => clk_reset,
            mclk        => mclk,
            sclk        => sclk,
            lrck        => lrck,
            sclk_rise   => sclk_rise,
            sclk_fall   => sclk_fall,
            frame_start => frame_start
        );

    dut : entity work.i2s_tx
        port map (
            clk             => clk,
            reset           => tx_reset,
            sample_in       => sample_in,
            sample_in_valid => sample_in_valid,
            sclk_fall       => sclk_fall,
            frame_start     => frame_start,
            sdin            => sdin
        );

    -- Resets: everything at the start; later only i2s_tx, in the middle of
    -- frame c_reset_at's left slot, with the clocks running.
    resets : process is
    begin

        for i in 1 to 4 loop

            wait until rising_edge(clk);

        end loop;

        clk_reset <= '0';
        tx_reset  <= '0';

        wait until frame_no = c_reset_at;

        for i in 1 to 300 loop

            wait until rising_edge(clk);

        end loop;

        report "resetting i2s_tx in the middle of a frame"
            severity note;
        tx_reset <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        tx_reset <= '0';
        wait;

    end process resets;

    -- One sample per frame, at the offset for that frame.
    stimulus : process is

        variable n   : natural := 0;
        variable off : integer;

    begin

        wait until clk_reset = '0';

        loop

            off := c_offsets(n mod c_offsets'length);
            -- frame_start goes high just after the clock edge before the
            -- frame_start clock.
            wait until frame_start = '1';

            if (off >= 0) then
                wait until rising_edge(clk); -- the frame_start clock edge

                for i in 1 to off loop

                    wait until rising_edge(clk);

                end loop;

            end if;

            sample_in       <= to_signed(c_samples(n mod c_samples'length), 24);
            sample_in_valid <= '1';
            wait until rising_edge(clk);
            sample_in_valid <= '0';
            n               := n + 1;

        end loop;

    end process stimulus;

    -- Spec model: what each frame must send. Clocked like the design, so it
    -- sees every input as it was just before the edge.
    model : process is

        variable hold : signed(23 downto 0) := (others => '0');

    begin

        wait until rising_edge(clk);

        if (tx_reset = '1') then
            hold       := (others => '0');
            exp_sample <= (others => '0');
            frame_ok   <= false;
        else
            if (frame_start = '1') then
                exp_sample <= hold; -- the sample from before this clock
                frame_no   <= frame_no + 1;
                frame_ok   <= true;
            end if;

            if (sample_in_valid = '1') then
                hold := sample_in;
            end if;
        end if;

    end process model;

    -- CS4344 model: reads sdin on sclk rising edges, rebuilds both words,
    -- checks them at the end of the right slot.
    dac : process is

        variable p_lrck : std_logic := '0';
        variable k      : integer   := -1;   -- rising edge in the slot, -1 = not started
        variable word   : signed(23 downto 0);
        variable left   : signed(23 downto 0);
        variable zeros  : boolean   := true; -- delay bit and padding were all '0'
        variable got_l  : boolean   := false;

    begin

        wait until rising_edge(sclk);

        if (lrck /= p_lrck) then
            k := 0;
            if (lrck = '0') then
                zeros := true; -- new frame
                got_l := false;
            end if;
        elsif (k >= 0) then
            k := k + 1;
        end if;

        p_lrck := lrck;

        if (k >= 1 and k <= 24) then
            word(24 - k) := sdin;
        elsif (k >= 0 and sdin /= '0') then
            zeros := false;
        end if;

        if (k = 24 and lrck = '0') then
            left  := word;
            got_l := true;
        end if;

        -- End of the right slot (after its padding): check the frame.
        if (k = 31 and lrck = '1' and got_l and frame_ok and frame_no >= 1) then
            -- 1. Both slots carry the expected sample.
            assert left = exp_sample
                report "frame " & integer'image(frame_no) & ": left = "
                       & integer'image(to_integer(left)) & ", expected "
                       & integer'image(to_integer(exp_sample))
                severity failure;
            assert word = exp_sample
                report "frame " & integer'image(frame_no) & ": right = "
                       & integer'image(to_integer(word)) & ", expected "
                       & integer'image(to_integer(exp_sample))
                       & " (left = " & integer'image(to_integer(left)) & ")"
                severity failure;
            -- 2. Delay bits and padding are '0'.
            assert zeros
                report "frame " & integer'image(frame_no)
                       & ": sdin not '0' on a delay bit or the padding"
                severity failure;
            frames_checked <= frames_checked + 1;
        end if;

    end process dac;

    -- 3. sdin stable around every sclk rising edge (the DAC's sample point).
    timing : process is
    begin

        wait until rising_edge(sclk);

        if (clk_reset = '0' and tx_reset = '0') then
            assert sdin'last_event >= c_stable
                report "sdin changed " & time'image(sdin'last_event)
                       & " before an sclk rising edge (must change on sclk falling)"
                severity failure;
            wait for c_stable;
            assert sdin'last_event >= c_stable
                report "sdin changed less than " & time'image(c_stable)
                       & " after an sclk rising edge (must change on sclk falling)"
                severity failure;
        end if;

    end process timing;

    -- 5. Ends the run and reports.
    end_run : process is
    begin

        wait until frame_no = c_frames;
        wait until rising_edge(clk);
        -- Frames 0 .. c_frames - 1 minus frame 0 (sent before any input)
        -- and the reset frame are checked; allow one at the end.
        assert frames_checked >= c_frames - 3
            report "only " & integer'image(frames_checked) & " frames checked"
            severity failure;
        report integer'image(frames_checked) & " frames checked (left = right = expected)"
            severity note;
        report "ALL TESTS PASSED"
            severity note;
        std.env.finish;

    end process end_run;

end architecture sim;
