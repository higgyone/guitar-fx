-- cmd_decoder: turns commands from the PC (bytes from the uart block) into
-- register writes, and answers each command with one reply byte.
--
-- A command is 3 bytes, back-to-back:
--   [ register number ] [ value high byte ] [ value low byte ]
-- Reply (one byte per command, sent through the uart's transmit FIFO):
--   0x06 ACK  written
--   0x15 NAK  the register does not exist (reg_addr_valid '0'): not written;
--             resending will not help
--   0x18 CAN  the command arrived broken (a byte missing or bad): resend
--
-- States (which byte is expected next):
--   st_reg     byte 1: keep it as the register number (s_reg_addr)
--   st_hi      byte 2: keep it as the high byte (s_data_hi)
--   st_lo      byte 3: value = high & low; reg_addr_valid '1' -> pulse
--              reg_write and reply ACK, else reply NAK; back to st_reg
--   st_discard after a broken command: ignore bytes until the line has been
--              quiet for the timeout, then reply CAN once and go to st_reg.
--              Without it, the rest of a broken command would start a new
--              command and cause a second reply, which the PC would take as
--              the answer to its resend. So: exactly one reply per command.
-- A bad byte (rx_frame_error) in any state, or the timeout in st_hi /
-- st_lo, goes to st_discard.
--
-- Timeout: s_timer counts clocks since the last byte (good or bad) and stops
-- at g_timeout_clks - 1, so "timed out" stays true until the next byte.
-- g_timeout_clks = 98 305 = 1 ms: far longer than the gap inside a command
-- (bytes are back-to-back), far shorter than the PC's wait for a reply.
--
-- reg_addr comes straight from s_reg_addr (byte 1), so ctrl_regs answers
-- reg_addr_valid long before byte 3 arrives, when it is checked.
--
-- Testbench: sim/cmd_decoder_tb.vhd. Design notes: docs/uart.md, section 5.

library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity cmd_decoder is
    generic (
        g_timeout_clks : natural := 98305 -- longest gap between the bytes of one command, in clocks (98305 = 1 ms)
    );
    port (
        clk            : in    std_logic;                     -- s_clk, 98.305 MHz
        reset          : in    std_logic;                     -- synchronous, active high
        rx_data        : in    std_logic_vector(7 downto 0);  -- received byte (meaningful on rx_valid)
        rx_valid       : in    std_logic;                     -- one-clock pulse: rx_data holds a good byte
        rx_frame_error : in    std_logic;                     -- one-clock pulse: stop bit was '0', byte discarded
        reg_addr_valid : in    std_logic;                     -- level from ctrl_regs: '1' while reg_addr exists
        tx_data        : out   std_logic_vector(7 downto 0);  -- reply byte to the PC: ACK, NAK or CAN
        tx_valid       : out   std_logic;                     -- one-clock pulse: queue tx_data in the uart FIFO
        reg_addr       : out   std_logic_vector(7 downto 0);  -- register number: byte 1 of the command
        reg_data       : out   std_logic_vector(15 downto 0); -- value: byte 2 (high) & byte 3 (low)
        reg_write      : out   std_logic                      -- one-clock pulse: write reg_data to reg_addr
    );
end entity cmd_decoder;

architecture rtl of cmd_decoder is

    -- States: which byte of a command is expected next.
    --   st_reg     byte 1, the register number
    --   st_hi      byte 2, value high byte
    --   st_lo      byte 3, value low byte: write and reply
    --   st_discard a broken command: wait for 1 ms of silence, then reply CAN

    type t_state is (st_reg, st_hi, st_lo, st_discard);

    signal s_state : t_state := st_reg;

    -- Reply bytes to the PC.
    constant c_ack : std_logic_vector(7 downto 0) := x"06"; -- done
    constant c_nak : std_logic_vector(7 downto 0) := x"15"; -- unknown register: don't resend
    constant c_can : std_logic_vector(7 downto 0) := x"18"; -- command broken: resend

    -- What the decoder remembers:
    --   s_reg_addr              byte 1, kept until the write (drives reg_addr)
    --   s_data_hi               byte 2, kept until byte 3 arrives
    --   s_timer                 clocks since the last byte; stops at the top = timed out
    --   s_tx_data, s_tx_valid   the reply (s_tx_valid a one-clock pulse)
    --   s_reg_data, s_reg_write the write (s_reg_write a one-clock pulse)
    signal s_reg_addr  : std_logic_vector(7 downto 0)          := (others => '0');
    signal s_data_hi   : std_logic_vector(7 downto 0)          := (others => '0');
    signal s_timer     : natural range 0 to g_timeout_clks - 1 := 0;
    signal s_tx_data   : std_logic_vector(7 downto 0)          := (others => '0');
    signal s_tx_valid  : std_logic                             := '0';
    signal s_reg_data  : std_logic_vector(15 downto 0)         := (others => '0');
    signal s_reg_write : std_logic                             := '0';

begin

    cmd_decode_proc : process (clk) is
    begin

        if rising_edge(clk) then
            s_tx_valid  <= '0';                                            -- default: no reply
            s_reg_write <= '0';                                            -- default: no write

            if (reset = '1') then
                s_timer <= 0;
                s_state <= st_reg;
            else
                if (rx_valid = '1' or rx_frame_error = '1') then
                    s_timer <= 0;                                          -- a byte: restart
                elsif (s_timer < g_timeout_clks - 1) then
                    s_timer <= s_timer + 1;                                -- quiet: count up
                end if;

                case s_state is

                    when st_reg =>

                        if (rx_valid = '1') then
                            s_reg_addr <= rx_data;                         -- byte 1: the register number
                            s_state    <= st_hi;
                        elsif (rx_frame_error = '1') then
                            s_state <= st_discard;                         -- a bad first byte: discard the rest
                        end if;

                    when st_hi =>

                        if (rx_valid = '1') then
                            s_data_hi <= rx_data;                          -- byte 2: the high byte of the data
                            s_state   <= st_lo;
                        elsif (rx_frame_error = '1') then
                            s_state <= st_discard;                         -- a bad second byte: discard the rest
                        elsif (s_timer = g_timeout_clks - 1) then
                            s_state <= st_discard;                         -- nothing for 1 ms: the command is broken
                        end if;

                    when st_lo =>

                        if (rx_valid = '1') then
                            s_reg_data <= s_data_hi & rx_data;
                            if (reg_addr_valid = '1') then
                                s_reg_write <= '1';                        -- known register: write it
                                s_tx_data   <= c_ack;                      -- reply ACK
                            else
                                s_tx_data <= c_nak;                        -- unknown register: no write, NAK
                            end if;
                            s_tx_valid <= '1';                             -- send the reply (ACK or NAK)
                            s_state    <= st_reg;
                        elsif (rx_frame_error = '1') then
                            s_state <= st_discard;                         -- a bad third byte: discard the rest
                        elsif (s_timer = g_timeout_clks - 1) then
                            s_state <= st_discard;                         -- nothing for 1 ms: the command is broken
                        end if;

                    when st_discard =>

                        if (s_timer = g_timeout_clks - 1) then             -- 1 ms of silence
                            s_tx_data  <= c_can;                           -- reply: cancelled, please resend
                            s_tx_valid <= '1';
                            s_state    <= st_reg;
                        end if;

                end case;

            end if;
        end if;

    end process cmd_decode_proc;

    tx_data   <= s_tx_data;
    tx_valid  <= s_tx_valid;
    reg_addr  <= s_reg_addr;
    reg_data  <= s_reg_data;
    reg_write <= s_reg_write;

end architecture rtl;
