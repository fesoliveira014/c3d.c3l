#!/usr/bin/env python3
"""Build orchestration for c3d.

Steps, in order: tools, deps, abi, shaders, build, test, run.
Each step is a function; failures raise BuildError and stop the run.

  scripts/build.py                  regenerate ABI and shaders, build all example targets
  scripts/build.py --test           same, then run every test target
  scripts/build.py --check --test   CI: verify generated files are current, build, test
  scripts/build.py --example cube   build and run one example
  scripts/build.py --init-deps      initialize submodules and build native dependencies
  scripts/build.py --clean          remove c3c build directories
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
LIB = ROOT / "lib"
EXAMPLES = ROOT / "examples"
TEST = ROOT / "test"

REQUIRED_C3C_VERSION = "0.8.3"
SUBMODULES = ("gpu.c3l", "sdl3.c3l", "c3imgui.c3l", "c3cg.c3l", "box3d.c3l")
NATIVE_BUILD_SCRIPTS = ("scripts/build-box3d.sh",)

# Import boundaries from AGENTS.md section 10: module import -> directories allowed to import it.
IMPORT_BOUNDARIES = {
    "gpu": ("render", "shader", "post", "rt", "gui"),
    "sdl": ("platform",),
    "imgui": ("gui",),
    "cg": ("geometry",),
    "b3": ("physics",),
}

# Directories allowed one named submodule of a boundary module but not the module itself:
# c3d::platform bridges an SDL window to a gpu surface and touches nothing else in gpu.
SUBMODULE_BOUNDARIES = {
    "gpu": {"platform": "surface"},
}

EXIT_BUILD_FAILED = 1
EXIT_USAGE = 2


class BuildError(Exception):
    pass


class Options:
    def __init__(self, args: argparse.Namespace):
        self.check = args.check
        self.test = args.test
        self.example = args.example
        self.target = args.target
        self.opt = args.opt
        self.verbose = args.verbose
        self.init_deps = args.init_deps
        self.clean = args.clean
        self.skip_abi = args.skip_abi
        self.skip_shaders = args.skip_shaders
        self.skip_build = args.skip_build
        self.skip_boundaries = args.skip_boundaries
        self.c3c = args.c3c
        self.glslang = args.glslang


def log(message: str) -> None:
    print(f"[build] {message}", flush=True)


def run(command: list[str], cwd: Path, verbose: bool) -> None:
    if verbose:
        log(f"$ {' '.join(command)}  (cwd {cwd.relative_to(ROOT) if cwd != ROOT else '.'})")
    result = subprocess.run(command, cwd=cwd)
    if result.returncode != 0:
        raise BuildError(f"command failed ({result.returncode}): {' '.join(command)}")


def capture(command: list[str], cwd: Path) -> str:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise BuildError(f"command failed ({result.returncode}): {' '.join(command)}\n{result.stderr}")
    return result.stdout


def timed(name: str):
    class Timer:
        def __enter__(self):
            self.start = time.perf_counter()
            log(f"{name}")
            return self

        def __exit__(self, exc_type, exc, traceback):
            elapsed = time.perf_counter() - self.start
            status = "failed" if exc_type else "ok"
            log(f"{name}: {status} ({elapsed:.1f}s)")
            return False

    return Timer()


def project_targets(project_dir: Path) -> list[str]:
    project_file = project_dir / "project.json"
    if not project_file.exists():
        return []
    with project_file.open() as handle:
        project = json.load(handle)
    return list(project.get("targets", {}).keys())


# ----------------------------------------------------------------------------- steps


def step_tools(options: Options) -> None:
    if sys.version_info < (3, 10):
        raise BuildError("python 3.10 or newer is required")

    c3c = shutil.which(options.c3c)
    if c3c is None:
        raise BuildError(f"'{options.c3c}' not found on PATH (set --c3c or install C3 {REQUIRED_C3C_VERSION})")
    version_text = capture([c3c, "--version"], ROOT)
    match = re.search(r"\d+\.\d+\.\d+", version_text)
    version = match.group(0) if match else "unknown"
    if version != REQUIRED_C3C_VERSION:
        raise BuildError(f"c3c {REQUIRED_C3C_VERSION} required, found {version}")
    log(f"c3c {version} at {c3c}")

    if not options.skip_shaders:
        glslang = shutil.which(options.glslang)
        if glslang is None:
            raise BuildError(f"'{options.glslang}' not found on PATH (install a Vulkan SDK or pass --glslang)")
        log(f"glslang at {glslang}")


def step_deps(options: Options) -> None:
    if options.init_deps:
        run(["git", "submodule", "update", "--init", "--recursive"], ROOT, options.verbose)
        for name in SUBMODULES:
            for script_name in NATIVE_BUILD_SCRIPTS:
                script = LIB / name / script_name
                if script.exists():
                    run(["sh", str(script)], script.parent, options.verbose)

    missing = [name for name in SUBMODULES if not (LIB / name / "manifest.json").exists()]
    if missing:
        raise BuildError(
            f"missing dependencies under lib/: {', '.join(missing)} "
            "(run scripts/build.py --init-deps)"
        )


def step_abi(options: Options) -> None:
    if options.skip_abi:
        log("abi: skipped")
        return
    command = [sys.executable, str(SCRIPTS / "gen_abi.py")]
    if options.check:
        command.append("--check")
    run(command, ROOT, options.verbose)


def step_shaders(options: Options) -> None:
    if options.skip_shaders:
        log("shaders: skipped")
        return
    command = [sys.executable, str(SCRIPTS / "build_shaders.py"), "--glslang", options.glslang]
    if options.check:
        command.append("--check")
    if options.verbose:
        command.append("--verbose")
    run(command, ROOT, options.verbose)


def step_boundaries(options: Options) -> None:
    if options.skip_boundaries:
        log("boundaries: skipped")
        return
    source_root = ROOT / "src" / "c3d"
    violations: list[str] = []
    for source in source_root.rglob("*.c3"):
        relative = source.relative_to(source_root)
        top_directory = relative.parts[0] if len(relative.parts) > 1 else ""
        text = source.read_text(encoding="utf-8")
        for module, allowed in IMPORT_BOUNDARIES.items():
            if top_directory in allowed:
                continue
            permitted = SUBMODULE_BOUNDARIES.get(module, {}).get(top_directory)
            for match in re.finditer(rf"^\s*import\s+{module}(?:::(?P<submodule>\w+))?\b", text, re.MULTILINE):
                submodule = match.group("submodule")
                if submodule is not None and submodule == permitted:
                    continue
                imported = f"{module}::{submodule}" if submodule else module
                violations.append(f"{relative}: imports {imported}")
    if violations:
        raise BuildError("import boundary violations:\n  " + "\n  ".join(violations))


def step_build(options: Options) -> None:
    if options.skip_build:
        log("build: skipped")
        return
    targets = [options.target] if options.target else project_targets(EXAMPLES)
    if not targets:
        raise BuildError(f"no targets found in {EXAMPLES / 'project.json'}")
    for target in targets:
        command = [options.c3c, "build", target, "--path", str(EXAMPLES)]
        if options.opt:
            command.append(f"-{options.opt}")
        run(command, ROOT, options.verbose)


def step_test(options: Options) -> None:
    if not options.test:
        return
    targets = project_targets(TEST)
    if not targets:
        run([options.c3c, "test", "--path", str(TEST)], ROOT, options.verbose)
        return
    for target in targets:
        run([options.c3c, "test", target, "--path", str(TEST)], ROOT, options.verbose)


def step_run(options: Options) -> None:
    if not options.example:
        return
    command = [options.c3c, "run", options.example, "--path", str(EXAMPLES)]
    if options.opt:
        command.append(f"-{options.opt}")
    run(command, ROOT, options.verbose)


def step_clean(options: Options) -> None:
    for project_dir in (EXAMPLES, TEST):
        if (project_dir / "project.json").exists():
            run([options.c3c, "clean", "--path", str(project_dir)], ROOT, options.verbose)


# ----------------------------------------------------------------------------- entry


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="c3d build orchestration",
        epilog=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--check", action="store_true", help="verify generated ABI and shaders instead of regenerating (CI)")
    parser.add_argument("--test", action="store_true", help="run every test target after building")
    parser.add_argument("--example", metavar="NAME", help="run one example target after building it")
    parser.add_argument("--target", metavar="NAME", help="build only this example target")
    parser.add_argument("--opt", metavar="LEVEL", help="c3c optimization flag without the dash, for example O3")
    parser.add_argument("--init-deps", action="store_true", help="initialize submodules and run native dependency builds")
    parser.add_argument("--clean", action="store_true", help="remove c3c build directories and exit")
    parser.add_argument("--skip-abi", action="store_true")
    parser.add_argument("--skip-shaders", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-boundaries", action="store_true", help="skip the import boundary check")
    parser.add_argument("--c3c", default="c3c", help="c3c executable (default: c3c)")
    parser.add_argument("--glslang", default="glslangValidator", help="glslang executable (default: glslangValidator)")
    parser.add_argument("-v", "--verbose", action="store_true", help="print every command")
    return parser.parse_args()


def main() -> int:
    options = Options(parse_arguments())
    if options.example and options.target is None:
        options.target = options.example

    try:
        if options.clean:
            with timed("clean"):
                step_clean(options)
            return 0

        with timed("tools"):
            step_tools(options)
        with timed("deps"):
            step_deps(options)
        with timed("abi"):
            step_abi(options)
        with timed("shaders"):
            step_shaders(options)
        with timed("boundaries"):
            step_boundaries(options)
        with timed("build"):
            step_build(options)
        if options.test:
            with timed("test"):
                step_test(options)
        if options.example:
            with timed(f"run {options.example}"):
                step_run(options)
    except BuildError as error:
        log(str(error))
        return EXIT_BUILD_FAILED
    except KeyboardInterrupt:
        log("interrupted")
        return EXIT_BUILD_FAILED
    return 0


if __name__ == "__main__":
    sys.exit(main())
