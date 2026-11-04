"""Runs the test WAV through the gain stage model and compares with the VHDL output."""

import os
import subprocess

import numpy as np

from gain_stage_model import gain_stage_array
from wav_io import read_text, read_wav_q123, write_text, write_wav_q123

GAIN = 2**16  # Q3.15, 2.0. Must match -gg_gain=... on the GHDL command line.

x_k, fs = read_wav_q123("sim/out/test_guitar.wav")

# Part 1: write the input for the VHDL, then stop so you can run GHDL.
write_text("sim/out/gain_in.txt", x_k)

# Run the VHDL: compile, then simulate with the same gain.
work = os.environ["TEMP"]
subprocess.run(
    [
        "ghdl",
        "-a",
        "--std=08",
        f"--workdir={work}",
        "rtl/gain_stage.vhd",
        "sim/gain_stage_file_tb.vhd",
    ],
    check=True,
)
subprocess.run(
    ["ghdl", "-r", "--std=08", f"--workdir={work}", "gain_stage_file_tb", f"-gg_gain={GAIN}"],
    check=True,
)

# Part 2: after running GHDL, compare and make the WAV.
y_vhdl = read_text("sim/out/gain_out.txt")
y_model = gain_stage_array(x_k, GAIN)
mismatches = np.sum(y_vhdl != y_model)
print(f"{len(y_vhdl)} samples, {mismatches} mismatches")
write_wav_q123("sim/out/gain_out.wav", y_vhdl, fs)
