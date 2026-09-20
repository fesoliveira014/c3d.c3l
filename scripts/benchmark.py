#!/usr/bin/env python3
"""Run CPU, headless rendering or scene sweeps; retain raw samples and environment metadata.

  scripts/benchmark.py cpu --output results/cpu --repeats 3
  scripts/benchmark.py scene --output results/scene --build --features off
  scripts/benchmark.py render --output results/render --build --features internal --capture
  scripts/benchmark.py render --output results/x --dry-run --features full --panel

A run builds or locates one benchmark binary, checks its compiled profiling
features, writes environment.json, then runs every job as an independent
process for each repeat and summarizes the per-frame CSV into summary.csv.
"""

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
BUILD_SCRIPT = ROOT / "scripts/build.py"
EXAMPLES_BUILD = ROOT / "examples/build"
BENCH_BUILD = EXAMPLES_BUILD / "bench"
EXECUTABLE_SUFFIX = ".exe" if os.name == "nt" else ""

CPU_CASES = ["world", "hidden_world", "meshes", "culled_meshes", "hidden_meshes",
             "shadows", "lights", "hidden_lights", "sort"]
TARGETS = {"cpu": "cpu_bench", "render": "many_lights", "scene": "gltf_viewer"}
SCENE_MODEL = ROOT / "examples/assets/benchmark/sponza/glTF/Sponza.gltf"
FETCH_HINT = "fetch it with: python3 scripts/fetch_benchmark_assets.py"
FEATURES = {
    "off": [],
    "cpu": ["C3D_PROFILE_CPU"],
    "internal": ["C3D_PROFILE_CPU", "C3D_PROFILE_INTERNAL"],
    "gpu": ["C3D_PROFILE_GPU", "C3D_PROFILE_INTERNAL"],
    "gui": ["C3D_PROFILE_GUI", "C3D_PROFILE_CPU", "C3D_PROFILE_INTERNAL"],
    "full": ["C3D_PROFILE_GUI", "C3D_PROFILE_CPU", "C3D_PROFILE_GPU", "C3D_PROFILE_INTERNAL"],
}
FEATURE_BITS = {"cpu": "C3D_PROFILE_CPU", "gpu": "C3D_PROFILE_GPU",
                "internal": "C3D_PROFILE_INTERNAL", "gui": "C3D_PROFILE_GUI"}
DRIVER_ENVIRONMENT = ["VK_ICD_FILENAMES", "VK_DRIVER_FILES", "VK_LAYER_PATH", "VK_INSTANCE_LAYERS",
                      "GALLIVM_PERF", "LP_NUM_THREADS", "MESA_SHADER_CACHE_DISABLE"]
SUMMARY_FIELDS = ["case", "repeat", "metric", "samples", "median", "mean", "p95", "min", "max"]


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("suite", choices=sorted(TARGETS))
    parser.add_argument("--output", type=Path, required=True, help="new directory for raw samples and metadata")
    parser.add_argument("--binary", type=Path, help="run this binary instead of the default build output")
    parser.add_argument("--build", action="store_true", help="build the target with -O3 before running")
    parser.add_argument("--repeats", type=int, default=3, help="independent process sweeps per job")
    parser.add_argument("--timeout", type=float, default=180, help="seconds allowed per job process")
    parser.add_argument("--cpu", type=int, help="Linux CPU affinity; omitted by default")
    parser.add_argument("--dry-run", action="store_true", help="print the build and job commands, run nothing")

    cpu = parser.add_argument_group("cpu suite")
    cpu.add_argument("--nodes", type=int, nargs="+", default=[1024, 4096, 16384])
    cpu.add_argument("--cases", nargs="+", choices=CPU_CASES, default=CPU_CASES)
    cpu.add_argument("--iterations", type=int, default=100)
    cpu.add_argument("--samples", type=int, default=30)

    render = parser.add_argument_group("render and scene suites")
    render.add_argument("--lights", type=int, nargs="+", help="render default 64 256 1024 4096; scene default 16 64 256")
    render.add_argument("--modes", nargs="+", choices=["flat", "clustered"], default=["flat", "clustered"])
    render.add_argument("--frames", type=int, default=300)
    render.add_argument("--warmup", type=int, default=60)
    render.add_argument("--width", type=int, default=1440)
    render.add_argument("--height", type=int, default=900)
    render.add_argument("--capacity", type=int, default=64)
    render.add_argument("--range", type=float, help="light range: render default 6 units; scene default 0.08 of the extent")
    render.add_argument("--gpu-timings", action="store_true", help="enable renderer timestamps")
    render.add_argument("--validation", action="store_true", help="enable Vulkan validation")

    scene = parser.add_argument_group("scene suite")
    scene.add_argument("--model", type=Path, default=SCENE_MODEL, help="glTF file rendered by the scene suite")
    scene.add_argument("--shadows", choices=["on", "off"], default="on", help="shadowed sun in the scene suite")

    profiling = parser.add_argument_group("render and scene suite profiling")
    profiling.add_argument("--features", choices=sorted(FEATURES), default="off",
                           help="profiling configuration compiled into the binary")
    profiling.add_argument("--capture", action="store_true", help="open a profiler capture around every frame")
    profiling.add_argument("--window", action="store_true", help="present to a window instead of an offscreen target")
    profiling.add_argument("--panel", action="store_true", help="draw the profiler panel every frame; implies --window")

    args = parser.parse_args()
    if args.panel:
        args.window = True
    if args.lights is None:
        args.lights = [16, 64, 256] if args.suite == "scene" else [64, 256, 1024, 4096]
    if args.range is None:
        args.range = 0.08 if args.suite == "scene" else 6
    validate_arguments(parser, args)
    return args


def validate_arguments(parser, args):
    if args.repeats < 1 or args.timeout <= 0:
        parser.error("repeats and timeout must be positive")
    if args.build and args.binary:
        parser.error("--build and --binary are mutually exclusive")
    if args.suite == "cpu" and (args.features != "off" or args.capture or args.window or args.panel):
        parser.error("--features, --capture, --window and --panel apply to the render and scene suites")
    if args.suite == "scene" and not args.model.is_file():
        parser.error(f"scene model does not exist: {args.model}; {FETCH_HINT}")
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


class Plan:
    """Which binary runs, how it is built, and which profiling features it must carry."""

    def __init__(self, args):
        self.target = TARGETS[args.suite]
        self.defines = FEATURES[args.features] if args.suite != "cpu" else []
        self.libraries = libraries_for(self.defines)
        self.built = EXAMPLES_BUILD / (self.target + EXECUTABLE_SUFFIX)
        if args.binary:
            self.binary = args.binary.resolve()
        elif args.suite != "cpu" and args.build:
            self.binary = BENCH_BUILD / f"{self.target}-{args.features}{EXECUTABLE_SUFFIX}"
        else:
            self.binary = self.built
        self.build_command = None
        if args.build:
            self.build_command = [sys.executable, str(BUILD_SCRIPT), "--target", self.target, "--opt", "O3"]
            for define in self.defines:
                self.build_command += ["--define", define]
            for library in self.libraries:
                self.build_command += ["--lib", library]

    def build(self):
        subprocess.run(self.build_command, cwd=ROOT, check=True)
        if self.binary != self.built:
            self.binary.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.built, self.binary)

    def expected_features(self):
        return {bit: define in self.defines for bit, define in FEATURE_BITS.items()}

    def describe(self):
        return {"build": self.build_command, "binary": str(self.binary),
                "defines": self.defines, "libraries": self.libraries}


def libraries_for(defines):
    libraries = []
    if "C3D_PROFILE_GUI" in defines:
        libraries.append("c3d_profile_gui")
    if defines:
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


def environment_metadata(args, plan, features_reported):
    metadata = {
        "date_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "revision": capture(["git", "rev-parse", "HEAD"]).strip(),
        "changes": capture(["git", "diff", "--stat"]),
        "dependencies": capture(["git", "submodule", "status", "--recursive"]),
        "platform": platform.platform(),
        "cpu": capture(["lscpu"]) if sys.platform == "linux" else platform.processor(),
        "compiler": capture(["c3c", "--version"]),
        "build": "-O3" if args.build else "Existing binary; build flags must be recorded by caller",
        "features": args.features if args.suite != "cpu" else None,
        "defines": plan.defines,
        "libraries": plan.libraries,
        "features_reported": features_reported,
        "binary_sha256": hashlib.sha256(plan.binary.read_bytes()).hexdigest(),
        "options": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
        "driver_environment": {key: os.environ.get(key) for key in DRIVER_ENVIRONMENT},
    }
    if args.suite != "cpu":
        metadata["vulkan"] = capture(["vulkaninfo", "--summary"])
    return metadata


def cpu_jobs(args):
    return [(f"{case}-{nodes}", [case, str(nodes), str(args.iterations), str(args.samples)])
            for nodes in args.nodes for case in args.cases]


def common_switches(args):
    return [flag for flag, enabled in [("--gpu-timings", args.gpu_timings),
                                        ("--validation", args.validation),
                                        ("--capture", args.capture),
                                        ("--window", args.window),
                                        ("--panel", args.panel)] if enabled]


def workload_arguments(args, mode, lights):
    return ["--benchmark", "--mode", mode, "--lights", str(lights), "--frames", str(args.frames),
            "--warmup", str(args.warmup), "--width", str(args.width), "--height", str(args.height),
            "--capacity", str(args.capacity), "--range", str(args.range), *common_switches(args)]


def render_jobs(args):
    return [(f"{mode}-{lights}", workload_arguments(args, mode, lights))
            for lights in args.lights for mode in args.modes]


def scene_jobs(args):
    return [(f"{mode}-{lights}-shadows-{args.shadows}",
             [str(args.model.resolve()), "--shadows", args.shadows, *workload_arguments(args, mode, lights)])
            for lights in args.lights for mode in args.modes]


def run_job(output, name, command, timeout):
    """Run one job process, keeping its command, CSV and stderr; return the CSV rows."""
    (output / f"{name}.command.json").write_text(json.dumps(command))
    with (output / f"{name}.csv").open("w") as stdout, (output / f"{name}.log").open("w") as stderr:
        subprocess.run(command, cwd=ROOT, stdout=stdout, stderr=stderr, timeout=timeout, check=True)
    rows = list(csv.DictReader(io.StringIO((output / f"{name}.csv").read_text())))
    if not rows:
        raise RuntimeError(f"{name}: no samples")
    return rows


def summarize(label, repeat, rows):
    """One summary row per timing metric; negative columns mean unavailable and are skipped."""
    summary = []
    metrics = [key for key in rows[0] if key.endswith("_ms") or key == "us_per_iteration"]
    for metric in metrics:
        values = sorted(float(row[metric]) for row in rows)
        if values[0] < 0:
            continue
        if not all(math.isfinite(value) for value in values):
            raise RuntimeError(f"{label}-r{repeat}: non-finite {metric}")
        summary.append({"case": label, "repeat": repeat, "metric": metric, "samples": len(values),
                        "median": statistics.median(values), "mean": statistics.mean(values),
                        "p95": values[math.ceil(0.95 * len(values)) - 1], "min": values[0], "max": values[-1]})
    return summary


def write_summary(output, summary):
    with (output / "summary.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=SUMMARY_FIELDS)
        writer.writeheader()
        writer.writerows(summary)


def main():
    args = parse_arguments()
    plan = Plan(args)
    jobs = {"cpu": cpu_jobs, "render": render_jobs, "scene": scene_jobs}[args.suite](args)

    if args.dry_run:
        print(json.dumps(plan.describe()))
        for label, arguments in jobs:
            print(json.dumps({"job": label, "command": [str(plan.binary), *arguments]}))
        return 0

    if plan.build_command:
        plan.build()
    if not plan.binary.is_file():
        raise SystemExit(f"binary does not exist: {plan.binary}")
    features_reported = None
    if args.suite != "cpu":
        features_reported = reported_features(plan.binary)
        if features_reported != plan.expected_features():
            raise SystemExit(f"binary reports {features_reported}, requested {plan.expected_features()}")

    if args.cpu is not None:
        os.sched_setaffinity(0, {args.cpu})
    args.output.mkdir(parents=True)
    (args.output / "environment.json").write_text(json.dumps(environment_metadata(args, plan, features_reported), indent=2))

    summary = []
    for repeat in range(args.repeats):
        # Reverse alternating sweeps to reduce correlation between order and machine drift.
        ordered = jobs if repeat % 2 == 0 else list(reversed(jobs))
        for label, arguments in ordered:
            name = f"{label}-r{repeat}"
            print(name, flush=True)
            rows = run_job(args.output, name, [str(plan.binary), *arguments], args.timeout)
            summary += summarize(label, repeat, rows)
            write_summary(args.output, summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
