import numpy as np
from numpy.typing import ArrayLike, NDArray


def gain_stage(x_k: int, g_k: int) -> int:
    """Bit-exact model of rtl/gain_stage.vhd, one sample at a time.

    Multiplies, rounds to nearest (adds 2**14), drops 15 LSBs, then
    saturates to the Q1.23 range. Reference for gain_stage_array.

    Args:
        x_k (int): input sample, Q1.23 integer (-2**23 .. 2**23 - 1).
        g_k (int): gain, Q3.15 integer (-2**17 .. 2**17 - 1); 2**15 = 1.0.

    Returns:
        int: output sample, Q1.23 integer, saturated.
    """
    product = x_k * g_k  # Q4.38
    rounded = product + (1 << 14)  # round to nearest, Q4.38
    y = rounded >> 15  # Q1.23

    y_max = 2**23 - 1
    y_min = -(2**23)
    if y > y_max:
        y = y_max
    elif y < y_min:
        y = y_min
    return y


def gain_stage_array(x_k: ArrayLike, g_k: ArrayLike) -> NDArray[np.int64]:
    """Bit-exact model of rtl/gain_stage.vhd for a whole array of samples.

    Same maths as gain_stage, element by element; np.clip replaces the
    if/elif saturation. Inputs are converted to int64 so the 42-bit
    product cannot overflow.

    Args:
        x_k (array-like of int): input samples, Q1.23 integers.
        g_k (int or array-like of int): gain, Q3.15 integer (one value for
            all samples, or one per sample).

    Returns:
        numpy.ndarray of int64: output samples, Q1.23 integers, saturated.
    """
    x_k = np.asarray(x_k, dtype=np.int64)
    g_k = np.asarray(g_k, dtype=np.int64)

    product = x_k * g_k  # Q4.38
    rounded = product + (1 << 14)  # round to nearest, Q4.38
    y = rounded >> 15  # Q1.23

    y_max = 2**23 - 1
    y_min = -(2**23)

    y = np.clip(y, y_min, y_max)

    return y


if __name__ == "__main__":
    assert gain_stage(1000, 2**15) == 1000  # unity
    assert gain_stage(1001, 2**14) == 501  # 500.5 rounds up
    assert gain_stage(-1, 2**13) == 0  # -0.25 rounds to 0
    assert gain_stage(2**23 - 1, 2**16) == 2**23 - 1  # saturates at max
    print("model ok")

    rng = np.random.default_rng(1)  # random numbers, same every run
    xs = rng.integers(-(2**23), 2**23, size=10000, dtype=np.int64)  # 10,000 random Q1.23 samples
    for g in [2**13, 2**15, 2**16 + 123, 2**17 - 1, -(2**15)]:  # a few gains, incl. saturating ones
        expected = [gain_stage(int(x), g) for x in xs]  # slow, one at a time
        got = gain_stage_array(xs, g)  # fast, all at once
        assert list(got) == expected
    print("array model ok")
