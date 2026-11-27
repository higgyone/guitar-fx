r"""Controls the guitar-fx pedal from the PC over the Arty's USB-UART.

Protocol (docs/uart.md section 5): every command is 3 bytes,
    write: [ register ]        [ value high ] [ value low ]  -> reply ACK
    read:  [ 0x80 | register ] [ 0x00 ]       [ 0x00 ]       -> reply ACK, high, low
    NAK  = unknown register, or a write to a read-only one: don't resend
    CAN  = the command arrived broken: resend
    no reply within the timeout: resend (the command or its reply was lost)

Usage (repo root):
    .venv\Scripts\python model\fx.py write out_gain 0.5
    .venv\Scripts\python model\fx.py write tremolo_rate 6.5
    .venv\Scripts\python model\fx.py write delay_time 300
    .venv\Scripts\python model\fx.py write control 0x90   (PC control, delay on)
    .venv\Scripts\python model\fx.py read out_gain
    .venv\Scripts\python model\fx.py status
    add --port COM5 for the Arty's COM port, or --fake to test without a board

Steps 1..3 (conversions, send_command, write_reg / read_reg) user-written;
step 4 (command line) and fake_fpga.py by Claude. Stage 2 (tremolo
registers): conversions user-written, the rest by Claude. Stage 3 (delay
registers): the same split. No arguments: self-test.
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
SAMPLE_RATE = 48000  # Hz: the tremolo's phase step and the delay time are worked out for this
DELAY_MAX = 0x7FFF  # samples: the longest delay (15 bits, about 682.6 ms)

# --- Register map (docs/uart.md, ctrl_regs) ---------------------------------
# name: (register number, format).
# Formats: "bits", "q3_13", "q0_16", "q1_15", "rate", "delay", "feedback", "raw".

REGISTERS = {
    "control": (0x00, "bits"),  # bit 0 distortion, 1 soft, 2 tremolo, 3 tone, 4 delay, 7 PC
    "out_gain": (0x01, "q3_13"),
    "drive_gain": (0x02, "q3_13"),
    "threshold": (0x03, "q0_16"),
    "tremolo_depth": (0x04, "q1_15"),  # 0.0 .. 1.0
    "tremolo_rate": (0x05, "rate"),  # Hz; register = phase step / 256
    "delay_time": (0x06, "delay"),  # ms; register = samples, 1 .. 0x7FFF
    "delay_feedback": (0x07, "feedback"),  # 0.0 .. below 1.0 (Q1.15)
    "delay_mix": (0x08, "q1_15"),  # 0.0 dry .. 1.0 echo only: the depth's format
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


# --- Stage 2 conversions: tremolo depth and rate (user to write) -----------


def depth_to_q1_15(depth: float) -> int:
    """Convert a tremolo depth to the 16-bit Q1.15 value for register 0x04.

    Args:
        depth: 0.0 (no tremolo) .. 1.0 (dips to silence).

    Returns:
        The 16-bit value to send, 0 .. 0x8000.

    Raises:
        ValueError: depth is outside 0.0 .. 1.0 (above 1.0 the FPGA's gain
            would go negative).
    """
    q = round(depth * 2**15)  # Q1.15: 1.0 = 2**15 = 0x8000
    # Range check on the scaled value. Q1.15 has an integer bit, so 1.0
    # (0x8000) fits; only values above it are refused.
    if q < 0 or q > 2**15:
        raise ValueError(f"depth {depth} is outside 0.0 to 1.0")
    return q  # 0 .. 0x8000: positive, so already a 16-bit value


def q1_15_to_depth(value: int) -> float:
    """Convert a 16-bit Q1.15 value read back from the FPGA to a depth.

    Args:
        value: the 16-bit value, 0 .. 0xFFFF (unsigned).

    Returns:
        The depth (0.0 .. 1.0 when written by depth_to_q1_15).
    """
    return value / 2**15  # the reverse of the scaling (unsigned: no negative case)


def rate_to_reg(rate_hz: float) -> int:
    """Convert a tremolo rate to the 16-bit value for register 0x05.

    The FPGA's phase step is rate_hz * 2**32 / SAMPLE_RATE; the register
    holds it / 256 (the FPGA adds 8 zeros at the bottom).

    Args:
        rate_hz: the rate in Hz, 0.0 .. about 187 Hz.

    Returns:
        The 16-bit value to send, 0 .. 0xFFFF.

    Raises:
        ValueError: the rate doesn't fit in 16 bits after rounding.
    """
    step = (
        rate_hz * 2**32 / SAMPLE_RATE
    )  # the FPGA's 32-bit phase step (rate * 2**32 / SAMPLE_RATE)
    reg = round(step / 256)  # step / 256, rounded to a whole number
    if reg < 0 or reg >= 2**16:  # outside 0 .. 0xFFFF (16 bits)
        raise ValueError(f"rate {rate_hz} Hz doesn't fit register 0x05 (max about 187 Hz)")
    return reg


def reg_to_rate(value: int) -> float:
    """Convert register 0x05's 16-bit value read back from the FPGA to Hz.

    Args:
        value: the 16-bit value, 0 .. 0xFFFF.

    Returns:
        The rate in Hz.
    """
    return value * 256 * SAMPLE_RATE / 2**32


# --- Stage 3 conversions: delay time and feedback (user to write) ----------
# The mix needs no new functions: it is Q1.15, 0.0 .. 1.0 like the tremolo
# depth, so depth_to_q1_15 / q1_15_to_depth already do it.


def delay_to_reg(delay_ms: float) -> int:
    """Convert a delay time to the 16-bit value for register 0x06.

    The register holds the delay in samples: SAMPLE_RATE samples a second,
    so delay_ms / 1000 seconds is that many samples.

    Args:
        delay_ms: the delay in milliseconds, about 0.02 .. 682.6.

    Returns:
        The number of samples, 1 .. DELAY_MAX (0x7FFF).

    Raises:
        ValueError: fewer than 1 sample after rounding (0 would read the
            oldest sample in the buffer, not a short delay), or more than
            DELAY_MAX (the FPGA would clamp it; refuse it here with a clear
            error instead).
    """
    # TODO: ms -> samples, rounded to a whole number
    # TODO: refuse anything outside 1 .. DELAY_MAX (ValueError with the ms
    #       and the limits in the message)
    # TODO: return it (positive and checked: already a 16-bit value)
    raise NotImplementedError


def reg_to_delay(value: int) -> float:
    """Convert register 0x06's value read back from the FPGA to milliseconds.

    Args:
        value: the 16-bit value, 0 .. 0xFFFF.

    Returns:
        The delay in ms that the FPGA really uses.
    """
    # TODO: the reverse of delay_to_reg. One catch: the register keeps
    #       whatever was written (a raw "write delay_time" can't, but a
    #       raw write to 0x06 could store 0x8000 or more), while the FPGA
    #       clamps what it uses to DELAY_MAX. Report what it uses.
    raise NotImplementedError


def feedback_to_q1_15(feedback: float) -> int:
    """Convert a delay feedback to the 16-bit Q1.15 value for register 0x07.

    Args:
        feedback: how much of each echo repeats, 0.0 (one echo) .. below
            1.0 (each repeat almost as loud as the last).

    Returns:
        The 16-bit value to send, 0 .. 0x7FFF.

    Raises:
        ValueError: feedback is negative, or 1.0 or more after rounding (at
            1.0 the echoes never fade; above it they grow until they clip).
            The FPGA clamps these too; refusing here gives a clear error.
    """
    # TODO: scale to Q1.15 and round (like depth_to_q1_15)
    # TODO: the range check differs from the depth's: 1.0 (0x8000) itself is
    #       refused. Mind values like 0.99999 that round up to 0x8000.
    # TODO: return it
    raise NotImplementedError


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
    if fmt == "q1_15":
        return depth_to_q1_15(float(text))
    if fmt == "rate":
        return rate_to_reg(float(text))
    if fmt == "delay":
        return delay_to_reg(float(text))
    if fmt == "feedback":
        return feedback_to_q1_15(float(text))
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
    if fmt == "q1_15":
        return f"{q1_15_to_depth(value):.5f}"
    if fmt == "rate":
        return f"{reg_to_rate(value):.4f} Hz"
    if fmt == "delay":
        return f"{reg_to_delay(value):.3f} ms"
    if fmt == "feedback":
        return f"{q1_15_to_depth(value):.5f}"  # same scaling as the depth
    if fmt == "bits":
        return f"0b{value:010b}"  # 10 binary digits (bits 0..9): easy to see which are on
    return str(value)


def show_status(port: Port) -> None:
    """Print what the pedal is doing: version, live state and the settings.

    Reads 0x7F (version) and 0x10 (live state: bits 0..3 effects actually
    on, bits 4..6 switches SW0..SW2, bit 7 PC control, bit 8 switch SW3,
    bit 9 delay actually on), then the settings.

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
    print(f"tone:       {on(3)}")
    print(f"delay:      {on(9)} (PC only)")
    sw = [(live >> b) & 1 for b in (4, 5, 6, 8)]
    print(f"switches:   SW0 {sw[0]}  SW1 {sw[1]}  SW2 {sw[2]}  SW3 {sw[3]}")
    for name in (
        "out_gain",
        "drive_gain",
        "threshold",
        "tremolo_depth",
        "tremolo_rate",
        "delay_time",
        "delay_feedback",
        "delay_mix",
    ):
        reg, fmt = REGISTERS[name]
        print(f"{name + ':':<16} {from_raw(fmt, read_reg(port, reg))}")


def main() -> None:
    """Parse the command line and run write / read / status."""
    parser = argparse.ArgumentParser(description="Control the guitar-fx pedal.")
    parser.add_argument("--port", default="COM5", help="the Arty's COM port")
    parser.add_argument("--fake", action="store_true", help="use the fake FPGA (no board)")
    sub = parser.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write", help="write a register")
    w.add_argument("name", choices=REGISTERS)
    w.add_argument(
        "value",
        help="e.g. 0.5 (gain, threshold, depth, feedback, mix), 5 (rate, Hz), "
        "300 (delay, ms), 0x85 (control)",
    )
    r = sub.add_parser("read", help="read a register")
    r.add_argument("name", choices=REGISTERS)
    sub.add_parser("status", help="show what the pedal is doing")
    args = parser.parse_args()

    if args.fake:
        from fake_fpga import FakeFpga  # a new fake each run: writes are not kept

        port: Port = FakeFpga()
    else:
        import serial
        from serial.tools import list_ports

        try:
            port = serial.Serial(args.port, BAUD, timeout=REPLY_TIMEOUT_S)
        except serial.SerialException as err:
            found = [p.device for p in list_ports.comports()]
            raise SystemExit(
                f"error: can't open {args.port}. Ports on this PC: "
                f"{', '.join(found) or 'none (is the Arty plugged in?)'}. "
                f"Pick one with --port, or use --fake."
            ) from err

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
    assert read_reg(fake, 0x7F) == 3  # version
    print("write_reg / read_reg ok")

    # Step 4: helpers.
    assert to_raw("q3_13", "0.5") == 0x1000
    assert to_raw("bits", "0x85") == 0x85
    assert from_raw("q0_16", 0x2000) == "0.12500"
    print("to_raw / from_raw ok")

    # Stage 2: tremolo depth and rate.
    assert depth_to_q1_15(0.5) == 0x4000
    assert depth_to_q1_15(1.0) == 0x8000
    assert depth_to_q1_15(0.0) == 0
    assert q1_15_to_depth(0x8000) == 1.0
    for bad in (-0.1, 1.01):
        try:
            depth_to_q1_15(bad)
            raise AssertionError(f"depth {bad} did not raise")
        except ValueError:
            pass
    assert rate_to_reg(5.0) == 1748  # 1747.6 rounded
    assert abs(reg_to_rate(1748) - 5.0011) < 1e-4
    assert rate_to_reg(150.0) == 0xCCCD  # top_tb's rate
    assert reg_to_rate(0xFFFF) < 188
    try:
        rate_to_reg(200.0)
        raise AssertionError("rate 200 Hz did not raise")
    except ValueError:
        pass
    fake = FakeFpga()
    assert read_reg(fake, 0x04) == 0x4000  # default depth 0.5
    assert read_reg(fake, 0x05) == 1748  # default rate 5 Hz
    write_reg(fake, 0x05, to_raw("rate", "6.5"))
    assert from_raw("rate", read_reg(fake, 0x05)) == "6.5002 Hz"
    fake.switches = 0b1000  # SW3 up
    assert read_reg(fake, 0x10) == 0x108  # tone on (bit 3), SW3 (bit 8)
    write_reg(fake, 0x00, 0x82)  # PC control, soft clip only
    assert read_reg(fake, 0x10) == 0x182  # tone off, SW3 still shown
    print("tremolo depth / rate ok")

    # Stage 3: delay time, feedback and mix.
    assert delay_to_reg(250.0) == 12000  # top's default
    assert delay_to_reg(682.6) == 32765  # 32764.8, rounded
    assert delay_to_reg(682.65) == 0x7FFF  # 32767.2: the longest delay
    assert reg_to_delay(12000) == 250.0
    assert reg_to_delay(0x8000) == reg_to_delay(0x7FFF)  # the FPGA clamps: report that
    for bad in (0.0, -5.0, 683.0):
        try:
            delay_to_reg(bad)
            raise AssertionError(f"delay {bad} ms did not raise")
        except ValueError:
            pass
    assert feedback_to_q1_15(0.5) == 0x4000
    assert feedback_to_q1_15(0.0) == 0
    assert feedback_to_q1_15(0.99) == 32440  # 32440.32
    for bad in (1.0, 0.99999, 1.5, -0.1):
        try:
            feedback_to_q1_15(bad)
            raise AssertionError(f"feedback {bad} did not raise")
        except ValueError:
            pass
    assert to_raw("q1_15", "1.0") == 0x8000  # mix 1.0 is fine (echo only)
    fake = FakeFpga()
    assert read_reg(fake, 0x06) == 12000  # default 250 ms
    assert read_reg(fake, 0x07) == 0x4000  # default feedback 0.5
    assert read_reg(fake, 0x08) == 0x4000  # default mix 0.5
    write_reg(fake, 0x00, 0x10)  # delay bit without PC control: still off
    assert read_reg(fake, 0x10) & 0x200 == 0
    write_reg(fake, 0x00, 0x90)  # PC control + delay
    assert read_reg(fake, 0x10) == 0x290  # delay on (bit 9), PC (bit 7), bit 4 = SW0 off
    write_reg(fake, 0x06, to_raw("delay", "300"))
    assert from_raw("delay", read_reg(fake, 0x06)) == "300.000 ms"
    print("delay time / feedback / mix ok")


if __name__ == "__main__":
    # No arguments: run the self-test. With arguments: the command line.
    if len(sys.argv) > 1:
        main()
    else:
        self_test()
