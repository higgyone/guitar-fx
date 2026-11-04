r"""Generates a synthetic plucked-guitar test signal as a WAV file.

Not a DSP model, just test audio until real guitar recordings exist.
Each note is a sum of harmonics with an exponential decay (higher harmonics
die away faster, like a real string) and a 2 ms attack to avoid a click.

Notes: open low E, then A, D, G, and finally an E-minor chord strummed
hard. Peaks about 0.6 of full scale, so a gain of 2.0 saturates.

Usage (repo root):
    .venv\Scripts\python model\make_test_signal.py [output.wav]
Default output: sim/out/test_guitar.wav (sim/out/ is gitignored).
"""

import sys
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from wav_io import write_wav_q123

RATE = 48000

# (start time s, frequency Hz, peak amplitude)
NOTES = [
    (0.00, 82.41, 0.30),  # E2
    (0.75, 110.00, 0.30),  # A2
    (1.50, 146.83, 0.30),  # D3
    (2.25, 196.00, 0.30),  # G3
    # E minor chord, strummed: each string 15 ms after the last
    (3.00, 82.41, 0.16),
    (3.015, 123.47, 0.16),
    (3.030, 164.81, 0.16),
    (3.045, 196.00, 0.16),
    (3.060, 246.94, 0.16),
    (3.075, 329.63, 0.16),
]
LENGTH_S = 5.0


def pluck(freq: float, amp: float, n: int) -> NDArray[np.float64]:
    """One plucked note: harmonics with exponential decay and a 2 ms attack.

    Args:
        freq (float): fundamental frequency in Hz.
        amp (float): peak amplitude, 0.0..1.0 of full scale.
        n (int): length in samples (at RATE).

    Returns:
        numpy.ndarray of float64: the note, n samples, peak equal to amp.
    """
    t = np.arange(n) / RATE
    note = np.zeros(n)
    for h in range(1, 13):  # 12 harmonics
        if h * freq > RATE / 2:  # skip above Nyquist
            break
        decay = 1.5 + 0.8 * h  # higher harmonics fade faster
        note += np.exp(-decay * t) * np.sin(2 * np.pi * h * freq * t) / h
    attack = np.minimum(t / 0.002, 1.0)  # 2 ms fade-in
    note *= attack
    return amp * note / np.max(np.abs(note))


def make_signal() -> NDArray[np.float64]:
    """Build the full test signal: every note in NOTES, summed.

    Args:
        None (uses the module constants RATE, NOTES and LENGTH_S).

    Returns:
        numpy.ndarray of float64: LENGTH_S * RATE samples, roughly
        -1.0..+1.0 (peak about 0.6).
    """
    total = int(LENGTH_S * RATE)
    sig = np.zeros(total)
    for start, freq, amp in NOTES:
        i = int(start * RATE)
        sig[i:] += pluck(freq, amp, total - i)
    return sig


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("sim/out/test_guitar.wav")
    out.parent.mkdir(parents=True, exist_ok=True)
    sig = make_signal()
    k = np.clip(np.round(sig * 2**23), -(2**23), 2**23 - 1).astype(np.int64)
    write_wav_q123(out, k, RATE)
    print(
        f"wrote {out}: {len(k)} samples, {LENGTH_S} s, peak {np.max(np.abs(sig)):.2f} of full scale"
    )
