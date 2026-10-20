#!/usr/bin/env python3
"""Run the instrumented cloth example repeatedly and print per-stage medians.

Measurement branch only. Usage, from the repository root:

    python scripts/measure_cloth_stages.py --runs 5 --scenes cape flag crowd
    python scripts/measure_cloth_stages.py --runs 5 --scenes cape --baseline path/to/unmodified/cloth

The example is run from addons/c3d_physics.c3l because its model path is relative.
--baseline interleaves an unmodified build to estimate the timer overhead on solve_ms.
"""
import argparse
import collections
import os
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(ROOT, "addons", "c3d_physics.c3l")


def default_binary():
    name = "cloth.exe" if os.name == "nt" else "cloth"
    return os.path.join(PACKAGE, "build", name)


def run_once(binary, scene):
    started = time.time()
    result = subprocess.run(
        [binary, "--benchmark", "--cpu-only", "--scene", scene],
        cwd=PACKAGE,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"{binary} failed for scene {scene}: {result.stderr}")
    return result.stdout.splitlines(), time.time() - started


def solve_mean(lines):
    for line in lines:
        if line.startswith("solve_ms,mean"):
            return float(line.split(",")[2])
    sys.exit("no solve_ms line")


def parse_pairs(fields):
    return dict(zip(fields[0::2], [float(value) for value in fields[1::2]]))


def parse_measure(lines):
    parsed = {"stage": collections.OrderedDict(), "contact": collections.OrderedDict(), "path": collections.OrderedDict(), "single": {}}
    for line in lines:
        if not line.startswith("measure|"):
            continue
        fields = line.split("|")
        kind = fields[1]
        if kind == "stage":
            parsed["stage"][fields[2]] = [float(value) for value in fields[3:]]
        elif kind in ("contact", "path"):
            parsed[kind][fields[2]] = parse_pairs(fields[3:])
        elif kind == "counts":
            parsed["single"].update(parse_pairs(fields[2:]))
        elif kind in ("clock_pair_ns", "query_bounds_ns", "frames"):
            parsed["single"][kind] = float(fields[2])
        elif kind == "solve_stat_ms":
            parsed["single"].update({"solve_stat_ms": float(fields[2]), "solve_timer_ms": float(fields[4]), "publish_stat_ms": float(fields[6])})
    return parsed


def median_of(values):
    return statistics.median(values)


def report(scene, timed_runs, baseline_solve):
    solves = [solve_mean(lines) for lines in timed_runs]
    print(f"scene {scene}: {len(timed_runs)} timed runs")
    print("  solve_ms mean per run (timed):", [round(value, 2) for value in solves], "median", round(median_of(solves), 3))
    if baseline_solve:
        print("  solve_ms mean per run (baseline):", [round(value, 2) for value in baseline_solve], "median", round(median_of(baseline_solve), 3))
    parsed = [parse_measure(lines) for lines in timed_runs]
    singles = parsed[0]["single"].keys()
    print("  " + "  ".join(f"{key}={median_of([run['single'][key] for run in parsed]):.4g}" for key in singles))
    print(f"  {'stage':44s} {'ms/frame':>9s} {'share%':>7s} {'calls/frame':>12s} {'timer ms':>9s}")
    for name in parsed[0]["stage"]:
        columns = [median_of([run["stage"][name][index] for run in parsed]) for index in range(4)]
        print(f"  {name:44s} {columns[0]:9.4f} {columns[1]:7.2f} {columns[2]:12.1f} {columns[3]:9.4f}")
    for kind in ("contact", "path"):
        for name in parsed[0][kind]:
            keys = parsed[0][kind][name].keys()
            print(f"  {kind} {name}: " + "  ".join(f"{key}={median_of([run[kind][name][key] for run in parsed]):.4g}" for key in keys))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--scenes", nargs="+", default=["cape", "flag", "crowd"])
    parser.add_argument("--binary", default=default_binary())
    parser.add_argument("--baseline", default=None)
    args = parser.parse_args()

    for scene in args.scenes:
        timed_runs = []
        baseline_solve = []
        for index in range(args.runs):
            lines, elapsed = run_once(args.binary, scene)
            timed_runs.append(lines)
            print(f"{scene} timed run {index}: {elapsed:.1f} s", file=sys.stderr)
            if args.baseline:
                baseline_lines, elapsed = run_once(args.baseline, scene)
                baseline_solve.append(solve_mean(baseline_lines))
                print(f"{scene} baseline run {index}: {elapsed:.1f} s", file=sys.stderr)
        report(scene, timed_runs, baseline_solve)
        print()


if __name__ == "__main__":
    main()
