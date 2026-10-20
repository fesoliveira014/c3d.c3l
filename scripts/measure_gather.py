#!/usr/bin/env python3
"""Run the instrumented vegetation benchmark and print the trace gather split. Measurement branch only.

Build the example with the timers, from the repository root:

    python3 scripts/build.py --skip-abi --skip-shaders --target vegetation --opt O3 \
        --define MEASURE_GATHER --define MEASURE_GATHER_ROWS

MEASURE_GATHER alone times the passes and functions; MEASURE_GATHER_ROWS adds the per-row timers. Run the
row build for the split and the pass build to check that the per-row timers do not move the pass totals.

Usage:

    python3 scripts/measure_gather.py --runs 3                      # both kinds, alternated
    python3 scripts/measure_gather.py --runs 3 --kinds software     # one kind
    python3 scripts/measure_gather.py --from-files a.txt b.txt c.txt

Each run is `vegetation --benchmark N --shadows traced --trace-sway [--trace-software]`, executed in the
binary's directory. Stage times are net: the cost of the timers is subtracted by the binary. Medians pool one
value per (run, segment); means are over the pooled (run, segment) means and add up across a parent's children.
Extra arguments after `--` go to the example, for example `-- --width 640 --height 360`.
"""
import argparse
import os
import re
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(ROOT, "addons", "c3d_landscape.c3l")

HEADER = re.compile(r"^# vegetation .*trace_kind=(\S+)")
CLOCK = re.compile(r"^gather_clock segment=(\S+) pair_ns=(\S+) empty_ns=(\S+)")
STAGE = re.compile(
    r"^gather_stage segment=(\S+) stage=(\S+) parent=(\S+) raw_ms=(\S+) net_ms=(\S+) raw_mean_ms=(\S+) "
    r"net_mean_ms=(\S+) calls_median=(\S+) calls_mean=(\S+)$"
)
COUNTER = re.compile(r"^gather_counter segment=(\S+) name=(\S+) median=(\S+) mean=(\S+) max=(\S+) sum=(\S+)$")
ROWS = re.compile(r"^gather_rows segment=(\S+) pose=(\S+) median=(\S+) max=(\S+)$")
CPU = re.compile(r"^cpu_record_ms segment=(\S+) median=(\S+)")
SEGMENTS = ["still", "spin", "gust", "walk", "far", "edit"]

# Stages that exist only to take the measurement; the parent's remainder does not count them as unexplained.
MEASUREMENT_ONLY = {"IDENTITY_CHECK"}

COUNTER_ROWS = [
    "ROWS_KEPT",
    "RECORD_CAPACITY",
    "CLAIM_HITS",
    "CLAIM_MISSES",
    "CLAIM_OVERFLOWS",
    "SLOT_VISITS_MISS",
    "SLOT_VISITS_OVERFLOW",
    "WRITE_TOP_LEVEL_CALLS",
    "TLAS_BUILDS",
]
IDENTITY_COLUMNS = [
    "WRITE_TOP_LEVEL_CALLS",
    "SWAY_ONLY_WRITES",
    "SWAY_ONLY_SERIAL_ROWS",
    "SWAY_ONLY_BOXES_SAME",
    "SWAY_ONLY_ROWS_SAME",
    "SWAY_ONLY_BOXES_DIFFER",
    "SWAY_ONLY_ROWS_DIFFER",
    "BOUNDS_WRITES",
    "BOUNDS_BOXES_DIFFER",
    "BOUNDS_ROWS_DIFFER",
    "OTHER_WRITES",
    "NEW_SET_WRITES",
]


def default_binary():
    return os.path.join(PACKAGE, "build", "vegetation.exe" if os.name == "nt" else "vegetation")


def run_once(binary, kind, frames, extra):
    command = [binary, "--benchmark", str(frames), "--shadows", "traced", "--trace-sway"]
    if kind == "software":
        command.append("--trace-software")
    command += extra
    result = subprocess.run(command, cwd=os.path.dirname(binary), capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"{command} failed: {result.stderr}")
    return result.stdout.splitlines()


def parse(lines):
    run = {"kind": "?", "clock": {}, "stage": {}, "parent": {}, "counter": {}, "rows": {}, "cpu": {}, "order": []}
    for line in lines:
        match = HEADER.match(line)
        if match:
            run["kind"] = match.group(1)
            continue
        match = CLOCK.match(line)
        if match:
            run["clock"][match.group(1)] = (float(match.group(2)), float(match.group(3)))
            continue
        match = STAGE.match(line)
        if match:
            segment, stage, parent = match.group(1), match.group(2), match.group(3)
            run["stage"][(segment, stage)] = tuple(float(match.group(index)) for index in range(4, 10))
            run["parent"][stage] = parent
            if stage not in run["order"]:
                run["order"].append(stage)
            continue
        match = COUNTER.match(line)
        if match:
            run["counter"][(match.group(1), match.group(2))] = tuple(float(match.group(index)) for index in range(3, 7))
            continue
        match = ROWS.match(line)
        if match:
            run["rows"][(match.group(1), match.group(2))] = (float(match.group(3)), float(match.group(4)))
            continue
        match = CPU.match(line)
        if match:
            run["cpu"][match.group(1)] = float(match.group(2))
    return run


# Columns of a stage tuple.
RAW_MEDIAN, NET_MEDIAN, RAW_MEAN, NET_MEAN, CALLS_MEDIAN, CALLS_MEAN = range(6)


def pooled(runs, segments, stage, column):
    return [run["stage"][(segment, stage)][column] for run in runs for segment in segments if (segment, stage) in run["stage"]]


def pooled_median(runs, segments, stage, column):
    values = pooled(runs, segments, stage, column)
    return statistics.median(values) if values else 0.0


def pooled_mean(runs, segments, stage, column):
    values = pooled(runs, segments, stage, column)
    return statistics.fmean(values) if values else 0.0


def run_medians(runs, segments, stage, column):
    return [
        statistics.median([run["stage"][(segment, stage)][column] for segment in segments])
        for run in runs
    ]


def counter_value(runs, segments, name, column):
    values = [run["counter"][(segment, name)][column] for run in runs for segment in segments]
    return statistics.median(values) if values else 0.0


def report(kind, runs, segments):
    stages = runs[0]["order"]
    parent = runs[0]["parent"]
    children = {}
    for stage in stages:
        if parent[stage] != stage:
            children.setdefault(parent[stage], []).append(stage)

    pair = statistics.median([run["clock"][segment][0] for run in runs for segment in segments])
    empty = statistics.median([run["clock"][segment][1] for run in runs for segment in segments])
    cpu = [run["cpu"][segment] for run in runs for segment in segments]
    print(f"kind={kind} runs={len(runs)} segments={','.join(segments)}")
    print(f"timer_pair_ns={pair:.0f} timer_empty_ns={empty:.0f} cpu_record_ms median={statistics.median(cpu):.3f}")

    gather_mean = pooled_mean(runs, segments, "GATHER", NET_MEAN)
    rows = pooled_median(runs, segments, "RESOLVE_CLASSIFY", CALLS_MEDIAN) or counter_value(runs, segments, "ROWS_KEPT", 0)

    print()
    print("stage table (net of timer cost)")
    header = f"{'stage':26s} {'parent':22s} {'median ms':>9s} {'mean ms':>8s} {'run range ms':>15s} {'% gather':>8s} {'calls':>7s} {'ns/row':>8s}"
    print(header)
    for stage in stages:
        if stage == "CALIBRATION":
            continue
        median = pooled_median(runs, segments, stage, NET_MEDIAN)
        mean = pooled_mean(runs, segments, stage, NET_MEAN)
        per_run = run_medians(runs, segments, stage, NET_MEDIAN)
        calls = pooled_median(runs, segments, stage, CALLS_MEDIAN)
        share = mean / gather_mean * 100 if gather_mean else 0
        per_row = median * 1e6 / rows if rows else 0
        print(
            f"{stage:26s} {parent[stage]:22s} {median:9.4f} {mean:8.4f} {min(per_run):7.4f}..{max(per_run):7.4f} "
            f"{share:8.1f} {calls:7.0f} {per_row:8.1f}"
        )

    print()
    print("parent check, means: parent net against the sum of its children's net")
    print(f"{'parent':22s} {'net ms':>8s} {'children ms':>11s} {'remainder ms':>12s} {'remainder %':>11s}")
    for name in stages:
        kids = [stage for stage in children.get(name, []) if stage != "CALIBRATION"]
        if not kids or name == "CALIBRATION":
            continue
        net = pooled_mean(runs, segments, name, NET_MEAN)
        explained = sum(pooled_mean(runs, segments, stage, NET_MEAN) for stage in kids)
        remainder = net - explained
        share = remainder / net * 100 if net else 0
        print(f"{name:22s} {net:8.4f} {explained:11.4f} {remainder:12.4f} {share:11.1f}")
    gather_net = pooled_mean(runs, segments, "GATHER", NET_MEAN)
    identity = pooled_mean(runs, segments, "IDENTITY_CHECK", NET_MEAN)
    print(f"GATHER net without the identity check: {gather_net - identity:.4f} ms")

    print()
    print("counters per frame (median over runs and segments)")
    for name in COUNTER_ROWS:
        print(f"{name:26s} {counter_value(runs, segments, name, 0):12.0f}")
    visits = counter_value(runs, segments, "SLOT_VISITS_MISS", 0) + counter_value(runs, segments, "SLOT_VISITS_OVERFLOW", 0)
    print(f"{'SLOT_VISITS total':26s} {visits:12.0f}")
    for pose in ["rest", "mesh", "crowd", "animated_lod", "vertex_motion", "custom", "sway"]:
        values = [run["rows"][(segment, pose)][0] for run in runs for segment in segments]
        print(f"rows[{pose}]".ljust(26) + f" {statistics.median(values):12.0f}")

    print()
    print("per segment, mean net ms of the stages the levers act on")
    keys = ["GATHER", "COLLECT", "RESOLVE", "RESOLVE_CLAIM_OVERFLOW", "RESOLVE_CLOSE", "COMPARE_ROWS", "WRITE_TOP_LEVEL", "WRITE_TOP_BVH", "TLAS_PACK"]
    print(f"{'segment':8s} " + " ".join(f"{key[:14]:>14s}" for key in keys))
    for segment in segments:
        cells = [pooled_mean(runs, [segment], key, NET_MEAN) for key in keys]
        print(f"{segment:8s} " + " ".join(f"{cell:14.4f}" for cell in cells))

    print()
    print("writes by what differs from the baseline, and their identity with the previous write; sums over runs and frames")
    print("S_ = records differ in pose_serial alone; BOUNDS_ = in pose_serial and bounds alone; OTHER_ = anything else")
    print(f"{'segment':8s} " + " ".join(f"{column.replace('SWAY_ONLY_', 'S_').replace('WRITE_TOP_LEVEL_CALLS', 'WRITES')[:15]:>15s}" for column in IDENTITY_COLUMNS))
    for segment in segments:
        sums = [sum(run["counter"][(segment, column)][3] for run in runs) for column in IDENTITY_COLUMNS]
        print(f"{segment:8s} " + " ".join(f"{value:15.0f}" for value in sums))
    totals = [sum(run["counter"][(segment, column)][3] for run in runs for segment in segments) for column in IDENTITY_COLUMNS]
    print(f"{'all':8s} " + " ".join(f"{value:15.0f}" for value in totals))
    only = totals[IDENTITY_COLUMNS.index("SWAY_ONLY_WRITES")]
    if only:
        boxes = totals[IDENTITY_COLUMNS.index("SWAY_ONLY_BOXES_SAME")]
        rows_same = totals[IDENTITY_COLUMNS.index("SWAY_ONLY_ROWS_SAME")]
        print(f"sway-only writes: {only:.0f}; boxes identical in {boxes:.0f}; TraceInstanceGpu rows identical in {rows_same:.0f}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--kinds", nargs="+", choices=["hardware", "software"], default=["hardware", "software"])
    parser.add_argument("--frames", type=int, default=300, help="frames per segment")
    parser.add_argument("--binary", default=default_binary())
    parser.add_argument("--from-files", nargs="+", default=None, help="saved benchmark outputs instead of running")
    parser.add_argument("--save", default=None, help="prefix for the raw outputs of the runs")
    parser.add_argument("--segments", nargs="+", default=SEGMENTS)
    parser.add_argument("extra", nargs="*")
    args = parser.parse_args()

    outputs = []
    if args.from_files:
        outputs = [open(path).read().splitlines() for path in args.from_files]
    else:
        for index in range(args.runs):
            for kind in args.kinds:
                lines = run_once(args.binary, kind, args.frames, args.extra)
                outputs.append(lines)
                if args.save:
                    with open(f"{args.save}{kind}-{index + 1}.txt", "w") as handle:
                        handle.write("\n".join(lines) + "\n")
                print(f"run {index + 1} {kind} done", file=sys.stderr)

    runs = [parse(lines) for lines in outputs]
    for kind in sorted({run["kind"] for run in runs}):
        report(kind, [run for run in runs if run["kind"] == kind], args.segments)
        print()


if __name__ == "__main__":
    main()
