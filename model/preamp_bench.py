r"""Preamp board bench test with a PicoScope 2207A and the USB audio adapter.

Setup: the adapter's headphone out (left channel) into J2 (3.5 mm -> 1/4"
lead), preamp on its 9 V pedal supply, 10x probes AC coupled on J2's tip
(input) and J3's tip (output), ground clips on the board's GND. Close the
PicoScope app first (the script talks to the scope through ps2000a.dll).

Modes:
    test   1 kHz at -20 dBFS, gain vs frequency (30 Hz .. 20 kHz), level
           sweep at 1 kHz (-30 .. 0 dBFS); prints and saves a plot
    quick  one 1 kHz reading (gain, phase, levels)
    trim   live gain readout at 1 kHz for setting RV1 (Ctrl+C to stop)

Usage (repo root):
    .venv\Scripts\python model\preamp_bench.py test --png docs\img\preamp_bench.png
    .venv\Scripts\python model\preamp_bench.py trim --target 3.0
    --a in   if probe A is on the input and B on the output (default: A on
             the output, B on the input)

Results of the first board: docs/preamp.md, "Bench test".
"""

import argparse
import ctypes
import os
import time
from collections.abc import Callable

import numpy as np
import sounddevice as sd

PICO_DIR = r"C:\Program Files\Pico Technology\PicoScope 7 T&M Stable"
PROBE = 10  # x10 probes
RANGES = {2: 0.05, 3: 0.1, 4: 0.2, 5: 0.5, 6: 1.0, 7: 2.0}  # ps2000a code -> V at the scope
N = 16000  # samples per channel per capture
FS_AUDIO = 48000


class Scope:
    """PicoScope 2207A, both channels AC coupled, untriggered block captures."""

    def __init__(self) -> None:
        """Opens the scope (fails if the PicoScope app has it)."""
        os.add_dll_directory(PICO_DIR)
        self.lib = ctypes.WinDLL(os.path.join(PICO_DIR, "ps2000a.dll"))
        self.h = ctypes.c_int16()
        if self.lib.ps2000aOpenUnit(ctypes.byref(self.h), None) != 0:
            raise SystemExit("scope not found (is the PicoScope app open?)")
        max_adc = ctypes.c_int16()
        self.lib.ps2000aMaximumValue(self.h, ctypes.byref(max_adc))
        self.max_adc = max_adc.value
        self.lib.ps2000aSetSimpleTrigger(self.h, 0, 0, 0, 2, 0, 0)  # no trigger

    def close(self) -> None:
        """Stops and releases the scope."""
        self.lib.ps2000aStop(self.h)
        self.lib.ps2000aCloseUnit(self.h)

    def capture(
        self, f: float, rng_a: int, rng_b: int
    ) -> tuple[np.ndarray, np.ndarray, float, bool]:
        """Captures about 10 periods of f on both channels.

        Args:
            f: the tone frequency, Hz (sets the sample interval, >= 1 us).
            rng_a: channel A range code (a key of RANGES).
            rng_b: channel B range code.

        Returns:
            Channel A and B in volts at the probe tip, the sample interval in
            seconds, and whether either channel overflowed.
        """
        dt = max(1e-6, 10.0 / f / N)
        tb = int(round(dt * 125e6)) + 2  # 2207A: (timebase - 2) / 125 MHz
        dt = (tb - 2) / 125e6
        lib, h = self.lib, self.h
        lib.ps2000aSetChannel(h, 0, 1, 0, rng_a, ctypes.c_float(0.0))  # A on, AC
        lib.ps2000aSetChannel(h, 1, 1, 0, rng_b, ctypes.c_float(0.0))  # B on, AC
        ind = ctypes.c_int32()
        st = lib.ps2000aRunBlock(h, 0, N, tb, 0, ctypes.byref(ind), 0, None, None)
        if st != 0:
            raise RuntimeError(f"RunBlock status 0x{st:x}")
        ready = ctypes.c_int16(0)
        while not ready.value:
            lib.ps2000aIsReady(h, ctypes.byref(ready))
            time.sleep(0.005)
        ba, bb = (ctypes.c_int16 * N)(), (ctypes.c_int16 * N)()
        lib.ps2000aSetDataBuffer(h, 0, ctypes.byref(ba), N, 0, 0)
        lib.ps2000aSetDataBuffer(h, 1, ctypes.byref(bb), N, 0, 0)
        n, ovf = ctypes.c_uint32(N), ctypes.c_int16()
        lib.ps2000aGetValues(h, 0, ctypes.byref(n), 1, 0, 0, ctypes.byref(ovf))
        a = np.array(ba[: n.value]) / self.max_adc * RANGES[rng_a] * PROBE
        b = np.array(bb[: n.value]) / self.max_adc * RANGES[rng_b] * PROBE
        return a, b, dt, bool(ovf.value)


def find_output() -> int:
    """Returns the sounddevice index of the USB adapter's output (MME)."""
    for i, d in enumerate(sd.query_devices()):
        api = sd.query_hostapis(d["hostapi"])["name"]
        if api == "MME" and "USB" in d["name"] and d["max_output_channels"] > 0:
            return i
    raise SystemExit("USB audio adapter output not found")


def fit(v: np.ndarray, f: float, dt: float) -> tuple[float, float]:
    """Amplitude and phase of the f component (least squares, with DC).

    Args:
        v: the signal, volts.
        f: the frequency, Hz.
        dt: the sample interval, seconds.

    Returns:
        Peak amplitude (volts) and phase (radians).
    """
    t = np.arange(len(v)) * dt
    w = 2 * np.pi * f * t
    m = np.column_stack([np.sin(w), np.cos(w), np.ones_like(t)])
    c, *_ = np.linalg.lstsq(m, v, rcond=None)
    return float(np.hypot(c[0], c[1])), float(np.arctan2(c[1], c[0]))


def thd(v: np.ndarray, f: float, dt: float) -> float:
    """Total harmonic distortion (2nd..5th), percent.

    Args:
        v: the signal, volts.
        f: the fundamental, Hz.
        dt: the sample interval, seconds.

    Returns:
        THD in percent (8-bit scope: unreliable below ~50 mV).
    """
    s = np.abs(np.fft.rfft((v - v.mean()) * np.blackman(len(v))))
    fr = np.fft.rfftfreq(len(v), dt)

    def band(x: float) -> float:
        """RMS of the spectrum around x."""
        i = int(np.argmin(abs(fr - x)))
        return float(np.sqrt(np.sum(s[max(i - 3, 0) : i + 4] ** 2)))

    harmonics = [band(k * f) for k in range(2, 6) if k * f < 0.4 / dt]
    return 100 * float(np.sqrt(sum(x**2 for x in harmonics))) / band(f)


def pick_range(peak: float) -> int:
    """Smallest range code that holds peak (volts at the tip) with 30 % spare."""
    for code, r in sorted(RANGES.items()):
        if peak * 1.3 < r * PROBE:
            return code
    return 7


class Bench:
    """Plays tones on the adapter and measures them on the scope."""

    def __init__(self, a_is_input: bool) -> None:
        """Opens the scope and finds the adapter.

        Args:
            a_is_input: True if probe A is on J2 (input), False if on J3.
        """
        self.scope = Scope()
        self.out = find_output()
        self.a_is_input = a_is_input

    def close(self) -> None:
        """Stops the tone and releases the scope."""
        sd.stop()
        self.scope.close()

    def start_tone(self, f: float, dbfs: float, seconds: float = 4.0, loop: bool = False) -> None:
        """Starts a sine on the left channel (the right one silent).

        Args:
            f: frequency, Hz.
            dbfs: level, dB below the adapter's full scale.
            seconds: length of the buffer.
            loop: repeat it until sd.stop().
        """
        t = np.arange(int(FS_AUDIO * seconds)) / FS_AUDIO
        x = (10 ** (dbfs / 20) * np.sin(2 * np.pi * f * t)).astype(np.float32)
        sd.play(np.column_stack([x, np.zeros_like(x)]), FS_AUDIO, device=self.out, loop=loop)

    def read(self, f: float) -> dict[str, float | np.ndarray | bool]:
        """Measures the tone that is playing, on both channels.

        Args:
            f: the tone's frequency, Hz.

        Returns:
            vin / vout (V peak), gain, phase (deg, out vs in), thd_in /
            thd_out (%), overflow, and the waveforms win / wout with dt.
        """
        a, b, dt, _ = self.scope.capture(f, 7, 7)  # +-20 V at the tip: find the size
        a, b, dt, ovf = self.scope.capture(
            f, pick_range(np.abs(a).max()), pick_range(np.abs(b).max())
        )
        win, wout = (a, b) if self.a_is_input else (b, a)
        vin, pin = fit(win, f, dt)
        vout, pout = fit(wout, f, dt)
        phase = float(np.degrees((pout - pin + np.pi) % (2 * np.pi) - np.pi))
        return {
            "vin": vin,
            "vout": vout,
            "gain": vout / vin,
            "phase": phase,
            "thd_in": thd(win, f, dt),
            "thd_out": thd(wout, f, dt),
            "overflow": ovf,
            "win": win,
            "wout": wout,
            "dt": dt,
        }

    def measure(self, f: float, dbfs: float) -> dict[str, float | np.ndarray | bool]:
        """Plays a tone, lets it settle, measures it, stops it.

        Args:
            f: frequency, Hz.
            dbfs: level, dBFS.

        Returns:
            The same as read().
        """
        self.start_tone(f, dbfs)
        time.sleep(0.6)
        r = self.read(f)
        sd.stop()
        return r


def line(r: dict[str, float | np.ndarray | bool]) -> str:
    """One-line summary of a reading."""
    return (
        f"in {r['vin'] * 1000:7.1f} mV pk, out {r['vout'] * 1000:7.1f} mV pk, "
        f"gain {r['gain']:.3f} ({20 * np.log10(r['gain']):+.2f} dB), phase {r['phase']:+6.1f} deg, "
        f"THD out {r['thd_out']:.3f} %" + ("  OVERFLOW" if r["overflow"] else "")
    )


def run_quick(bench: Bench, level: float) -> None:
    """One 1 kHz reading.

    Args:
        bench: the open bench.
        level: tone level, dBFS.
    """
    print(f"1 kHz, {level:.0f} dBFS: " + line(bench.measure(1000, level)))


def run_trim(bench: Bench, level: float, target: float, seconds: float) -> None:
    """Live gain readout at 1 kHz while RV1 is adjusted.

    Args:
        bench: the open bench.
        level: tone level, dBFS.
        target: the gain to aim for.
        seconds: how long to run (Ctrl+C stops it sooner).
    """
    print(f"Trim RV1 for gain {target:.3f} (1 kHz, {level:.0f} dBFS). Ctrl+C to stop.")
    bench.start_tone(1000, level, seconds=10.0, loop=True)
    time.sleep(0.6)
    t_end = time.time() + seconds
    try:
        while time.time() < t_end:
            g = bench.read(1000)["gain"]
            err = 100 * (g - target) / target
            hint = (
                "OK"
                if abs(err) < 0.5
                else ("too high: lower it" if err > 0 else "too low: raise it")
            )
            bar = "#" * max(0, min(40, int(round(20 + err * 4))))
            print(f"gain {g:.3f}  ({err:+5.1f} %)  {bar:<40}|  {hint}", flush=True)
            time.sleep(0.3)
    except KeyboardInterrupt:
        pass
    sd.stop()


def run_test(bench: Bench, png: str | None) -> None:
    """The full test: 1 kHz, frequency response, level sweep, plot.

    Args:
        bench: the open bench.
        png: where to save the plot (None: no plot).
    """
    first = bench.measure(1000, -20)
    print("1. 1 kHz, -20 dBFS: " + line(first))

    print("2. gain vs frequency, -20 dBFS")
    freqs = [30, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 15000, 20000]
    gains = []
    for f in freqs:
        r = bench.measure(f, -20)
        gains.append(r["gain"])
        print(f"   {f:6d} Hz: " + line(r))

    print("3. level sweep, 1 kHz")
    levels = [-30, -20, -12, -6, -3, 0]
    outs, thds = [], []
    for lv in levels:
        r = bench.measure(1000, lv)
        outs.append(r["vout"])
        thds.append(r["thd_out"])
        print(f"   {lv:4d} dBFS: " + line(r))

    if png:
        plot(first, freqs, gains, levels, outs, thds, png)
        print(f"saved {png}")


def plot(
    first: dict[str, float | np.ndarray | bool],
    freqs: list[int],
    gains: list[float],
    levels: list[int],
    outs: list[float],
    thds: list[float],
    png: str,
) -> None:
    """Three-panel figure: waveforms, gain vs frequency, level sweep.

    Args:
        first: the 1 kHz reading (with waveforms).
        freqs: the sweep frequencies, Hz.
        gains: the gain at each frequency.
        levels: the sweep levels, dBFS.
        outs: the output at each level, V peak.
        thds: the output THD at each level, %.
        png: the file to write.
    """
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(3, 1, figsize=(10, 11))
    t = np.arange(len(first["win"])) * first["dt"] * 1000
    k = t < 3
    ax[0].plot(t[k], first["win"][k] * 1000, label="input (J2 tip)", color="#2b6cb0")
    ax[0].plot(t[k], first["wout"][k] * 1000, label="output (J3 tip)", color="#c53030")
    ax[0].set_xlabel("time (ms)")
    ax[0].set_ylabel("mV")
    ax[0].grid(alpha=0.3)
    ax[0].legend()
    ax[0].set_title("1 kHz at -20 dBFS: input and output", fontsize=10, loc="left")

    g_db = 20 * np.log10(gains)
    ax[1].semilogx(freqs, g_db, "o-", color="#c53030")
    ax[1].set_xlabel("frequency (Hz)")
    ax[1].set_ylabel("gain (dB)")
    ax[1].grid(True, which="both", alpha=0.3)
    g1k = gains[freqs.index(1000)]
    ax[1].set_title(
        f"Gain vs frequency (1 kHz: {20 * np.log10(g1k):.2f} dB = x{g1k:.2f})",
        fontsize=10,
        loc="left",
    )

    ax[2].plot(levels, thds, "o-", color="#2f855a")
    ax2 = ax[2].twinx()
    ax2.plot(levels, np.array(outs) * 1000, "s--", color="#718096")
    ax[2].set_xlabel("adapter level (dBFS)")
    ax[2].set_ylabel("output THD (%)", color="#2f855a")
    ax2.set_ylabel("output (mV peak)", color="#718096")
    ax[2].set_title("1 kHz level sweep: distortion and output level", fontsize=10, loc="left")
    ax[2].grid(alpha=0.3)
    fig.suptitle("guitar-fx preamp board: bench test", fontsize=12)
    fig.tight_layout()
    fig.savefig(png, dpi=110)


def main() -> None:
    """Parses the command line and runs the chosen mode."""
    p = argparse.ArgumentParser(description="Preamp board bench test (PicoScope 2207A).")
    p.add_argument("mode", choices=["test", "quick", "trim"], nargs="?", default="quick")
    p.add_argument(
        "--a", choices=["in", "out"], default="out", help="where probe A is (default: out)"
    )
    p.add_argument("--level", type=float, default=-20.0, help="tone level for quick / trim, dBFS")
    p.add_argument("--target", type=float, default=3.0, help="trim: the gain to aim for")
    p.add_argument("--seconds", type=float, default=180.0, help="trim: how long to run")
    p.add_argument("--png", default=None, help="test: save the plot here")
    args = p.parse_args()

    bench = Bench(a_is_input=args.a == "in")
    modes: dict[str, Callable[[], None]] = {
        "quick": lambda: run_quick(bench, args.level),
        "trim": lambda: run_trim(bench, args.level, args.target, args.seconds),
        "test": lambda: run_test(bench, args.png),
    }
    try:
        modes[args.mode]()
    finally:
        bench.close()


if __name__ == "__main__":
    main()
