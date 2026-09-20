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
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
CPU_CASES = ["world", "hidden_world", "meshes", "culled_meshes", "hidden_meshes",
             "shadows", "lights", "hidden_lights", "sort"]
FEATURES = {
    "off": [],
    "cpu": ["C3D_PROFILE_CPU"],
    "internal": ["C3D_PROFILE_CPU", "C3D_PROFILE_INTERNAL"],
    "gpu": ["C3D_PROFILE_GPU", "C3D_PROFILE_INTERNAL"],
    "gui": ["C3D_PROFILE_GUI", "C3D_PROFILE_CPU", "C3D_PROFILE_INTERNAL"],
    "full": ["C3D_PROFILE_GUI", "C3D_PROFILE_CPU", "C3D_PROFILE_GPU", "C3D_PROFILE_INTERNAL"],
}
FEATURE_BITS = ("cpu", "gpu", "internal", "gui")


def libraries_for(features):
    libraries = []
    if "C3D_PROFILE_GUI" in features:
        libraries.append("c3d_profile_gui")
    if features:
        libraries.append("c3d_profile")
    return libraries


def reported_features(binary):
    """Parse the binary's --print-features line into {bit: bool}."""
    result = subprocess.run([str(binary), "--print-features"], cwd=ROOT, text=True, capture_output=True, timeout=30)
    if result.returncode != 0:
        raise RuntimeError(f"--print-features failed: {result.stderr.strip()}")
    reported = {}
    for token in result.stdout.split():
        name, _, value = token.partition("=")
        reported[name] = value == "1"
    missing = [bit for bit in FEATURE_BITS if bit not in reported]
    if missing:
        raise RuntimeError(f"--print-features did not report {missing}: {result.stdout.strip()}")
    return reported


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
    parser.add_argument("--features", choices=sorted(FEATURES), default="off",
                        help="profiling configuration compiled into the render binary")
    parser.add_argument("--capture", action="store_true", help="open a profiler capture around every frame")
    parser.add_argument("--window", action="store_true", help="present to a window instead of an offscreen target")
    parser.add_argument("--panel", action="store_true", help="draw the profiler panel every frame; implies --window")
    parser.add_argument("--dry-run", action="store_true", help="print the build and job commands, run nothing")
    args = parser.parse_args()
    if args.repeats < 1 or args.timeout <= 0:
        parser.error("repeats and timeout must be positive")
    if args.build and args.binary:
        parser.error("--build and --binary are mutually exclusive")
    if args.suite == "cpu" and (args.features != "off" or args.capture or args.window or args.panel):
        parser.error("--features, --capture, --window and --panel apply to the render suite")
    if args.panel:
        args.window = True
    if args.capture and args.features == "off":
        parser.error("--capture needs a profiling configuration; pass --features cpu, internal, gpu, gui or full")
    if args.panel and args.features not in ("gui", "full"):
        parser.error("--panel needs --features gui or full")
    if args.panel and not args.capture:
        parser.error("--panel needs --capture")
    if args.features != "off" and not args.build and not args.binary:
        parser.error("a profiling configuration needs --build or --binary so the binary is known to carry it")
    if not args.dry_run and args.output.exists():
        parser.error("output already exists; choose a new directory to preserve earlier runs")
    target = "cpu_bench" if args.suite == "cpu" else "many_lights"
    defines = FEATURES[args.features] if args.suite == "render" else []
    libraries = libraries_for(defines)
    executable = target + (".exe" if os.name == "nt" else "")
    build_command = None
    if args.build:
        build_command = [sys.executable, str(ROOT / "scripts/build.py"), "--target", target, "--opt", "O3"]
        for define in defines:
            build_command += ["--define", define]
        for library in libraries:
            build_command += ["--lib", library]
    built = ROOT / "examples/build" / executable
    if args.binary:
        binary = args.binary.resolve()
    elif args.suite == "render" and args.build:
        binary = ROOT / "examples/build/bench" / f"{target}-{args.features}{'.exe' if os.name == 'nt' else ''}"
    else:
        binary = built
    if args.dry_run:
        print(json.dumps({"build": build_command, "binary": str(binary), "defines": defines, "libraries": libraries}))
    elif build_command:
        subprocess.run(build_command, cwd=ROOT, check=True)
        if binary != built:
            binary.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(built, binary)
    if not args.dry_run and not binary.is_file():
        parser.error(f"binary does not exist: {binary}")
    features_reported = None
    if args.suite == "render" and not args.dry_run:
        features_reported = reported_features(binary)
        expected = {bit: any(bit.upper() in define for define in defines) for bit in FEATURE_BITS}
        if features_reported != expected:
            raise RuntimeError(f"binary reports {features_reported}, requested {expected}")
    if args.cpu is not None and not args.dry_run:
        os.sched_setaffinity(0, {args.cpu})
    if not args.dry_run:
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
        "features": args.features if args.suite == "render" else None,
        "defines": defines,
        "libraries": libraries,
        "features_reported": features_reported,
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest() if not args.dry_run else None,
        "options": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "driver_environment": {key: os.environ.get(key) for key in
                               ["VK_ICD_FILENAMES", "VK_DRIVER_FILES", "VK_LAYER_PATH", "VK_INSTANCE_LAYERS",
                                "GALLIVM_PERF", "LP_NUM_THREADS", "MESA_SHADER_CACHE_DISABLE"]},
    }
    if args.suite == "render" and not args.dry_run:
        metadata["vulkan"] = capture(["vulkaninfo", "--summary"])
    if not args.dry_run:
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
                                                        ("--validation", args.validation),
                                                        ("--capture", args.capture),
                                                        ("--window", args.window),
                                                        ("--panel", args.panel)] if enabled]
                jobs.append((f"{mode}-{lights}", command))
    if args.dry_run:
        for label, arguments in jobs:
            print(json.dumps({"job": label, "command": [str(binary), *arguments]}))
        return 0
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
