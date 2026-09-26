#!/usr/bin/env python3
"""Build orchestration for c3d.

Steps, in order: tools, deps, boundaries, abi, shaders, build, test, run.
Each step is a function; failures raise BuildError and stop the run.

  scripts/build.py                  compile SPIR-V, verify committed generated C3, build all example targets
  scripts/build.py --test           same, then run every test target (what CI runs)
  scripts/build.py --regen          rewrite the generated C3 and GLSL, then build
  scripts/build.py --example cube   build and run one example
  scripts/build.py --example physics
                                    add-on examples (capture, physics, physics_instanced) resolve to their package project
  scripts/build.py --init-deps      initialize submodules and build native dependencies
  scripts/build.py --clean          remove c3c build directories
  scripts/build.py --target many_lights --define C3D_PROFILE_CPU --lib c3d_profile
                                    build one target with extra c3c feature defines and libraries
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
PROFILE = ROOT / "addons" / "c3d_profile.c3l"
PROFILE_GUI = ROOT / "addons" / "c3d_profile_gui.c3l"
PHYSICS = ROOT / "addons" / "c3d_physics.c3l"
ADDON_EXAMPLES = {
    "capture": PROFILE,
    "physics": PHYSICS,
    "physics_instanced": PHYSICS,
    "physics_components": PHYSICS,
    "vehicle": PHYSICS,
    "ragdoll": PHYSICS,
}
PROFILE_TEST_TARGETS = (
    "profile_off", "profile_cpu", "profile_internal", "profile_gpu",
    "profile_gpu_internal", "profile_cpu_gpu", "profile_full",
)
PROFILE_GUI_TEST_TARGETS = (
    "panel_off", "panel_cpu", "panel_gpu", "panel_combined",
)
PHYSICS_TEST_TARGETS = ("physics_test",)

# Import boundaries of AGENTS.md sections 1 and 10: (description, scanned paths, line pattern,
# path prefixes where a matching line is allowed). Directories are scanned for *.c3 files.
BOUNDARY_RULES = (
    ("gpu only under the render layer and platform", ("src/c3d",), r"^import gpu\b",
     ("src/c3d/render/", "src/c3d/shader/", "src/c3d/gui/", "src/c3d/platform/")),
    ("platform imports gpu::surface alone", ("src/c3d/platform",), r"^import gpu\b(?!::surface\b)", ()),
    ("sdl only under platform", ("src/c3d",), r"^import sdl\b", ("src/c3d/platform/",)),
    ("imgui only under gui", ("src/c3d",), r"^import imgui\b", ("src/c3d/gui/",)),
    ("cg only under geometry", ("src/c3d",), r"^import cg\b", ("src/c3d/geometry/",)),
    ("b3 only in the physics package", ("src/c3d", "addons"), r"^import b3\b", ("addons/c3d_physics.c3l/",)),
    ("physics package imports std, c3d and b3 only", ("addons/c3d_physics.c3l/src",),
     r"^import (?!std::|c3d[ ;:]|b3[ ;:])", ()),
    ("gltf only under asset/gltf", ("src/c3d",), r"^import gltf\b", ("src/c3d/asset/gltf/",)),
    ("ufbx only under asset/fbx", ("src/c3d",), r"^import ufbx\b", ("src/c3d/asset/fbx/",)),
    ("shaderc only under shader", ("src/c3d",), r"^import shaderc\b", ("src/c3d/shader/",)),
    ("profiler add-on only through the core bridges", ("src/c3d",), r"^import c3d::(profile|render::profile_gpu)\b",
     ("src/c3d/instrumentation.c3", "src/c3d/render/profile.c3")),
    ("profile collector imports std only", ("addons/c3d_profile.c3l/src",), r"^import (?!std::)",
     ("addons/c3d_profile.c3l/src/gpu/",)),
    ("profile GPU module imports std, gpu and c3d::profile only", ("addons/c3d_profile.c3l/src/gpu",),
     r"^import (?!std::|gpu[ ;:]|c3d::profile[ ;])", ()),
    ("profile GUI imports std, c3d::profile and imgui only", ("addons/c3d_profile_gui.c3l/src",),
     r"^import (?!std::|c3d::profile[ ;]|imgui[ ;])", ()),
    ("no manifest depends on the profile GUI", ("manifest.json", "addons/c3d_profile.c3l/manifest.json"),
     r'"c3d_profile_gui"', ()),
    ("core and collector never name the profiler panel", ("src/c3d", "addons/c3d_profile.c3l/src"),
     r"ProfilerPanel|create_profiler_panel|destroy_profiler_panel|profiler_panel", ()),
)

REQUIRED_C3C_VERSION = "0.8.3"
C3IMGUI_RELEASE_TAG = "v0.1.3"
SUBMODULES = ("gpu.c3l", "sdl3.c3l", "c3imgui.c3l", "c3cg.c3l", "box3d.c3l", "cgltf.c3l", "ufbx.c3l", "shaderc.c3l")
NATIVE_BUILD_SCRIPTS = ("scripts/build-box3d.sh",)

EXIT_BUILD_FAILED = 1
EXIT_USAGE = 2


class BuildError(Exception):
    pass


class Options:
    def __init__(self, args: argparse.Namespace):
        self.regen = args.regen
        self.test = args.test
        self.example = args.example
        self.target = args.target
        self.opt = args.opt
        self.defines = args.define
        self.libs = args.lib
        self.verbose = args.verbose
        self.init_deps = args.init_deps
        self.clean = args.clean
        self.skip_boundaries = args.skip_boundaries
        self.skip_abi = args.skip_abi
        self.skip_shaders = args.skip_shaders
        self.skip_build = args.skip_build
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


# Windows PATH can resolve bash to WSL even through shutil.which.
def shell(name: str) -> list[str]:
    if sys.platform == "win32":
        git = shutil.which("git")
        if git is not None:
            for directory in Path(git).resolve().parents[:3]:
                executable = directory / "bin" / f"{name}.exe"
                if executable.is_file():
                    # Git's login profile supplies its Unix tools on a native Windows PATH.
                    return [str(executable), "-l"]
        raise BuildError(f"Git for Windows '{name}' not found (install Git for Windows and put git.exe on PATH)")

    path = shutil.which(name)
    if path is None:
        raise BuildError(f"'{name}' not found on PATH")
    return [path]


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
        run([sys.executable, str(LIB / "gpu.c3l" / "scripts" / "fetch_vma_libs.py")], ROOT, options.verbose)
        fetch = LIB / "c3imgui.c3l" / "fetch_linked_libs.sh"
        run([*shell("bash"), fetch.name, C3IMGUI_RELEASE_TAG], fetch.parent, options.verbose)
        for name in SUBMODULES:
            for script_name in NATIVE_BUILD_SCRIPTS:
                script = LIB / name / script_name
                if script.exists():
                    run([*shell("sh"), script.name], script.parent, options.verbose)

    missing = [name for name in SUBMODULES if not (LIB / name / "manifest.json").exists()]
    if missing:
        raise BuildError(
            f"missing dependencies under lib/: {', '.join(missing)} "
            "(run scripts/build.py --init-deps)"
        )

    native_name = "windows-x64/dcimgui.lib" if sys.platform == "win32" else "linux-x64/libdcimgui.a"
    native_archive = LIB / "c3imgui.c3l" / "linked-libs" / native_name
    if not native_archive.exists():
        raise BuildError(
            f"missing c3imgui native archive: {native_archive} "
            "(run scripts/build.py --init-deps)"
        )


def boundary_files(scanned: str) -> list[Path]:
    path = ROOT / scanned
    return [path] if path.is_file() else sorted(path.rglob("*.c3"))


def step_boundaries(options: Options) -> None:
    if options.skip_boundaries:
        log("boundaries: skipped")
        return
    violations = []
    for description, scanned_paths, pattern, allowed in BOUNDARY_RULES:
        expression = re.compile(pattern)
        for scanned in scanned_paths:
            for path in boundary_files(scanned):
                relative = path.relative_to(ROOT).as_posix()
                if relative.startswith(allowed):
                    continue
                lines = path.read_text(encoding="utf-8").splitlines()
                for line_number, line in enumerate(lines, start=1):
                    if expression.search(line):
                        violations.append(f"{relative}:{line_number}: {description}")
    if violations:
        for violation in violations:
            log(violation)
        raise BuildError(f"{len(violations)} import boundary violation(s)")


def step_abi(options: Options) -> None:
    if options.skip_abi:
        log("abi: skipped")
        return
    command = [sys.executable, str(SCRIPTS / "gen_abi.py")]
    if not options.regen:
        command.append("--check")
    run(command, ROOT, options.verbose)


def step_shaders(options: Options) -> None:
    if options.skip_shaders:
        log("shaders: skipped")
        return
    command = [sys.executable, str(SCRIPTS / "build_shaders.py"), "--glslang", options.glslang]
    if not options.regen:
        command.append("--check")
    if options.verbose:
        command.append("--verbose")
    run(command, ROOT, options.verbose)


def step_build(options: Options) -> None:
    if options.skip_build:
        log("build: skipped")
        return
    if options.target:
        targets = [(options.target, example_project(options.target))]
    else:
        targets = [(target, EXAMPLES) for target in project_targets(EXAMPLES)]
        targets += [(target, project) for target, project in ADDON_EXAMPLES.items()]
    if not targets:
        raise BuildError(f"no targets found in {EXAMPLES / 'project.json'}")
    if (options.defines or options.libs) and not options.target:
        raise BuildError("--define and --lib need --target")
    for target, project in targets:
        command = [options.c3c, "build", target, "--path", str(project)]
        if options.opt:
            command.append(f"-{options.opt}")
        for define in options.defines:
            command += ["-D", define]
        for lib in options.libs:
            command += ["--lib", lib]
        run(command, ROOT, options.verbose)
    copy_windows_runtimes(EXAMPLES / "build")
    copy_windows_runtimes(PHYSICS / "build")
    if not options.target or options.target == "profile_gpu":
        copy_windows_runtimes(ROOT / "build" / "profile_gpu")


def example_project(target: str) -> Path:
    """Project directory that owns an example target."""
    return ADDON_EXAMPLES.get(target, EXAMPLES)


def copy_windows_runtimes(output: Path) -> None:
    """Place imported Windows runtimes next to executables."""
    if sys.platform != "win32":
        return
    output.mkdir(parents=True, exist_ok=True)
    libraries = (
        LIB / "shaderc.c3l" / "windows" / "shaderc_shared.dll",
        LIB / "sdl3.c3l" / "linked-libs" / "windows-x64" / "SDL3.dll",
    )
    for library in libraries:
        destination = output / library.name
        if not destination.exists() or destination.stat().st_mtime < library.stat().st_mtime:
            shutil.copy2(library, destination)


def step_test(options: Options) -> None:
    if not options.test:
        return
    targets = project_targets(TEST)
    copy_windows_runtimes(TEST / "build")
    if not targets:
        run([options.c3c, "test", "--path", str(TEST)], ROOT, options.verbose)
        return
    for target in targets:
        run([options.c3c, "test", target, "--path", str(TEST)], ROOT, options.verbose)
    for target in PROFILE_TEST_TARGETS:
        run([options.c3c, "test", target, "--path", str(PROFILE)], ROOT, options.verbose)
    for target in PROFILE_GUI_TEST_TARGETS:
        run([options.c3c, "test", target, "--path", str(PROFILE_GUI)], ROOT, options.verbose)
    for target in PHYSICS_TEST_TARGETS:
        run([options.c3c, "test", target, "--path", str(PHYSICS)], ROOT, options.verbose)


def step_run(options: Options) -> None:
    if not options.example:
        return
    command = [options.c3c, "run", options.example, "--path", str(example_project(options.example))]
    if options.opt:
        command.append(f"-{options.opt}")
    run(command, ROOT, options.verbose)


def step_clean(options: Options) -> None:
    for project_dir in (EXAMPLES, TEST, PROFILE, PROFILE_GUI, PHYSICS):
        if (project_dir / "project.json").exists():
            run([options.c3c, "clean", "--path", str(project_dir)], ROOT, options.verbose)


# ----------------------------------------------------------------------------- entry


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="c3d build orchestration",
        epilog=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--regen", action="store_true", help="rewrite the generated ABI twins and registry table instead of verifying them")
    parser.add_argument("--test", action="store_true", help="run every test target after building")
    parser.add_argument("--example", metavar="NAME", help="run one example target after building it")
    parser.add_argument("--target", metavar="NAME", help="build only this example target")
    parser.add_argument("--opt", metavar="LEVEL", help="c3c optimization flag without the dash, for example O3")
    parser.add_argument("--define", metavar="NAME", action="append", default=[], help="c3c feature define for the --target build; repeatable")
    parser.add_argument("--lib", metavar="NAME", action="append", default=[], help="extra c3c library for the --target build; repeatable")
    parser.add_argument("--init-deps", action="store_true", help="initialize submodules and run native dependency builds")
    parser.add_argument("--clean", action="store_true", help="remove c3c build directories and exit")
    parser.add_argument("--skip-boundaries", action="store_true")
    parser.add_argument("--skip-abi", action="store_true")
    parser.add_argument("--skip-shaders", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
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
        with timed("boundaries"):
            step_boundaries(options)
        with timed("abi"):
            step_abi(options)
        with timed("shaders"):
            step_shaders(options)
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
