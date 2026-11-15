-- uart_fifo: a small first-in, first-out queue of bytes. It sits between
-- uart_rx and uart_tx, so bytes that arrive while uart_tx is still busy wait
-- here instead of being dropped (back-to-back input from a PC slightly
-- faster than our baud rate, or pasted text; see docs/uart.md, echo).
--
--   g_addr_bits : 2**g_addr_bits slots (default 4 = 16 bytes)
--   wr_data / wr_en : store a byte (wr_en a one-clock pulse, e.g. uart_rx's
--                     data_out_valid)
--   rd_data / rd_en : show-ahead read: rd_data always shows the oldest byte
--                     while not empty; a one-clock rd_en says "taken" and
--                     moves on to the next
--   empty / full    : nothing to read / no room
--   overflow        : one-clock pulse: a byte arrived while full and was
--                     dropped
--
-- A circular buffer: a write pointer and a read pointer go round the slots
-- and wrap from the last back to 0 by themselves (a g_addr_bits-wide
-- unsigned); nothing ever moves in memory. Pointers equal could mean empty
-- or full, so a count (0 .. 2**g_addr_bits, one bit wider than a pointer)
-- says how many bytes are held:
--   write only: +1, read only: -1, both or neither: unchanged.
--
-- Every write and read is guarded:
--   a write only if not full (that slot holds the oldest unsent byte, the
--   next one out, so writing it would destroy data); otherwise overflow;
--   a read only if not empty (the pointer would run past the write pointer
--   and the count would go below 0).
-- The guards are worked out once (s_do_write, s_do_read) and used for the
-- memory, the pointers and the count, so those can never disagree, and the
-- count can never leave its range.
--
-- Show-ahead fits uart_tx, which raises busy on the same edge it accepts a
-- byte: rd_en = not empty and not busy, uart_tx data_in = rd_data,
-- data_in_valid = rd_en, and one byte goes per send with no extra logic.
-- The memory is read without a clock, so Vivado builds it as LUT RAM (it
-- has no reset for the same reason: the count says which slots are real).
-- Reset empties the FIFO.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity uart_fifo is
    generic (
        g_addr_bits : natural := 4 -- 2**g_addr_bits slots: 4 = 16 bytes
    );
    port (
        clk      : in    std_logic;
        reset    : in    std_logic;                    -- synchronous, active high: empties the FIFO
        wr_data  : in    std_logic_vector(7 downto 0); -- byte to store
        wr_en    : in    std_logic;                    -- one-clock pulse: store wr_data (if not full)
        rd_en    : in    std_logic;                    -- one-clock pulse: the oldest byte was taken (if not empty)
        rd_data  : out   std_logic_vector(7 downto 0); -- the oldest byte (valid while empty = '0')
        empty    : out   std_logic;                    -- '1': nothing to read
        full     : out   std_logic;                    -- '1': no room
        overflow : out   std_logic                     -- one-clock pulse: a byte arrived while full, dropped
    );
end entity uart_fifo;

architecture rtl of uart_fifo is

    -- The slots: 2**g_addr_bits bytes.

    type t_mem is array (0 to 2 ** g_addr_bits - 1) of std_logic_vector(7 downto 0);

    signal s_mem      : t_mem;                                                  -- the bytes (no reset: LUT RAM)
    signal s_wr_ptr   : unsigned(g_addr_bits - 1 downto 0)  := (others => '0'); -- next slot to write
    signal s_rd_ptr   : unsigned(g_addr_bits - 1 downto 0)  := (others => '0'); -- slot of the oldest byte
    signal s_count    : natural range 0 to 2 ** g_addr_bits := 0;               -- bytes held
    signal s_overflow : std_logic                           := '0';             -- overflow pulse

    -- The decisions, worked out from the count and the requests:
    signal s_empty    : std_logic; -- count = 0
    signal s_full     : std_logic; -- count = 2**g_addr_bits
    signal s_do_write : std_logic; -- write really happens this clock
    signal s_do_read  : std_logic; -- read really happens this clock

begin

    -- Acts on the decisions: store and move the pointers, update the count,
    -- flag a dropped byte.
    uart_fifo_proc : process (clk) is
    begin

        if rising_edge(clk) then
            s_overflow <= '0';                                    -- default: a one-clock pulse, like uart_rx's valid
            if (reset = '1') then
                s_wr_ptr <= (others => '0');                      -- the memory is left as it is:
                s_rd_ptr <= (others => '0');                      -- count = 0 means none of it is read
                s_count  <= 0;
            else
                -- Separate ifs: a write and a read can both happen on one clock.
                if (s_do_write = '1') then
                    s_mem(to_integer(s_wr_ptr)) <= wr_data;
                    s_wr_ptr                    <= s_wr_ptr + 1;  -- wraps to 0 after the last slot
                end if;
                if (s_do_read = '1') then
                    s_rd_ptr <= s_rd_ptr + 1;                     -- wraps to 0 after the last slot
                end if;
                if (s_do_write = '1' and s_do_read = '0') then
                    s_count <= s_count + 1;                       -- a byte in, none out
                elsif (s_do_write = '0' and s_do_read = '1') then
                    s_count <= s_count - 1;                       -- a byte out, none in
                end if;                                           -- both or neither: count unchanged

                -- The raw wr_en, not s_do_write: s_do_write is '0' exactly
                -- when the byte is being dropped.
                if (wr_en = '1' and s_full = '1') then
                    s_overflow <= '1';
                end if;
            end if;
        end if;

    end process uart_fifo_proc;

    -- Empty and full from the count (a comparison is a boolean, so
    -- when ... else makes it a std_logic).
    s_empty <= '1' when s_count = 0 else
               '0';
    s_full  <= '1' when s_count = 2 ** g_addr_bits else
               '0';

    empty <= s_empty;
    full  <= s_full;

    rd_data  <= s_mem(to_integer(s_rd_ptr)); -- show-ahead: always the oldest byte
    overflow <= s_overflow;

    -- The guards: write only if not full, read only if not empty.
    s_do_write <= wr_en and not(s_full);
    s_do_read  <= rd_en and not(s_empty);

end architecture rtl;
