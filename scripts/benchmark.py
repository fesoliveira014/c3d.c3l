#!/usr/bin/env python3
"""Run CPU or headless rendering sweeps; retain raw samples and environment metadata."""

import argparse
import csv
import hashlib
import io
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
CPU_CASES = ["world", "hidden_world", "meshes", "culled_meshes", "hidden_meshes",
             "shadows", "lights", "hidden_lights", "sort"]


def capture(command):
    try:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=30)
        return result.stdout + result.stderr
    except (OSError, subprocess.TimeoutExpired) as error:
        return str(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=["cpu", "render"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--cpu", type=int, help="Linux CPU affinity; omitted by default")
    parser.add_argument("--nodes", type=int, nargs="+", default=[1024, 4096, 16384])
    parser.add_argument("--cases", nargs="+", choices=CPU_CASES, default=CPU_CASES)
    parser.add_argument("--iterations", type=int, default=100)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--lights", type=int, nargs="+", default=[64, 256, 1024, 4096])
    parser.add_argument("--modes", nargs="+", choices=["flat", "clustered"], default=["flat", "clustered"])
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--warmup", type=int, default=60)
    parser.add_argument("--width", type=int, default=1440)
    parser.add_argument("--height", type=int, default=900)
    parser.add_argument("--capacity", type=int, default=64)
    parser.add_argument("--range", type=float, default=6)
    parser.add_argument("--gpu-timings", action="store_true")
    parser.add_argument("--validation", action="store_true")
    args = parser.parse_args()
    if args.repeats < 1 or args.timeout <= 0:
        parser.error("repeats and timeout must be positive")
    if args.build and args.binary:
        parser.error("--build and --binary are mutually exclusive")
    if args.output.exists():
        parser.error("output already exists; choose a new directory to preserve earlier runs")
    target = "cpu_bench" if args.suite == "cpu" else "many_lights"
    if args.build:
        subprocess.run([sys.executable, str(ROOT / "scripts/build.py"), "--target", target, "--opt", "O3"],
                       cwd=ROOT, check=True)
    binary = (args.binary or ROOT / "examples/build" / (target + (".exe" if os.name == "nt" else ""))).resolve()
    if not binary.is_file():
        parser.error(f"binary does not exist: {binary}")
    if args.cpu is not None:
        os.sched_setaffinity(0, {args.cpu})
    args.output.mkdir(parents=True)
    metadata = {
        "date_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "revision": capture(["git", "rev-parse", "HEAD"]).strip(),
        "changes": capture(["git", "diff", "--stat"]),
        "dependencies": capture(["git", "submodule", "status", "--recursive"]),
        "platform": platform.platform(),
        "cpu": capture(["lscpu"]) if sys.platform == "linux" else platform.processor(),
        "compiler": capture(["c3c", "--version"]),
        "build": "-O3" if args.build else "Existing binary; build flags must be recorded by caller",
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "options": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "driver_environment": {key: os.environ.get(key) for key in
                               ["VK_ICD_FILENAMES", "VK_DRIVER_FILES", "VK_LAYER_PATH", "VK_INSTANCE_LAYERS",
                                "GALLIVM_PERF", "LP_NUM_THREADS", "MESA_SHADER_CACHE_DISABLE"]},
    }
    if args.suite == "render":
        metadata["vulkan"] = capture(["vulkaninfo", "--summary"])
    (args.output / "environment.json").write_text(json.dumps(metadata, indent=2))
    jobs = []
    if args.suite == "cpu":
        for nodes in args.nodes:
            for case in args.cases:
                jobs.append((f"{case}-{nodes}", [case, str(nodes), str(args.iterations), str(args.samples)]))
    else:
        for lights in args.lights:
            for mode in args.modes:
                command = ["--benchmark", "--mode", mode, "--lights", str(lights), "--frames", str(args.frames),
                           "--warmup", str(args.warmup), "--width", str(args.width), "--height", str(args.height),
                           "--capacity", str(args.capacity), "--range", str(args.range)]
                command += [flag for flag, enabled in [("--gpu-timings", args.gpu_timings),
                                                        ("--validation", args.validation)] if enabled]
                jobs.append((f"{mode}-{lights}", command))
    summary = []
    for repeat in range(args.repeats):
        # Reverse alternating sweeps to reduce correlation between order and machine drift.
        for label, arguments in (jobs if repeat % 2 == 0 else list(reversed(jobs))):
            name = f"{label}-r{repeat}"
            command = [str(binary), *arguments]
            print(name, flush=True)
            (args.output / f"{name}.command.json").write_text(json.dumps(command))
            with (args.output / f"{name}.csv").open("w") as stdout, (args.output / f"{name}.log").open("w") as stderr:
                subprocess.run(command, cwd=ROOT, stdout=stdout, stderr=stderr, timeout=args.timeout, check=True)
            rows = list(csv.DictReader(io.StringIO((args.output / f"{name}.csv").read_text())))
            if not rows:
                raise RuntimeError(f"{name}: no samples")
            metrics = [key for key in rows[0] if key.endswith("_ms") or key == "us_per_iteration"]
            for metric in metrics:
                values = sorted(float(row[metric]) for row in rows)
                if values[0] < 0:
                    continue
                if not all(math.isfinite(value) for value in values):
                    raise RuntimeError(f"{name}: non-finite {metric}")
                summary.append({"case": label, "repeat": repeat, "metric": metric, "samples": len(values),
                                "median": statistics.median(values), "mean": statistics.mean(values),
                                "p95": values[math.ceil(0.95 * len(values)) - 1], "min": values[0], "max": values[-1]})
            with (args.output / "summary.csv").open("w", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=summary[0].keys())
                writer.writeheader()
                writer.writerows(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
