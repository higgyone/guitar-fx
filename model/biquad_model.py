"""Model of the tone control: a biquad low-pass filter (effect #4).

    y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]

Coefficients from the Audio EQ Cookbook (low-pass), normalised so the
y[n] coefficient (a0) is 1. In hardware they are Q2.16 integers (18 bits,
-2 .. just under +2).

Steps:
    A. lowpass_coeffs: cutoff, Q, sample rate -> five float coefficients.
    B. quantise: floats -> Q2.16 integers (and back, to see the error).
    C. plot: frequency response, exact vs quantised.
"""

import math

import matplotlib.pyplot as plt
import numpy as np
from scipy import signal

COEFF_FRAC_BITS = 16  # Q2.16: 16 fraction bits, 1.0 = 2**16
SAMPLE_RATE = 48000.0  # Hz


def lowpass_coeffs(fc: float, q: float, fs: float) -> tuple[float, float, float, float, float]:
    """Cookbook low-pass biquad coefficients, normalised by a0.

    Args:
        fc (float): cutoff frequency, Hz.
        q (float): resonance; 0.707 = smooth (Butterworth).
        fs (float): sample rate, Hz.

    Returns:
        tuple of float: (b0, b1, b2, a1, a2).
    """
    w0 = 2 * math.pi * fc / fs
    alpha = math.sin(w0) / (2 * q)

    b0 = (1 - math.cos(w0)) / 2
    b1 = 1 - math.cos(w0)
    b2 = (1 - math.cos(w0)) / 2
    a0 = 1 + alpha
    a1 = -2 * math.cos(w0)
    a2 = 1 - alpha

    return b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0


def quantise(coeffs: tuple[float, ...]) -> list[int]:
    """Rounds each coefficient to a Q2.16 integer.

    Args:
        coeffs (tuple of float): (b0, b1, b2, a1, a2).

    Returns:
        list of int: the same five as Q2.16 integers (value * 2**16, rounded).
    """
    for value in coeffs:
        if not -2.0 <= value < 2.0:
            raise ValueError(f"Coefficient {value} out of range for Q2.16")

    integers = [round(value * 2**COEFF_FRAC_BITS) for value in coeffs]

    for n in integers:
        if not -(2**17) <= n < 2**17:
            raise ValueError(f"Quantised coefficient {n} out of range for Q2.16")

    return integers


def plot_response(fc: float, q: float, fs: float) -> None:
    """Plots the gain in dB against frequency: exact and quantised filters.

    Args:
        fc (float): cutoff frequency, Hz.
        q (float): resonance.
        fs (float): sample rate, Hz.
    """
    # 1. The exact filter
    b0, b1, b2, a1, a2 = lowpass_coeffs(fc, q, fs)
    w, h = signal.freqz([b0, b1, b2], [1, a1, a2], worN=4096, fs=fs)

    # 2. The quantised filter: round to Q2.16, then back to floats
    q16 = quantise((b0, b1, b2, a1, a2))
    bq0, bq1, bq2, aq1, aq2 = [n / 2**COEFF_FRAC_BITS for n in q16]
    wq, hq = signal.freqz([bq0, bq1, bq2], [1, aq1, aq2], worN=4096, fs=fs)

    # 3. Gain in dB, on a log frequency axis
    plt.semilogx(w, 20 * np.log10(abs(h)), label="exact")
    plt.semilogx(wq, 20 * np.log10(abs(hq)), "--", label="Q2.16")

    # 4. Labels, cutoff line, range
    plt.axvline(fc, color="grey", linestyle=":")
    plt.xlim(20, fs / 2)
    plt.ylim(-60, 6)
    plt.xlabel("frequency (Hz)")
    plt.ylabel("gain (dB)")
    plt.title(f"Biquad low-pass, fc = {fc:.0f} Hz, Q = {q}")
    plt.grid(True, which="both")
    plt.legend()
    plt.show()


def biquad_q(x: list[int], coeffs_q16: list[int]) -> list[int]:
    """Bit-exact model of the hardware biquad (Direct Form I), one sample at a time.

    Sum of the five products in Q6.39, round to nearest (add 2**15), drop 16
    bits, saturate to Q1.23. The state holds the rounded, saturated samples.

    Args:
        x (list of int): input samples, Q1.23 integers (-2**23 .. 2**23 - 1).
        coeffs_q16 (list of int): (b0, b1, b2, a1, a2) as Q2.16 integers.

    Returns:
        list of int: output samples, Q1.23 integers, one per input.
    """
    b0, b1, b2, a1, a2 = coeffs_q16
    x1 = x2 = y1 = y2 = 0  # state: x[n-1], x[n-2], y[n-1], y[n-2]
    y_out = []

    for xn in x:
        # the sum, Q6.39 (mind the minus signs on the feedback terms)
        acc = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2

        # round (add half of what is dropped), shift 16, clip to Q1.23
        rounded = acc + (1 << 15)  # before
        y = rounded >> 16  # the shift
        y = int(np.clip(y, -(2**23), 2**23 - 1))  # after

        # move the state along (old values first: x2 before x1, y2 before y1)
        x2 = x1
        x1 = xn
        y2 = y1
        y1 = y

        y_out.append(y)

    return y_out


if __name__ == "__main__":
    # Step A check: should print 0.029954, 0.059909, 0.029954, -1.454243, 0.574061
    # (to about the 5th decimal; q = 0.707 is not exactly 1 / sqrt(2)).
    coeffs = lowpass_coeffs(3000.0, 0.707, SAMPLE_RATE)
    print("float:", [f"{c:.6f}" for c in coeffs])

    q16 = quantise(coeffs)
    print("Q2.16:", q16)
    print("back :", [f"{n / 2**COEFF_FRAC_BITS:.6f}" for n in q16])

    # Step D checks: biquad_q against scipy's float filter with the same
    # (quantised) coefficients. Rounding inside the loop allows a few LSB.
    q_float = [n / 2**COEFF_FRAC_BITS for n in q16]  # Q2.16 back to floats

    # A step to 0.5 full scale settles to the input (DC gain 1); rounding
    # can leave it 1 LSB off (deadband).
    step = [2**22] * 1000
    ys = biquad_q(step, q16)
    assert abs(ys[-1] - 2**22) <= 2, f"step settled at {ys[-1]}, input {2**22}"
    print(f"step: settles at {ys[-1]} (input {2**22})")

    # Sines in the passband and the stop band, 0.5 full scale.
    k = np.arange(2000)
    for f in (1000.0, 10000.0):
        x = [round(0.5 * 2**23 * math.sin(2 * math.pi * f * n / SAMPLE_RATE)) for n in k]
        yq = np.array(biquad_q(x, q16), dtype=float)
        yf = signal.lfilter(q_float[:3], [1.0, q_float[3], q_float[4]], x)
        err = np.max(np.abs(yq - yf))
        assert err <= 3, f"{f:.0f} Hz: model differs from float by {err:.2f} LSB"
        gain_db = 20 * np.log10(np.max(np.abs(yq[500:])) / (0.5 * 2**23))
        print(f"{f:5.0f} Hz: within {err:.2f} LSB of float, gain {gain_db:+.1f} dB")

    print("model checks ok")

    # Last: the window waits until it is closed.
    plot_response(3000.0, 0.707, SAMPLE_RATE)
