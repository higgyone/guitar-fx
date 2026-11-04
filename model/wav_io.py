"""Audio file plumbing for the DSP models and VHDL file testbenches.

Everything inside the project uses Q1.23 integers (k = value * 2**23,
range -2**23 .. 2**23 - 1), held in numpy int64 arrays.

- WAV files: read any common format (16-bit, 24-bit-in-32, 32-bit int,
  float); written as 32-bit float, which holds 24-bit values exactly.
- Text files: one integer per line. This is what the VHDL testbenches read
  and write (std.textio), so Python and VHDL share the same numbers.
"""

from pathlib import Path

import numpy as np
from numpy.typing import ArrayLike, NDArray
from scipy.io import wavfile

Q123_MAX = 2**23 - 1
Q123_MIN = -(2**23)


def read_wav_q123(path: str | Path) -> tuple[NDArray[np.int64], int]:
    """Read a WAV file as Q1.23 integers. Stereo is mixed to mono.

    Args:
        path (str or pathlib.Path): WAV file to read (16-bit, 32-bit int or
            float samples).

    Returns:
        tuple[numpy.ndarray of int64, int]: (samples as Q1.23 integers,
        sample rate in Hz).

    Raises:
        ValueError: the WAV sample type is not supported.
    """
    rate, data = wavfile.read(path)

    # Scale each format to Q1.23 first, then mix channels.
    if data.dtype == np.int16:
        k = data.astype(np.int64) << 8  # 16-bit -> 24-bit: 8 zero LSBs
    elif data.dtype == np.int32:
        k = data.astype(np.int64) >> 8  # 32-bit container -> top 24 bits
    elif data.dtype in (np.float32, np.float64):
        k = np.round(data * 2**23).astype(np.int64)  # float full scale is +-1.0
    else:
        raise ValueError(f"unsupported WAV sample type {data.dtype}")

    if k.ndim > 1:
        k = np.round(k.mean(axis=1)).astype(np.int64)  # stereo -> mono
    return np.clip(k, Q123_MIN, Q123_MAX), rate


def write_wav_q123(path: str | Path, k: ArrayLike, rate: int) -> None:
    """Write Q1.23 integers to a mono 32-bit float WAV file.

    Args:
        path (str or pathlib.Path): WAV file to write (overwritten).
        k (array-like of int): samples, Q1.23 integers.
        rate (int): sample rate in Hz, e.g. 48000.

    Returns:
        None
    """
    k = np.asarray(k, dtype=np.int64)
    wavfile.write(path, rate, (k / 2**23).astype(np.float32))


def write_text(path: str | Path, k: ArrayLike) -> None:
    """Write integers to a text file, one per line (VHDL testbench input).

    Args:
        path (str or pathlib.Path): text file to write (overwritten).
        k (array-like of int): values to write, e.g. Q1.23 samples.

    Returns:
        None
    """
    np.savetxt(path, np.asarray(k, dtype=np.int64), fmt="%d")


def read_text(path: str | Path) -> NDArray[np.int64]:
    """Read a text file of integers, one per line (VHDL testbench output).

    Args:
        path (str or pathlib.Path): text file to read.

    Returns:
        numpy.ndarray of int64: the values, in file order (always 1-D, even
        for a single line).
    """
    return np.loadtxt(path, dtype=np.int64, ndmin=1)
