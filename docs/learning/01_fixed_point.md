# Lesson 1 — Fixed-point multiplication

## 1. Q-format

`Qm.n`: `m` integer bits (including the sign bit), `n` fraction bits.
Total width `m + n`. Two's complement.

The bits are just a signed integer `k`. The value is:

    value = k / 2^n

Smallest step (1 LSB) is `2^-n`. Range is `-2^(m-1)` to `2^(m-1) - 2^-n`.

**Q1.3** (4 bits) — small enough to do by hand:

| Bits | k | Value k/8 |
|------|---|-----------|
| 0111 | 7 | +0.875 (max) |
| 0100 | 4 | +0.5 |
| 0001 | 1 | +0.125 (1 LSB) |
| 0000 | 0 | 0 |
| 1111 | −1 | −0.125 |
| 1100 | −4 | −0.5 |
| 1000 | −8 | −1.0 (min) |

Note: −1.0 fits, +1.0 does not. Range is not symmetric.

**Q1.23** (24 bits) — the project's sample format. Same idea, `k / 2^23`.

## 2. The multiply rule

Multiply the integers. The formats add:

    Qa.b  ×  Qc.d  =  Q(a+c).(b+d)        width = (a+b) + (c+d)

Why: `(k1 / 2^b) × (k2 / 2^d) = (k1 × k2) / 2^(b+d)`.
So the product's integer is `k1 × k2` and it has `b + d` fraction bits.

Worked example, Q1.3 × Q1.3 → Q2.6 (8 bits):

    0.5 × 0.75
    k1 = 4 (0100), k2 = 6 (0110)
    k1 × k2 = 24 = 0001_1000   as Q2.6:  00.011000
    value = 24 / 64 = 0.375  ✓

Negative:

    −0.5 × 0.75
    k1 = −4 (1100), k2 = 6 (0110)
    k1 × k2 = −24 = 1110_1000  as Q2.6
    value = −24 / 64 = −0.375  ✓

In VHDL (`numeric_std`), `signed * signed` already returns a result as wide
as both inputs added together. The hardware never "knows" about the binary
point — you track it on paper.

## 3. Getting back to the original format

Product is Q2.6, we want Q1.3. Two steps:

1. **Drop fraction bits** (`6 − 3 = 3` of them): shift right by 3.
   This loses precision.
2. **Drop integer bits** (`2 − 1 = 1` of them): take fewer top bits.
   This can overflow.

    24 = 0001_1000  >> 3  =  0011 = 3   → 3/8 = 0.375  ✓
   −24 = 1110_1000  >> 3  =  1101 = −3  → −3/8 = −0.375  ✓

(Shift right on signed = arithmetic shift: the sign bit is copied in.)

Taking a shift and a narrower width together is just a **bit slice**.

### Finding the slice: find the point, then count

1. **Find the binary point.** A product with `F` fraction bits has them in
   bits `F−1 downto 0`. The point sits between bit `F` and bit `F−1`.
   (Off-by-one trap: `F` bits occupy `F−1 downto 0`, not `F downto 0`.)
2. **Top of the slice** = the output's integer bits counted left from the
   point. For a Q1.x output that is just bit `F` (the sign bit).
3. **Bottom of the slice** = the output's fraction bits counted right from
   the point: bit `F − n_out`. This equals the number of bits dropped.
4. **Check the width**: top − bottom + 1 = output width.

| Multiply | Product | Point between | Q1.x slice | Overflow check bits |
|----------|---------|---------------|------------|---------------------|
| Q1.3 × Q1.3 | Q2.6 (8 b) | 6 / 5 | `p(6 downto 3)` | 7, 6 |
| Q1.3 × Q3.1 | Q4.4 (8 b) | 4 / 3 | `p(4 downto 1)` | 7 … 4 |
| Q1.23 × Q1.17 | Q2.40 (42 b) | 40 / 39 | `p(40 downto 17)` | 41, 40 |
| Q1.23 × Q3.15 | Q4.38 (42 b) | 38 / 37 | `p(38 downto 15)` | 41 … 38 |

Overflow check: the dropped top bits **and** the kept sign bit must all be
equal (all 0 or all 1). Otherwise saturate.

## 4. Overflow — why the extra integer bit exists

Q1.3 × Q1.3 can only leave the Q1.3 range in one case: `−1 × −1 = +1`.
The product (Q2.6) holds +1 fine. Q1.3 cannot.

If you just slice the bits, the dropped top bit is lost and the result
**wraps** to a large negative number. In audio that is a loud click.

**Saturation**: if the dropped top bits are not all copies of the kept sign
bit, the value is out of range → output the max (or min) value instead.

    dropped bits + kept sign bit all 0  → positive, in range
    dropped bits + kept sign bit all 1  → negative, in range
    anything else                       → overflow → clamp

## 5. Truncation vs rounding

A plain shift right **truncates** (rounds towards −∞). The error is always
negative, average −½ LSB → a tiny DC offset, plus distortion at low levels.

**Round to nearest**: add half an output LSB before shifting.
Half an output LSB in the product's units = `2^(shift − 1)`.

    0.625 × 0.75  (exact 0.46875)
    5 × 6 = 30
    truncate: 30 >> 3 = 3       → 0.375
    round:   (30 + 4) >> 3 = 4  → 0.5     (nearer to 0.46875)

Rounding can itself overflow at the very top of the range → saturate after
rounding.

## 6. Gains greater than 1

Q1.n cannot represent > 1. For a gain of up to 4× use more integer bits
in the coefficient, e.g. **Q3.15** (still 18 bits, range −4 to +4 − 2⁻¹⁵).
The product then has 3 extra integer bits → overflow is now normal, so
saturation is essential.

## 7. Why 18 bits for coefficients

The Artix-7 DSP48E1 slice has a **25 × 18** signed multiplier.
24-bit samples fit the 25-bit port, 18-bit coefficients fit the other.
One multiply per DSP48, no extra logic.

## Exercises

E1. What value is `1010` in Q1.3?

E2. By hand, in Q1.3: −0.75 × −0.5. Give the integers, the product bits, its
    Q-format, then the Q1.3 result.

E3. −1 × −1 in Q1.3. What bits does a plain slice give, what value is that,
    and what should saturation output instead?

E4. Q1.23 sample × Q1.17 coefficient.
    (a) Product Q-format and width?
    (b) Which bit range do you keep for a Q1.23 result?
    (c) Which bits must you check for overflow?

E5. Q1.23 sample × Q3.15 gain (up to 4×). Same three questions as E4.

E6. At 100 MHz and 48 kHz, how many clock cycles per sample?
