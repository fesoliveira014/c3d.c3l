#!/usr/bin/env python3
"""Run the cloth step-shape matrix and print one table.

  measure_cloth_step.py timing --exe PATH [--runs 3] [--frames N]
  measure_cloth_step.py equivalence --exe PATH [--frames 60]

timing alternates shapes inside each run, so clock drift reaches every shape alike, and reports the
median over runs of each per-run median. equivalence dumps the device positions after N steps of
every shape and reports the worst per-axis deviation of fused and single from pr0.

The executable is the cloth_gpu example built with the profiler GPU defines. Extra environment
(for example the validation layer settings) is inherited.
"""

from __future__ import annotations

import argparse
import statistics
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

SCENES = ("flag33", "flag128")
SHAPES = ("pr0", "fused", "single", "single_cached")


def run_example(exe: Path, scene: str, shape: str, extra: list[str]) -> str:
    command = [str(exe), "--scene", scene, "--gpu", "--gpu-shape", shape, "--benchmark", *extra]
    result = subprocess.run(command, capture_output=True, text=True, cwd=exe.parent)
    if result.returncode != 0:
        sys.exit(f"{' '.join(command)}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def field(output: str, prefix: str, key: str) -> float:
    for line in output.splitlines():
        if line.startswith(prefix):
            cells = line.split(",")
            return float(cells[cells.index(key) + 1])
    sys.exit(f"no '{prefix}' line with '{key}' in:\n{output}")


def timing(options: argparse.Namespace) -> None:
    extra = ["--frames", str(options.frames)] if options.frames else []
    samples: dict[tuple[str, str], list[tuple[float, float, float, float]]] = {}
    dispatches: dict[tuple[str, str], int] = {}
    for _ in range(options.runs):
        for scene in options.scenes:
            for shape in options.shapes:
                output = run_example(options.exe, scene, shape, extra)
                key = (scene, shape)
                dispatches[key] = int(field(output, "gpu_cloth,shape", "dispatches_per_step"))
                samples.setdefault(key, []).append((
                    field(output, "gpu_cloth,custom_compute_ms", "median"),
                    field(output, "gpu_cloth,custom_compute_ms", "p95"),
                    field(output, "gpu_cloth,record_ms", "mean"),
                    field(output, "gpu_frame_ms", "median"),
                ))
    print("scene,shape,dispatches,custom_compute_ms_median_of_runs,runs,p95_of_runs,record_ms_mean,gpu_frame_ms_median")
    for (scene, shape), runs in samples.items():
        medians = [run[0] for run in runs]
        print(
            f"{scene},{shape},{dispatches[(scene, shape)]},{statistics.median(medians):.4f},"
            f"{'/'.join(f'{value:.4f}' for value in medians)},"
            f"{statistics.median(run[1] for run in runs):.4f},"
            f"{statistics.median(run[2] for run in runs):.4f},"
            f"{statistics.median(run[3] for run in runs):.4f}"
        )


def read_positions(path: Path) -> list[tuple[float, float, float, float]]:
    data = path.read_bytes()
    return [struct.unpack_from("4f", data, offset) for offset in range(0, len(data), 16)]


def equivalence(options: argparse.Namespace) -> None:
    with tempfile.TemporaryDirectory() as scratch:
        for scene in options.scenes:
            dumps = {}
            for shape in options.shapes:
                dumps[shape] = Path(scratch) / f"{scene}-{shape}.bin"
                run_example(options.exe, scene, shape, ["--frames", str(options.frames), "--dump", str(dumps[shape])])
            reference = read_positions(dumps["pr0"])
            for shape in options.shapes:
                if shape == "pr0":
                    continue
                other = read_positions(dumps[shape])
                worst = max(
                    max(abs(a[axis] - b[axis]) for axis in range(4)) for a, b in zip(reference, other)
                )
                print(f"{scene},{shape},particles,{len(reference)},worst_deviation_m,{worst:.3e}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("timing", "equivalence"))
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--frames", type=int, default=0)
    parser.add_argument("--scenes", nargs="+", default=list(SCENES))
    parser.add_argument("--shapes", nargs="+", default=list(SHAPES))
    options = parser.parse_args()
    options.exe = options.exe.resolve()
    if options.mode == "equivalence":
        options.frames = options.frames or 60
        equivalence(options)
    else:
        timing(options)


if __name__ == "__main__":
    main()
