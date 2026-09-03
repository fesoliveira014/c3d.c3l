#!/usr/bin/env python3
"""Generate the shared C3 and GLSL ABI from the schemas under abi/.

The generator itself is gpu.c3l's tools/gen_shader_abi, built on first use.

  scripts/gen_abi.py            regenerate the C3 and GLSL twins
  scripts/gen_abi.py --check    fail if the committed twins are out of date
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ABI = ROOT / "abi"
GENERATOR_DIR = ROOT / "lib" / "gpu.c3l" / "tools" / "gen_shader_abi"

MODULE = "c3d::shader"
C3_OUT = ROOT / "src" / "c3d" / "shader" / "abi.c3"
GLSL_OUT = ROOT / "shaders" / "generated" / "c3d_abi.glsl"

EXIT_FAILED = 1


def log(message: str) -> None:
    print(f"[gen_abi] {message}", flush=True)


def generator_binary() -> Path:
    build = GENERATOR_DIR / "build"
    windows = build / "gen_shader_abi.exe"
    return windows if windows.exists() else build / "gen_shader_abi"


def build_generator(c3c: str, verbose: bool) -> Path:
    binary = generator_binary()
    if binary.exists():
        return binary
    command = [c3c, "build", "gen_shader_abi", "--path", str(GENERATOR_DIR)]
    if verbose:
        log(f"$ {' '.join(command)}")
    subprocess.run(command, check=True, stdout=None if verbose else subprocess.DEVNULL)
    return generator_binary()


def generate(binary: Path, schemas: list[Path], check: bool, verbose: bool) -> None:
    C3_OUT.parent.mkdir(parents=True, exist_ok=True)
    GLSL_OUT.parent.mkdir(parents=True, exist_ok=True)
    command = [
        str(binary),
        "--module", MODULE,
        "--c3-out", str(C3_OUT),
        "--glsl-out", str(GLSL_OUT),
    ]
    if check:
        command.append("--check")
    command += [str(schema) for schema in schemas]
    if verbose:
        log(f"$ {' '.join(command)}")
    subprocess.run(command, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="c3d shader ABI generation")
    parser.add_argument("--check", action="store_true", help="verify the committed output instead of writing it")
    parser.add_argument("--c3c", default="c3c", help="c3c executable (default: c3c)")
    parser.add_argument("-v", "--verbose", action="store_true", help="print every command")
    arguments = parser.parse_args()

    schemas = sorted(ABI.glob("*.abi"))
    if not schemas:
        log("no schemas under abi/")
        return 0

    c3c = shutil.which(arguments.c3c)
    if c3c is None:
        log(f"'{arguments.c3c}' not found on PATH")
        return EXIT_FAILED

    try:
        binary = build_generator(c3c, arguments.verbose)
        generate(binary, schemas, arguments.check, arguments.verbose)
    except subprocess.CalledProcessError as error:
        log(f"generator failed ({error.returncode})")
        return EXIT_FAILED

    log(f"{'checked' if arguments.check else 'generated'} {len(schemas)} schema(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
