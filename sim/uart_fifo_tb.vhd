-- Self-checking testbench for uart_fifo (show-ahead FIFO, default 16 bytes).
--
-- A model FIFO in the testbench (an array, a head index and a count) runs
-- alongside the DUT, with the DUT's rules worked out from the spec, not
-- from the DUT:
--   a write is accepted if wr_en = '1' and the FIFO was not full before
--   the clock edge; a read if rd_en = '1' and it was not empty. Both can
--   happen on one edge (a write is still refused if the FIFO was full,
--   even when a read frees a slot on that same edge).
--   overflow pulses on the edge after wr_en = '1' while full.
-- After every clock edge it checks empty, full, overflow, and rd_data
-- (the oldest byte, whenever not empty).
--
-- Tests:
--   1. After reset: empty, not full, no overflow.
--   2. One byte in: shows on rd_data at once (show-ahead); one read
--      empties it.
--   3. Fill to 16: full; a 17th byte pulses overflow and is dropped; read
--      all 16 back in order; empty again. A read while empty does nothing.
--   4. Write and read on the same clock (count unchanged), half full.
--   5. 3000 random clocks in three phases (mostly writes, mostly reads,
--      mixed), so the pointers wrap many times and full / empty / overflow
--      happen at random moments.
--   6. Reset mid-stream: empty again, and it works afterwards.
--
-- Run (xsim): xvhdl -2008 rtl/uart_fifo.vhd sim/uart_fifo_tb.vhd ->
-- xelab uart_fifo_tb -> xsim -R. GHDL: ghdl -a --std=08 (same files),
-- ghdl -r --std=08 uart_fifo_tb.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

entity uart_fifo_tb is
end entity uart_fifo_tb;

architecture sim of uart_fifo_tb is

    constant clk_period : time    := 10 ns;
    constant c_bits     : natural := 4;
    constant c_depth    : natural := 2 ** c_bits;

    signal clk      : std_logic                    := '0';
    signal reset    : std_logic                    := '1';
    signal wr_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal wr_en    : std_logic                    := '0';
    signal rd_en    : std_logic                    := '0';
    signal rd_data  : std_logic_vector(7 downto 0);
    signal empty    : std_logic;
    signal full     : std_logic;
    signal overflow : std_logic;

    signal sim_done : boolean := false;

begin

    clk <= not clk after clk_period / 2 when not sim_done;

    dut : entity work.uart_fifo
        generic map (
            g_addr_bits => c_bits
        )
        port map (
            clk      => clk,
            reset    => reset,
            wr_data  => wr_data,
            wr_en    => wr_en,
            rd_en    => rd_en,
            rd_data  => rd_data,
            empty    => empty,
            full     => full,
            overflow => overflow
        );

    test : process is

        type t_model is array (0 to c_depth - 1) of integer;

        variable model    : t_model;
        variable head     : natural   := 0;   -- model slot of the oldest byte
        variable count    : natural   := 0;   -- model bytes held
        variable exp_ovf  : std_logic := '0'; -- model overflow pulse
        variable n_checks : natural   := 0;
        variable n_ovf    : natural   := 0;
        variable n_full   : natural   := 0;
        variable n_both   : natural   := 0;
        variable n_bytes  : natural   := 0;
        variable next_val : natural   := 0;   -- bytes written count up 0, 1, 2 ...
        variable seed1    : positive  := 7;
        variable seed2    : positive  := 2026;
        variable r        : real;

        -- Checks the DUT against the model.

        procedure check (
            constant name : in string
        ) is
        begin

            if (count = 0) then
                assert empty = '1'
                    report name & ": empty should be '1' (model holds 0)"
                    severity failure;
            else
                assert empty = '0'
                    report name & ": empty should be '0' (model holds "
                           & integer'image(count) & ")"
                    severity failure;
                assert to_integer(unsigned(rd_data)) = model(head)
                    report name & ": rd_data " & integer'image(to_integer(unsigned(rd_data)))
                           & ", expected the oldest byte " & integer'image(model(head))
                    severity failure;
            end if;

            assert (full = '1') = (count = c_depth)
                report name & ": full is " & std_logic'image(full) & " with "
                       & integer'image(count) & " bytes held"
                severity failure;
            assert overflow = exp_ovf
                report name & ": overflow is " & std_logic'image(overflow) & ", expected "
                       & std_logic'image(exp_ovf)
                severity failure;
            n_checks := n_checks + 1;

        end procedure check;

        -- One clock: drive wr_en / rd_en (and the next byte), step the
        -- model with the same rules, then check.

        procedure step (
            constant name : in string;
            constant wr   : in std_logic;
            constant rd   : in std_logic
        ) is

            variable do_wr : boolean;
            variable do_rd : boolean;

        begin

            wr_en   <= wr;
            rd_en   <= rd;
            wr_data <= std_logic_vector(to_unsigned(next_val mod 256, 8));
            wait until rising_edge(clk);
            wr_en   <= '0';
            rd_en   <= '0';

            -- The model, decided on the counts from before the edge.
            do_wr := wr = '1' and count < c_depth;
            do_rd := rd = '1' and count > 0;

            if (wr = '1' and count = c_depth) then
                exp_ovf := '1';
                n_ovf   := n_ovf + 1;
            else
                exp_ovf := '0';
            end if;

            if (do_wr and do_rd) then
                n_both := n_both + 1;
            end if;

            if (do_rd) then
                head  := (head + 1) mod c_depth;
                count := count - 1;
            end if;

            if (do_wr) then
                model((head + count) mod c_depth) := next_val mod 256;
                count                             := count + 1;
                next_val                          := next_val + 1;
                n_bytes                           := n_bytes + 1;
            end if;

            if (count = c_depth) then
                n_full := n_full + 1;
            end if;

            wait for 1 ns;
            check(name);

        end procedure step;

    begin

        -- 1. Reset.
        for i in 1 to 3 loop

            wait until rising_edge(clk);

        end loop;

        reset <= '0';
        wait for 1 ns;
        check("after reset");

        -- 2. One byte in, one out.
        step("one byte in", '1', '0');
        step("one byte out", '0', '1');
        report "1-2 reset, one byte: ok"
            severity note;

        -- 3. Fill, overflow, drain, read while empty.
        for i in 1 to c_depth loop

            step("fill", '1', '0');

        end loop;

        assert full = '1'
            report "not full after " & integer'image(c_depth) & " writes"
            severity failure;
        step("write while full (dropped)", '1', '0');
        assert overflow = '1'
            report "no overflow pulse for a write while full"
            severity failure;
        step("after the overflow", '0', '0');

        for i in 1 to c_depth loop

            step("drain", '0', '1');

        end loop;

        step("read while empty", '0', '1');
        assert empty = '1'
            report "not empty after draining"
            severity failure;
        report "3 fill / overflow / drain / read while empty: ok"
            severity note;

        -- 4. Same-clock write and read at half full.
        for i in 1 to c_depth / 2 loop

            step("half fill", '1', '0');

        end loop;

        for i in 1 to 20 loop

            step("write + read together", '1', '1');

        end loop;

        report "4 write and read on one clock: ok"
            severity note;

        -- 5. Random traffic.
        for i in 0 to 2999 loop

            uniform(seed1, seed2, r);

            if (i < 1000) then                                                                    -- mostly writes: fills, overflows
                if (r < 0.70) then
                    step("random (fill phase)", '1', '0');
                elsif (r < 0.85) then
                    step("random (fill phase)", '1', '1');
                else
                    step("random (fill phase)", '0', '1');
                end if;
            elsif (i < 2000) then                                                                 -- mostly reads: drains, empty reads
                if (r < 0.15) then
                    step("random (drain phase)", '1', '0');
                elsif (r < 0.30) then
                    step("random (drain phase)", '1', '1');
                else
                    step("random (drain phase)", '0', '1');
                end if;
            else                                                                                  -- mixed
                if (r < 0.30) then
                    step("random (mixed)", '1', '0');
                elsif (r < 0.55) then
                    step("random (mixed)", '1', '1');
                elsif (r < 0.85) then
                    step("random (mixed)", '0', '1');
                else
                    step("random (mixed)", '0', '0');
                end if;
            end if;

        end loop;

        assert n_ovf > 5 and n_full > 5 and n_both > 100
            report "random coverage too low: " & integer'image(n_ovf) & " overflows, "
                   & integer'image(n_full) & " clocks full, " & integer'image(n_both)
                   & " write+read clocks"
            severity failure;
        report "5 random: " & integer'image(n_bytes) & " bytes through, "
               & integer'image(n_ovf) & " overflows, " & integer'image(n_full) & " clocks full, "
               & integer'image(n_both) & " clocks with write and read together"
            severity note;

        -- 6. Reset with bytes inside.
        for i in 1 to 5 loop

            step("before reset", '1', '0');

        end loop;

        reset   <= '1';
        wait until rising_edge(clk);
        reset   <= '0';
        head    := 0;
        count   := 0;
        exp_ovf := '0';
        wait for 1 ns;
        check("after reset mid-stream");

        for i in 1 to 3 loop

            step("after reset: write", '1', '0');

        end loop;

        for i in 1 to 3 loop

            step("after reset: read", '0', '1');

        end loop;

        report "6 reset mid-stream: ok"
            severity note;

        report integer'image(n_checks) & " clocks checked. ALL TESTS PASSED"
            severity note;
        sim_done <= true;
        wait;

    end process test;

end architecture sim;
