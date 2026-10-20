#!/usr/bin/env python3
"""Run the instrumented vegetation benchmark repeatedly and print per-stage CPU medians.

Measurement branch only. Usage, from the repository root:

    python scripts/measure_sway_stages.py --runs 3 --kind hardware
    python scripts/measure_sway_stages.py --runs 3 --kind software
    python scripts/measure_sway_stages.py --from-files out1.txt out2.txt out3.txt

Each run is `vegetation --benchmark N --shadows traced --trace-sway [--trace-software]`. Every
(run, segment) pair contributes one median per stage; the table reports the median of those and the
range of the per-run medians. net_ms subtracts the cost of the timers themselves, raw_ms does not.
Extra arguments after `--` go to the example, for example `-- --width 1280 --height 720`.
"""
import argparse
import os
import re
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(ROOT, "addons", "c3d_landscape.c3l")

STAGE_LINE = re.compile(
    r"^sway_stage segment=(\S+) stage=(\S+) raw_ms=(\S+) net_ms=(\S+) net_us_per_slot=(\S+) calls_median=(\S+)$"
)
CPU_LINE = re.compile(r"^cpu_record_ms segment=(\S+) median=(\S+)")
TRACE_LINE = re.compile(
    r"^trace segment=(\S+) posed_median=(\S+) poses_median=(\S+) refits_median=(\S+) blas_updates_median=(\S+)"
)
CLOCK_LINE = re.compile(r"^sway_clock segment=(\S+) pair_ns=(\S+) empty_ns=(\S+) tlas_rows_median=(\S+)")

# The five stages the plan names, as sums of leaf-level stages that do not overlap.
GROUPS = [
    ("1 pose recording (root builds, compare, write_pose_root)", ["pose_inputs", "pose_compare", "pose_write"]),
    ("2 pose bind and dispatch recording", ["pose_record"]),
    ("3 refit recording (write_refit_root, dispatch loop)", ["refit_root", "refit_record"]),
    ("4 build preparation (record_posed_builds loop)", ["build_loop"]),
    ("5 TLAS (record_top_level_build)", ["tlas"]),
]
DETAILS = [
    ("1a sway_pose_root, both calls", ["root_build_inputs", "root_build_write"]),
    ("1b update_pose compare", ["pose_compare"]),
    ("1c upload-ring take and write", ["pose_upload"]),
    ("4a cmd_update/cmd_build calls", ["build_cmd"]),
    ("4b of 4a: prepare_acceleration_structure_build (gpu patch)", ["gpu_prepare"]),
    ("4c of 4a: emit and vkCmd (gpu patch)", ["gpu_emit"]),
    ("5a TLAS row packing", ["tlas_pack"]),
    ("5b TLAS build call", ["tlas_cmd"]),
]
CONTEXT = [
    ("resolve_posed_instance, whole (per slot)", ["resolve"]),
    ("rows: resolve_trace_instances, whole", ["rows"]),
    ("collect_trace_instances", ["collect"]),
    ("top-level box BVH and trace rows", ["top_bvh"]),
    ("gather: record_scene_trace, whole", ["gather"]),
    ("prepare_scene_trace body, whole", ["trace_prepare"]),
]


def default_binary():
    return os.path.join(PACKAGE, "build", "vegetation.exe" if os.name == "nt" else "vegetation")


def run_once(binary, kind, frames, extra, multi_build):
    command = [binary, "--benchmark", str(frames), "--shadows", "traced", "--trace-sway"]
    if kind == "software":
        command.append("--trace-software")
    if multi_build:
        command.append("--measure-multi-build")
    command += extra
    result = subprocess.run(command, cwd=os.path.dirname(binary), capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"{command} failed: {result.stderr}")
    return result.stdout.splitlines()


def parse(lines):
    parsed = {"stage": {}, "cpu": {}, "trace": {}, "clock": {}}
    for line in lines:
        match = STAGE_LINE.match(line)
        if match:
            segment, stage = match.group(1), match.group(2)
            parsed["stage"][(segment, stage)] = tuple(float(match.group(index)) for index in range(3, 7))
            continue
        match = CPU_LINE.match(line)
        if match:
            parsed["cpu"][match.group(1)] = float(match.group(2))
            continue
        match = TRACE_LINE.match(line)
        if match:
            parsed["trace"][match.group(1)] = tuple(float(match.group(index)) for index in range(2, 6))
            continue
        match = CLOCK_LINE.match(line)
        if match:
            parsed["clock"][match.group(1)] = tuple(float(match.group(index)) for index in range(2, 5))
    return parsed


def stage_values(run, stages, column, segments):
    """Per-segment sums of the listed stages for one run."""
    return [sum(run["stage"][(segment, stage)][column] for stage in stages) for segment in segments]


def summarise(runs, segments, stages, column):
    per_run = [statistics.median(stage_values(run, stages, column, segments)) for run in runs]
    pooled = [value for run in runs for value in stage_values(run, stages, column, segments)]
    return statistics.median(pooled), min(per_run), max(per_run)


def report(kind, runs, segments):
    cpu_pooled = [run["cpu"][segment] for run in runs for segment in segments]
    cpu_per_run = [statistics.median([run["cpu"][segment] for segment in segments]) for run in runs]
    slots = statistics.median([run["trace"][segment][0] for run in runs for segment in segments])
    poses = statistics.median([run["trace"][segment][1] for run in runs for segment in segments])
    refits = statistics.median([run["trace"][segment][2] for run in runs for segment in segments])
    updates = statistics.median([run["trace"][segment][3] for run in runs for segment in segments])
    pair = statistics.median([run["clock"][segment][0] for run in runs for segment in segments])
    empty = statistics.median([run["clock"][segment][1] for run in runs for segment in segments])
    rows = statistics.median([run["clock"][segment][2] for run in runs for segment in segments])
    cpu_median = statistics.median(cpu_pooled)
    print(f"kind={kind} runs={len(runs)} segments={','.join(segments)}")
    print(
        f"posed={slots:.0f} poses={poses:.0f} refits={refits:.0f} blas_updates={updates:.0f} "
        f"tlas_rows={rows:.0f} timer_pair_ns={pair:.0f} timer_empty_ns={empty:.0f}"
    )
    print(
        f"cpu_record_ms median={cpu_median:.3f} per-run range {min(cpu_per_run):.3f}..{max(cpu_per_run):.3f}"
    )
    header = f"{'stage':62s} {'net ms':>8s} {'us/slot':>8s} {'run range ms':>15s} {'% cpu_record':>12s} {'calls':>7s}"
    for title, table in (("", GROUPS), ("detail", DETAILS), ("context (not one of the five stages)", CONTEXT)):
        print()
        if title:
            print(title)
        print(header)
        total_ms = 0.0
        total_slot = 0.0
        for name, stages in table:
            ms, low, high = summarise(runs, segments, stages, 1)
            per_slot, _, _ = summarise(runs, segments, stages, 2)
            calls, _, _ = summarise(runs, segments, stages, 3)
            share = ms / cpu_median * 100 if cpu_median else 0
            print(f"{name:62s} {ms:8.4f} {per_slot:8.4f} {low:7.4f}..{high:7.4f} {share:12.1f} {calls:7.0f}")
            if table is GROUPS:
                total_ms += ms
                total_slot += per_slot
        if table is GROUPS:
            print(f"{'sum of the five stages':62s} {total_ms:8.4f} {total_slot:8.4f} {'':15s} {total_ms / cpu_median * 100:12.1f}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--kind", choices=["hardware", "software"], default="hardware")
    parser.add_argument("--frames", type=int, default=300, help="frames per segment")
    parser.add_argument("--binary", default=default_binary())
    parser.add_argument("--from-files", nargs="+", default=None, help="saved benchmark outputs instead of running")
    parser.add_argument("--segments", nargs="+", default=["still", "spin", "gust", "walk", "far", "edit"])
    parser.add_argument("--multi-build", action="store_true", help="pass --measure-multi-build; needs the multi-build patch")
    parser.add_argument("extra", nargs="*")
    args = parser.parse_args()

    if args.from_files:
        outputs = [open(path).read().splitlines() for path in args.from_files]
    else:
        outputs = []
        for index in range(args.runs):
            outputs.append(run_once(args.binary, args.kind, args.frames, args.extra, args.multi_build))
            print(f"run {index + 1} done", file=sys.stderr)
    report(args.kind, [parse(lines) for lines in outputs], args.segments)


if __name__ == "__main__":
    main()
