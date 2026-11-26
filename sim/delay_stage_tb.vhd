-- Self-checking testbench for delay_stage.
--
-- A 16-sample buffer (g_addr_bits = 4) so the pointers wrap within a few
-- samples; sample_in_valid every 8 clocks instead of every ~2083 (the block
-- counts samples, not clocks).
--
-- Every output is compared bit for bit with a model in this file that does
-- the same sums with the same rounding (gain_stage: round half up, then
-- saturate) on its own 16-entry buffer and pointer. On top of that, named
-- checks in plain numbers:
--   1. A click comes back exactly delay_samples later (feedback 0,
--      mix 0.5: half the click now, half of it D samples later), and the
--      pointer wraps (D = 15, more than 16 samples sent).
--   2. Feedback 0.5, mix 1.0: echoes at D, 2D, 3D of 1/2, 1/4, 1/8.
--   3. Feedback clamp: 1.0 and 3.0 on the port behave as 0x7FFF (each
--      repeat a little smaller, never growing); -0.5 behaves as 0 (one
--      echo only).
--   4. Mix clamp and ends: mix 0 = dry only (out = in exactly), mix 1.0 =
--      echo only, mix 1.5 behaves as 1.0, mix -0.5 as 0.
--   5. Saturation: a loud constant input with feedback ~1.0 fills the
--      buffer up to full scale; the output stays positive (the write sum
--      saturates instead of wrapping to a big negative value).
--   6. One output per input, 2 clocks after it.
--
-- The buffer starts as zeros (its initial value in the design), so the
-- model's buffer does too. Without that initial value it would start as
-- 'U' in simulation and the first pass through it would compare 'X'.
--
-- xsim (from a scratch folder):
--   xvhdl -2008 rtl/gain_stage.vhd rtl/delay_stage.vhd sim/delay_stage_tb.vhd
--   xelab delay_stage_tb -s delay_tb
--   xsim delay_tb -R

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library std;
    use std.env.all;

entity delay_stage_tb is
end entity delay_stage_tb;

architecture sim of delay_stage_tb is

    constant clk_period   : time    := 10 ns;
    constant c_addr_bits  : natural := 4;           -- 16-sample buffer
    constant c_size       : natural := 2 ** c_addr_bits;
    constant c_clocks_per : natural := 8;           -- clocks between samples
    constant c_half       : integer := 2 ** 22;     -- 0.5 full scale
    constant c_max        : integer := 2 ** 23 - 1; -- Q1.23 max
    constant c_one        : integer := 32768;       -- 1.0 in Q.15

    signal clk              : std_logic                          := '0';
    signal reset            : std_logic                          := '1';
    signal sample_in        : signed(23 downto 0)                := (others => '0');
    signal sample_in_valid  : std_logic                          := '0';
    signal delay_samples    : unsigned(c_addr_bits - 1 downto 0) := (others => '0');
    signal feedback         : signed(17 downto 0)                := (others => '0');
    signal mix              : signed(17 downto 0)                := (others => '0');
    signal sample_out       : signed(23 downto 0);
    signal sample_out_valid : std_logic;

    signal sim_done : boolean := false;

    -- The model's buffer.

    type t_buf is array (0 to c_size - 1) of signed(23 downto 0);

    -- The gain_stage sum: x * g (Q1.23 x Q.15), + half an LSB, >> 15,
    -- saturated to Q1.23.

    function model_gain (
        x : signed(23 downto 0);
        g : signed(17 downto 0)
    ) return signed is

        variable p : signed(41 downto 0);

    begin

        p := x * g + to_signed(2 ** 14, 42);
        p := shift_right(p, 15);

        if (p > to_signed(c_max, 42)) then
            return to_signed(c_max, 24);
        elsif (p < to_signed(-c_max - 1, 42)) then
            return to_signed(-c_max - 1, 24);
        end if;

        return resize(p, 24);

    end function model_gain;

    -- a + b, saturated to Q1.23.

    function model_add (
        a : signed(23 downto 0);
        b : signed(23 downto 0)
    ) return signed is

        variable s : signed(24 downto 0);

    begin

        s := resize(a, 25) + resize(b, 25);

        if (s > to_signed(c_max, 25)) then
            return to_signed(c_max, 24);
        elsif (s < to_signed(-c_max - 1, 25)) then
            return to_signed(-c_max - 1, 24);
        end if;

        return resize(s, 24);

    end function model_add;

    -- The clamps, as the design should do them.

    function clamp (
        v : signed(17 downto 0);
        hi : integer
    ) return signed is
    begin

        if (v > hi) then
            return to_signed(hi, 18);
        elsif (v < 0) then
            return to_signed(0, 18);
        end if;

        return v;

    end function clamp;

begin

    clk <= not clk after clk_period / 2 when not sim_done;

    dut : entity work.delay_stage
        generic map (
            g_addr_bits => c_addr_bits
        )
        port map (
            clk              => clk,
            reset            => reset,
            sample_in        => sample_in,
            sample_in_valid  => sample_in_valid,
            delay_samples    => delay_samples,
            feedback         => feedback,
            mix              => mix,
            sample_out       => sample_out,
            sample_out_valid => sample_out_valid
        );

    stimulus : process is

        variable buf      : t_buf   := (others => (others => '0'));
        variable ptr      : natural := 0;
        variable n_sent   : natural := 0;
        variable n_checks : natural := 0;
        variable last     : signed(23 downto 0); -- the last output

        type t_hist is array (0 to 63) of signed(23 downto 0);

        variable hist : t_hist;                  -- outputs of the current test

        -- Sends one sample, runs the model, waits for the output and checks
        -- it bit for bit. Stores the output in hist(k).

        procedure send (
            value      : integer;
            k          : natural;
            label_text : string
        ) is

            variable echo    : signed(23 downto 0);
            variable fb_echo : signed(23 downto 0);
            variable wr      : signed(23 downto 0);
            variable expect  : signed(23 downto 0);
            variable got_it  : boolean := false;
            variable waited  : natural := 0;

        begin

            -- Model.
            echo     := buf((ptr - to_integer(delay_samples)) mod c_size);
            fb_echo  := model_gain(echo, clamp(feedback, c_one - 1));
            wr       := model_add(to_signed(value, 24), fb_echo);
            expect   := model_add(model_gain(to_signed(value, 24), to_signed(c_one, 18) - clamp(mix, c_one)),
                                  model_gain(echo, clamp(mix, c_one)));
            buf(ptr) := wr;
            ptr      := (ptr + 1) mod c_size;

            -- DUT.
            sample_in       <= to_signed(value, 24);
            sample_in_valid <= '1';
            wait until rising_edge(clk);
            sample_in_valid <= '0';
            sample_in       <= (others => '0');

            for i in 1 to c_clocks_per - 1 loop

                wait until rising_edge(clk);

                if (sample_out_valid = '1') then
                    assert not got_it
                        report label_text & ": two outputs for one input"
                        severity failure;
                    got_it := true;
                    assert waited = 1
                        report label_text & ": output " & integer'image(waited + 1) & " clocks after the input, expected 2"
                        severity failure;
                    assert sample_out = expect
                        report label_text & " sample " & integer'image(k) & ": got " & integer'image(to_integer(sample_out))
                               & ", model " & integer'image(to_integer(expect))
                        severity failure;
                    last   := sample_out;
                end if;

                waited := waited + 1;

            end loop;

            assert got_it
                report label_text & ": no output for sample " & integer'image(k)
                severity failure;
            hist(k)  := last;
            n_sent   := n_sent + 1;
            n_checks := n_checks + 1;

        end procedure send;

        -- Compares one output with a value worked out by hand (+-1 LSB for
        -- the rounding of each multiply).

        procedure expect_near (
            k          : natural;
            value      : integer;
            label_text : string
        ) is
        begin

            assert abs (to_integer(hist(k)) - value) <= 2
                report label_text & ": sample " & integer'image(k) & " is " & integer'image(to_integer(hist(k)))
                       & ", expected about " & integer'image(value)
                severity failure;
            n_checks := n_checks + 1;

        end procedure expect_near;

        -- Clears the model and the DUT's buffer by sending a buffer's worth of
        -- silence with feedback 0 (the echo of silence is silence).

        procedure flush (
            label_text : string
        ) is
        begin

            feedback <= to_signed(0, 18);
            wait until rising_edge(clk);

            for k in 0 to c_size - 1 loop

                send(0, 0, label_text & " flush");

            end loop;

        end procedure flush;

    begin

        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';

        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        -- 1. A click at D = 5, feedback 0, mix 0.5.
        delay_samples <= to_unsigned(5, c_addr_bits);
        feedback      <= to_signed(0, 18);
        mix           <= to_signed(c_one / 2, 18);
        wait until rising_edge(clk);
        send(c_half, 0, "1 click");

        for k in 1 to 20 loop

            send(0, k, "1 click");

        end loop;

        expect_near(0, c_half / 2, "1 click now (dry x 0.5)");
        expect_near(5, c_half / 2, "1 echo at D = 5 (echo x 0.5)");
        expect_near(4, 0, "1 nothing at D - 1");
        expect_near(6, 0, "1 nothing at D + 1");
        expect_near(10, 0, "1 feedback 0: no second echo");
        report "1. click at D = 5: echo exactly 5 samples later, no repeat";

        -- 1b. D = 15 (the longest), across the pointer wrap.
        flush("1b");
        delay_samples <= to_unsigned(15, c_addr_bits);
        wait until rising_edge(clk);
        send(c_half, 0, "1b click");

        for k in 1 to 20 loop

            send(0, k, "1b click");

        end loop;

        expect_near(15, c_half / 2, "1b echo at D = 15");
        expect_near(14, 0, "1b nothing at 14");
        expect_near(16, 0, "1b nothing at 16");
        report "1b. D = 15: echo 15 samples later, across the wrap";

        -- 2. Feedback 0.5, mix 1.0 (echo only), D = 4.
        flush("2");
        delay_samples <= to_unsigned(4, c_addr_bits);
        feedback      <= to_signed(c_one / 2, 18);
        mix           <= to_signed(c_one, 18);
        wait until rising_edge(clk);
        send(c_half, 0, "2 click");

        for k in 1 to 16 loop

            send(0, k, "2 click");

        end loop;

        expect_near(0, 0, "2 mix 1.0: no dry");
        expect_near(4, c_half, "2 first echo, full size");
        expect_near(8, c_half / 2, "2 second echo, x 0.5");
        expect_near(12, c_half / 4, "2 third echo, x 0.25");
        expect_near(16, c_half / 8, "2 fourth echo, x 0.125");
        report "2. feedback 0.5: echoes 1, 1/2, 1/4, 1/8, every 4 samples";

        -- 3. Feedback clamp: 1.0 and 3.0 behave as 0x7FFF; -0.5 as 0.
        for t in 0 to 1 loop

            flush("3");

            if (t = 0) then
                feedback <= to_signed(c_one, 18);                                                                   -- 1.0
            else
                feedback <= to_signed(3 * c_one, 18);                                                               -- 3.0
            end if;

            wait until rising_edge(clk);
            send(c_half, 0, "3 click");

            for k in 1 to 16 loop

                send(0, k, "3 click");

            end loop;

            assert hist(8) < hist(4) and hist(12) < hist(8) and hist(16) < hist(12) and hist(16) > c_half - 4 * 128
                report "3 feedback clamp: repeats " & integer'image(to_integer(hist(4))) & ", "
                       & integer'image(to_integer(hist(8))) & ", " & integer'image(to_integer(hist(12))) & ", "
                       & integer'image(to_integer(hist(16))) & " should each shrink by about 128 (x 32767 / 32768)"
                severity failure;
            n_checks := n_checks + 1;

        end loop;

        flush("3 neg");
        feedback <= to_signed(-c_one / 2, 18);                                                                      -- -0.5
        wait until rising_edge(clk);
        send(c_half, 0, "3 neg click");

        for k in 1 to 12 loop

            send(0, k, "3 neg click");

        end loop;

        expect_near(4, c_half, "3 feedback -0.5: first echo");
        expect_near(8, 0, "3 feedback -0.5 acts as 0: no second echo");
        report "3. feedback clamp: 1.0 and 3.0 -> just below 1.0 (fading), -0.5 -> 0";

        -- 4. Mix ends and clamp (feedback 0, D = 3).
        flush("4");
        delay_samples <= to_unsigned(3, c_addr_bits);

        for t in 0 to 3 loop

            case t is

                when 0 =>

                    mix <= to_signed(0, 18);                                                                        -- dry only

                when 1 =>

                    mix <= to_signed(c_one, 18);                                                                    -- echo only

                when 2 =>

                    mix <= to_signed(c_one + c_one / 2, 18);                                                        -- 1.5 -> 1.0

                when others =>

                    mix <= to_signed(-c_one / 2, 18);                                                               -- -0.5 -> 0

            end case;

            wait until rising_edge(clk);
            send(c_half, 0, "4 click");
            send(-c_half / 2, 1, "4 click");

            for k in 2 to 6 loop

                send(0, k, "4 click");

            end loop;

            if (t = 0 or t = 3) then
                expect_near(0, c_half, "4 dry only: out = in");
                expect_near(1, -c_half / 2, "4 dry only: out = in (negative)");
                expect_near(3, 0, "4 dry only: no echo");
                assert hist(0) = to_signed(c_half, 24)
                    report "4 mix 0 should pass the input exactly"
                    severity failure;
            else
                expect_near(0, 0, "4 echo only: no dry");
                expect_near(3, c_half, "4 echo only: echo");
                expect_near(4, -c_half / 2, "4 echo only: second echo");
            end if;

        end loop;

        report "4. mix 0 = dry only (exact), 1.0 = echo only, 1.5 -> 1.0, -0.5 -> 0";

        -- 5. Saturation: a constant 0.9 with feedback 1.0 (clamped) piles up
        -- past full scale; it must stop at full scale, not wrap negative.
        flush("5");
        delay_samples <= to_unsigned(2, c_addr_bits);
        feedback      <= to_signed(c_one, 18);
        mix           <= to_signed(c_one, 18);
        wait until rising_edge(clk);

        for k in 0 to 40 loop

            send(c_max * 9 / 10, k, "5 loud");
            assert hist(k) >= 0
                report "5 saturation: output went negative (" & integer'image(to_integer(hist(k)))
                       & "): the write sum wrapped"
                severity failure;

        end loop;

        expect_near(40, c_max, "5 echo saturated at full scale");
        report "5. loud input + feedback ~1.0: saturates at full scale, never wraps";

        report "delay_stage TB: ALL TESTS PASSED (" & integer'image(n_checks) & " checks, "
               & integer'image(n_sent) & " samples)";
        sim_done <= true;
        finish;

    end process stimulus;

end architecture sim;
