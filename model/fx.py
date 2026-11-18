r"""Controls the guitar-fx pedal from the PC over the Arty's USB-UART.

Protocol (docs/uart.md section 5): every command is 3 bytes,
    write: [ register ]        [ value high ] [ value low ]  -> reply ACK
    read:  [ 0x80 | register ] [ 0x00 ]       [ 0x00 ]       -> reply ACK, high, low
    NAK  = unknown register, or a write to a read-only one: don't resend
    CAN  = the command arrived broken: resend
    no reply within the timeout: resend (the command or its reply was lost)

Usage (repo root):
    .venv\Scripts\python model\fx.py write out_gain 0.5
    .venv\Scripts\python model\fx.py read out_gain
    .venv\Scripts\python model\fx.py status
    add --port COM5 for the Arty's COM port, or --fake to test without a board

Steps 1..3 (conversions, send_command, write_reg / read_reg) user-written;
step 4 (command line) and fake_fpga.py by Claude. No arguments: self-test.
"""

import argparse
import sys
from typing import Protocol

# --- Protocol constants ------------------------------------------------------

ACK = 0x06  # done
NAK = 0x15  # unknown register / read-only: don't resend
CAN = 0x18  # command broken: resend
READ_FLAG = 0x80  # byte 1 bit 7: this command is a read

BAUD = 115200
REPLY_TIMEOUT_S = 0.1  # wait this long for a reply before resending
TRIES = 3  # attempts per command

# --- Register map (docs/uart.md, ctrl_regs) ---------------------------------
# name: (register number, format). Formats: "bits", "q3_13", "q0_16", "raw".

REGISTERS = {
    "control": (0x00, "bits"),
    "out_gain": (0x01, "q3_13"),
    "drive_gain": (0x02, "q3_13"),
    "threshold": (0x03, "q0_16"),
    "live": (0x10, "bits"),  # read only
    "version": (0x7F, "raw"),  # read only
}


class Port(Protocol):
    """Anything that can send and receive bytes: a pyserial Serial or the fake FPGA."""

    def write(self, data: bytes) -> int | None:
        """Send bytes."""
        ...

    def read(self, size: int) -> bytes:
        """Receive up to size bytes; fewer (maybe none) if the timeout runs out."""
        ...


# --- Step 1: conversions -----------------------------------------------------


def gain_to_q3_13(gain: float) -> int:
    """Convert a gain to the 16-bit Q3.13 value for registers 0x01 / 0x02.

    Args:
        gain: the gain, -4.0 <= gain < 4.0 (1.0 = unchanged).

    Returns:
        The 16-bit value to send, 0 .. 0xFFFF (negative gains in two's
        complement).

    Raises:
        ValueError: gain is outside the Q3.13 range. This includes gains just
            under 4.0 (above 4 - 2**-14) that round up to 4.0, which Q3.13
            cannot hold.
    """
    k = round(gain * 2**13)
    if k < -4 * 2**13 or k >= 4 * 2**13:
        raise ValueError(f"gain {gain} is outside -4.0 .. just under 4.0")
    return k & 0xFFFF


def q3_13_to_gain(value: int) -> float:
    """Convert a 16-bit Q3.13 value read back from the FPGA to a gain.

    Args:
        value: the 16-bit value, 0 .. 0xFFFF (0x8000 and up are negative).

    Returns:
        The gain, -4.0 .. just under 4.0.
    """
    if value & 0x8000:  # negative
        value -= 0x10000
    return value / (2**13)


def threshold_to_q0_16(threshold: float) -> int:
    """Convert a clip threshold to the 16-bit Q0.16 value for register 0x03.

    Args:
        threshold: fraction of full scale, 0.0 <= threshold < 1.0.

    Returns:
        The 16-bit value to send, 0 .. 0xFFFF.

    Raises:
        ValueError: threshold is outside the Q0.16 range.
    """
    thres = round(threshold * 2**16)
    if thres < 0 or thres >= 2**16:
        raise ValueError(f"threshold {threshold} is outside 0.0 to just under 1.0")
    return thres  # unsigned and range-checked: already 0 .. 0xFFFF


def q0_16_to_threshold(value: int) -> float:
    """Convert a 16-bit Q0.16 value read back from the FPGA to a threshold.

    Args:
        value: the 16-bit value, 0 .. 0xFFFF.

    Returns:
        The threshold, 0.0 .. just under 1.0.
    """
    return value / (2**16)


# --- Step 2: one command, with retries ---------------------------------------


def send_command(port: Port, byte1: int, value: int) -> bytes:
    r"""Send one 3-byte command and return the reply, resending if needed.

    Sends byte1, value high byte, value low byte. Reads one reply byte:
    ACK -> done (for a read, read 2 more bytes: the value); NAK -> give up;
    CAN or nothing within the timeout -> send again, up to TRIES times.

    Args:
        port: where to send (a pyserial Serial, or the fake FPGA).
        byte1: register number, with READ_FLAG added for a read.
        value: 16-bit value to write (0 for a read).

    Returns:
        The reply: b"\x06" for a write, b"\x06" + 2 value bytes for a read.

    Raises:
        RuntimeError: NAK, or no good reply after TRIES attempts.
    """
    packet = bytes([byte1, (value >> 8) & 0xFF, value & 0xFF])  # value high byte, value low byte
    for _attempt in range(TRIES):
        port.write(packet)
        reply = port.read(1)  # one byte, or b"" if nothing came in time
        if not reply:  # b"": nothing within the timeout
            continue  # go round again: send it again
        code = reply[0]  # the byte as a number 0..255
        if code == NAK:
            # Unknown register, or a write to a read-only one: resending won't help.
            raise RuntimeError(f"0x{byte1:02X}: NAK, unknown or read-only register")
        if code == CAN:
            continue  # the FPGA says "broken, resend"
        if code == ACK:
            if byte1 & READ_FLAG:  # a read: the value follows
                data = port.read(2)
                if len(data) == 2:
                    return reply + data  # ACK + high + low
                continue  # value cut short: try again
            return reply  # a write: ACK is everything
        # anything else is a byte we don't understand: try again.
    raise RuntimeError(f"no reply after {TRIES} tries (register 0x{byte1:02X})")


# --- Step 3: write and read a register ---------------------------------------


def write_reg(port: Port, reg: int, value: int) -> None:
    """Write a 16-bit value to a register.

    Args:
        port: where to send.
        reg: register number, 0x00 .. 0x7F.
        value: 16-bit value, 0 .. 0xFFFF.
    """
    send_command(port, reg, value)


def read_reg(port: Port, reg: int) -> int:
    """Read a register's 16-bit value.

    Args:
        port: where to send.
        reg: register number, 0x00 .. 0x7F.

    Returns:
        The value, 0 .. 0xFFFF.
    """
    reply = send_command(port, reg | READ_FLAG, 0)  # ACK, value high, value low
    return (reply[1] << 8) | reply[2]  # rebuild the 16-bit value (ACK not part of it)


# --- Step 4: the command line (written by Claude: plumbing, not DSP) ---------


def to_raw(fmt: str, text: str) -> int:
    """Convert a value typed on the command line to the register's 16 bits.

    Args:
        fmt: the register's format from REGISTERS ("q3_13", "q0_16", "bits", "raw").
        text: the value as typed, e.g. "0.5" for a gain, "0x85" for control.

    Returns:
        The 16-bit value to write.

    Raises:
        ValueError: the value does not fit the format.
    """
    if fmt == "q3_13":
        return gain_to_q3_13(float(text))
    if fmt == "q0_16":
        return threshold_to_q0_16(float(text))
    value = int(text, 0)  # base from the prefix: 0x.. hex, 0b.. binary, else decimal
    if not 0 <= value <= 0xFFFF:
        raise ValueError(f"{text} is not a 16-bit value")
    return value


def from_raw(fmt: str, value: int) -> str:
    """Convert a register's 16 bits to text to print.

    Args:
        fmt: the register's format from REGISTERS.
        value: the 16-bit value read back.

    Returns:
        The value as text: a gain or threshold as a decimal, bits in binary.
    """
    if fmt == "q3_13":
        return f"{q3_13_to_gain(value):.5f}"
    if fmt == "q0_16":
        return f"{q0_16_to_threshold(value):.5f}"
    if fmt == "bits":
        return f"0b{value:08b}"  # 8 binary digits: easy to see which bits are on
    return str(value)


def show_status(port: Port) -> None:
    """Print what the pedal is doing: version, live state and the settings.

    Reads 0x7F (version) and 0x10 (live state: bits 0..2 effects actually
    on, bits 4..6 switches SW0..SW2, bit 7 PC control), then the settings.

    Args:
        port: where to send.
    """
    version = read_reg(port, REGISTERS["version"][0])
    live = read_reg(port, REGISTERS["live"][0])

    def on(bit: int) -> str:
        """Return "on" or "off" for one bit of the live state."""
        return "on" if live & (1 << bit) else "off"

    print(f"guitar-fx version {version}")
    print(f"control:    {'PC' if live & 0x80 else 'switches'}")
    kind = "soft" if live & 0x02 else "hard"
    print(f"distortion: {on(0)} ({kind} clip)")
    print(f"tremolo:    {on(2)}")
    sw = [(live >> b) & 1 for b in (4, 5, 6)]
    print(f"switches:   SW0 {sw[0]}  SW1 {sw[1]}  SW2 {sw[2]}")
    for name in ("out_gain", "drive_gain", "threshold"):
        reg, fmt = REGISTERS[name]
        print(f"{name + ':':<11} {from_raw(fmt, read_reg(port, reg))}")


def main() -> None:
    """Parse the command line and run write / read / status."""
    parser = argparse.ArgumentParser(description="Control the guitar-fx pedal.")
    parser.add_argument("--port", default="COM5", help="the Arty's COM port")
    parser.add_argument("--fake", action="store_true", help="use the fake FPGA (no board)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write", help="write a register")
    w.add_argument("name", choices=REGISTERS)
    w.add_argument("value", help="e.g. 0.5 for a gain or threshold, 0x85 for control")
    r = sub.add_parser("read", help="read a register")
    r.add_argument("name", choices=REGISTERS)
    sub.add_parser("status", help="show what the pedal is doing")
    args = parser.parse_args()

    if args.fake:
        from fake_fpga import FakeFpga  # a new fake each run: writes are not kept

        port: Port = FakeFpga()
    else:
        import serial

        port = serial.Serial(args.port, BAUD, timeout=REPLY_TIMEOUT_S)

    try:
        if args.cmd == "write":
            reg, fmt = REGISTERS[args.name]
            write_reg(port, reg, to_raw(fmt, args.value))
            print("ok")
        elif args.cmd == "read":
            reg, fmt = REGISTERS[args.name]
            print(f"{args.name} = {from_raw(fmt, read_reg(port, reg))}")
        else:
            show_status(port)
    except (RuntimeError, ValueError) as err:
        raise SystemExit(f"error: {err}") from err


def self_test() -> None:
    """Run the step 1..3 checks against the fake FPGA (no board needed)."""
    from fake_fpga import FakeFpga

    # Step 1: conversions.
    assert gain_to_q3_13(2.0) == 0x4000
    assert gain_to_q3_13(1 / 32) == 256
    assert gain_to_q3_13(-0.5) == 0xF000  # -4096 in 16-bit two's complement
    assert q3_13_to_gain(0xF000) == -0.5
    assert threshold_to_q0_16(0.125) == 0x2000
    print("conversions ok")

    # Step 2: send_command.
    fake = FakeFpga()
    assert send_command(fake, 0x01, 0x1000) == bytes([ACK])  # write out_gain 0.5
    assert send_command(fake, 0x81, 0) == bytes([ACK, 0x10, 0x00])  # read it back
    fake.lose_next_byte()  # a byte goes missing...
    assert send_command(fake, 0x02, 0x4000) == bytes([ACK])  # ...the retry still works
    fake.lose_next_reply()  # the reply goes missing...
    assert send_command(fake, 0x02, 0x4000) == bytes([ACK])  # ...still works
    try:
        send_command(fake, 0x10, 0x1234)  # write to read-only: NAK
        raise AssertionError("NAK did not raise")
    except RuntimeError:
        pass
    print("send_command ok")

    # Step 3: write_reg / read_reg.
    write_reg(fake, 0x03, 0x1234)
    assert read_reg(fake, 0x03) == 0x1234
    assert read_reg(fake, 0x01) == 0x1000  # out_gain written above
    assert read_reg(fake, 0x7F) == 1  # version
    print("write_reg / read_reg ok")

    # Step 4: helpers.
    assert to_raw("q3_13", "0.5") == 0x1000
    assert to_raw("bits", "0x85") == 0x85
    assert from_raw("q0_16", 0x2000) == "0.12500"
    print("to_raw / from_raw ok")


if __name__ == "__main__":
    # No arguments: run the self-test. With arguments: the command line.
    if len(sys.argv) > 1:
        main()
    else:
        self_test()
