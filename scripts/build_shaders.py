#!/usr/bin/env python3
"""Compile the GLSL sources under shaders/ to SPIR-V in shaders/spv/.

Stage files are named <name>.<stage>.glsl. Files under shaders/common/ are
shared includes and are never compiled on their own.

  scripts/build_shaders.py            compile every stage file
  scripts/build_shaders.py --check    fail if the committed SPIR-V is out of date
"""

from __future__ import annotations

import argparse
import filecmp
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHADERS = ROOT / "shaders"
GENERATED = SHADERS / "generated"
SPIRV = SHADERS / "spv"
COMMON = SHADERS / "common"
GPU_INCLUDE = ROOT / "lib" / "gpu.c3l" / "include" / "shaders"

TARGET_ENV = "vulkan1.3"
STAGES = (
    "vert", "frag", "comp", "geom", "tesc", "tese",
    "rgen", "rmiss", "rchit", "rahit", "rint", "rcall",
    "task", "mesh",
)

EXIT_FAILED = 1


def log(message: str) -> None:
    print(f"[shaders] {message}", flush=True)


def stage_sources() -> list[Path]:
    sources = []
    for source in sorted(SHADERS.rglob("*.glsl")):
        if COMMON in source.parents or GENERATED in source.parents or SPIRV in source.parents:
            continue
        if source.suffixes[-2:-1] and source.suffixes[-2][1:] in STAGES:
            sources.append(source)
    return sources


def output_for(source: Path, directory: Path) -> Path:
    return directory / (source.name[: -len(".glsl")] + ".spv")


def compile_one(glslang: str, source: Path, output: Path, verbose: bool) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        glslang,
        "-V",
        "--target-env", TARGET_ENV,
        "-I" + str(COMMON),
        "-I" + str(GPU_INCLUDE),
        "-o", str(output),
        str(source),
    ]
    if verbose:
        log(f"$ {' '.join(command)}")
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)


def main() -> int:
    parser = argparse.ArgumentParser(description="c3d shader compilation")
    parser.add_argument("--glslang", default="glslangValidator", help="glslang executable")
    parser.add_argument("--check", action="store_true", help="verify the committed SPIR-V instead of writing it")
    parser.add_argument("--verbose", action="store_true", help="print every command")
    arguments = parser.parse_args()

    sources = stage_sources()
    if not sources:
        log("no shaders under shaders/")
        return 0

    glslang = shutil.which(arguments.glslang)
    if glslang is None:
        log(f"'{arguments.glslang}' not found on PATH")
        return EXIT_FAILED

    try:
        if arguments.check:
            with tempfile.TemporaryDirectory() as scratch:
                stale = []
                for source in sources:
                    fresh = output_for(source, Path(scratch))
                    compile_one(glslang, source, fresh, arguments.verbose)
                    committed = output_for(source, SPIRV)
                    if not committed.exists() or not filecmp.cmp(fresh, committed, shallow=False):
                        stale.append(source.relative_to(ROOT))
                if stale:
                    log("stale SPIR-V:\n  " + "\n  ".join(str(path) for path in stale))
                    return EXIT_FAILED
        else:
            for source in sources:
                compile_one(glslang, source, output_for(source, SPIRV), arguments.verbose)
    except subprocess.CalledProcessError as error:
        log(f"glslang failed ({error.returncode})")
        return EXIT_FAILED

    log(f"{'checked' if arguments.check else 'compiled'} {len(sources)} shader(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
