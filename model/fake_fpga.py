"""A fake guitar-fx FPGA for testing model/fx.py without a board.

Behaves like cmd_decoder + ctrl_regs (docs/uart.md section 5): the same
registers, defaults and replies. Use it where fx.py would use a pyserial
Serial: it has write(bytes) and read(size).

Differences from the hardware, on purpose:
- No real time. A command left incomplete is treated as timed out the next
  time read() is called: it is discarded and CAN is replied (the FPGA does
  this after 1 ms of silence).
- lose_next_byte(): the next byte written is dropped, as if it never
  arrived, to test fx.py's retry logic. lose_next_reply(): the next reply
  is swallowed, as if lost on the way back.

Not a DSP model: test plumbing, written by Claude.
"""

ACK = 0x06
NAK = 0x15
CAN = 0x18


class FakeFpga:
    """Fake cmd_decoder + ctrl_regs, talking bytes like a serial port."""

    def __init__(self) -> None:
        """Start with the ctrl_regs defaults and the switches all off."""
        self.regs = {0x00: 0, 0x01: 256, 0x02: 16384, 0x03: 8192, 0x04: 16384, 0x05: 1748}
        self.version = 2
        self.switches = 0b0000  # SW3 SW2 SW1 SW0, as on the board
        self._rx: list[int] = []  # bytes of the command being received
        self._tx = bytearray()  # reply bytes waiting to be read
        self._lose_byte = False
        self._lose_reply = False
        self.commands = 0  # complete commands seen (for tests)

    def lose_next_byte(self) -> None:
        """Drop the next byte written (simulates a byte lost on the line)."""
        self._lose_byte = True

    def lose_next_reply(self) -> None:
        """Swallow the next reply (simulates a reply lost on the way back)."""
        self._lose_reply = True

    def _live(self) -> int:
        """Register 0x10: effects on (bits 0..3), SW0..SW2 (4..6), PC control (7), SW3 (8).

        Returns:
            The 16-bit live-state value.
        """
        pc = (self.regs[0x00] >> 7) & 1
        fx = self.regs[0x00] & 0b1111 if pc else self.switches
        sw = self.switches
        return fx | ((sw & 0b111) << 4) | (pc << 7) | (((sw >> 3) & 1) << 8)

    def _reply(self, data: bytes) -> None:
        """Queue reply bytes, unless the next reply is to be lost.

        Args:
            data: the reply bytes.
        """
        if self._lose_reply:
            self._lose_reply = False
            return
        self._tx += data

    def _command(self, byte1: int, value: int) -> None:
        """Act on one complete command, as cmd_decoder + ctrl_regs do.

        Args:
            byte1: register number, bit 7 = read.
            value: 16-bit value (ignored for a read).
        """
        self.commands += 1
        reg = byte1 & 0x7F
        read = bool(byte1 & 0x80)
        readable = {**self.regs, 0x10: self._live(), 0x7F: self.version}
        if reg not in readable:
            self._reply(bytes([NAK]))
        elif read:
            v = readable[reg]
            self._reply(bytes([ACK, v >> 8, v & 0xFF]))
        elif reg in self.regs:
            self.regs[reg] = value
            self._reply(bytes([ACK]))
        else:
            self._reply(bytes([NAK]))  # write to a read-only register

    def write(self, data: bytes) -> int:
        """Receive bytes from the PC, as the FPGA's uart_rx would.

        Args:
            data: the bytes sent.

        Returns:
            The number of bytes sent (as pyserial's write does).
        """
        for b in data:
            if self._lose_byte:
                self._lose_byte = False
                continue
            self._rx.append(b)
            if len(self._rx) == 3:
                self._command(self._rx[0], (self._rx[1] << 8) | self._rx[2])
                self._rx = []
        return len(data)

    def read(self, size: int) -> bytes:
        """Return up to size reply bytes, as pyserial's read with a timeout does.

        An incomplete command is timed out first: discarded, CAN replied.

        Args:
            size: the most bytes to return.

        Returns:
            Up to size bytes; fewer (maybe none) if no more replies are waiting.
        """
        if self._rx:
            self._rx = []
            self._reply(bytes([CAN]))
        out = bytes(self._tx[:size])
        del self._tx[:size]
        return out
