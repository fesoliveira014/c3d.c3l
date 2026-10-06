#!/usr/bin/env python3
"""Compile core's shader stages and every shader package to SPIR-V and emit their C3 tables.

Core: each entry of shaders/variants.json names one stage source under shaders/, its glslang
stage, and the defines it is compiled with. SPIR-V goes to shaders/spv/<name>.spv on every run
and is not committed; src/c3d/shader/variants.c3, with the ShaderName enum, flag constants, and
the embedded table, is committed.

The GLSL include set (shaders/common, shaders/generated and shaders/gpu) is embedded as
src/c3d/shader/includes.c3 so the in-process compiler resolves #include without a filesystem;
it is committed and checked like the registry table. shaders/gpu is a committed copy of
gpu.c3l's include/shaders, so a packed core library carries every file it embeds; it is
refreshed and checked the same way.

Each public_includes row of shaders/variants.json is compiled as a probe under
shaders/spv/probes/: the two ABI headers, the include and an empty main, with the row's stage
and defines. A public include that needs another include first fails the run with its name
and glslang's output.

A shader package is a directory with shaders/shaders.json (module, output, flags, entries), whose
entries follow variants.json with sources under the package's shaders/. Packages are discovered
under addons/*/ and test/. A package compiles
against core's include roots plus its own shaders/include/, whose files live under
shaders/include/<name>/ for the last component <name> of its module; another package's includes
are never visible. Its SPIR-V goes to its shaders/spv/, and its output C3 file, committed and
checked like the core tables, holds the SPIR-V as @private $embed constants and, when it has
includes, a public <NAME>_SHADER_INCLUDES table for the in-process compiler.

--package DIR compiles only the packages named (repeatable) against the include roots and writes
only their outputs. It reads neither shaders/variants.json nor lib/, so it runs from the shader
tools archive of a release as well as from a checkout.

  scripts/build_shaders.py                  compile everything and write every table
  scripts/build_shaders.py --check          compile everything; fail if a committed table is out of date
  scripts/build_shaders.py --package DIR    compile only the shader package at DIR (repeatable)
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHADERS = ROOT / "shaders"
MANIFEST = SHADERS / "variants.json"
SPIRV = SHADERS / "spv"
PROBES = SPIRV / "probes"
GENERATED_C3 = ROOT / "src" / "c3d" / "shader" / "variants.c3"
GENERATED_INCLUDES_C3 = ROOT / "src" / "c3d" / "shader" / "includes.c3"
GPU_INCLUDE_SOURCE = ROOT / "lib" / "gpu.c3l" / "include" / "shaders"
GPU_INCLUDE_COPY = SHADERS / "gpu"
INCLUDE_DIRS = (
    SHADERS / "generated",
    SHADERS / "common",
    GPU_INCLUDE_COPY,
)
INCLUDE_ROOT_PREFIXES = ("C3D_GENERATED", "C3D_COMMON", "GPU")
PROBE_PRELUDE = ("generated/shader_abi.glsl", "c3d_abi.glsl")
PACKAGE_MANIFEST = Path("shaders") / "shaders.json"
PACKAGE_FIELDS = ("module", "output", "flags", "entries")
IN_REPO_PACKAGE_PATTERNS = ("addons/*", "test")

TARGET_ENV = "vulkan1.3"
# Keep discard available without requesting shaderDemoteToHelperInvocation.
TARGET_SPIRV = "spirv1.5"
INCLUDE_PREAMBLE = "#extension GL_GOOGLE_include_directive : enable"
EMBED_PREFIX = "../../../shaders/spv/"
STAGES = (
    "vert", "frag", "comp", "geom", "tesc", "tese",
    "rgen", "rmiss", "rchit", "rahit", "rint", "rcall",
    "task", "mesh",
)
MAX_FLAGS = 24
MAX_SHADERS = 256

EXIT_FAILED = 1


class ManifestError(Exception):
    pass


class CompileError(Exception):
    def __init__(self, message: str, output: str) -> None:
        super().__init__(message)
        self.output = output


@dataclass(frozen=True)
class Entry:
    shader: str
    source: Path
    stage: str
    defines: tuple[str, ...]

    @property
    def spirv_name(self) -> str:
        suffix = "".join(f"_{define.lower()}" for define in self.defines)
        return f"{self.shader}{suffix}.spv"

    @property
    def embed_constant(self) -> str:
        return f"{Path(self.spirv_name).stem.upper()}_SPIRV"


@dataclass(frozen=True)
class Probe:
    include: str
    stage: str
    defines: tuple[str, ...]

    @property
    def name(self) -> str:
        suffix = "".join(f"_{define.lower()}" for define in self.defines)
        return self.include.removesuffix(".glsl").replace("/", "_") + suffix


@dataclass(frozen=True)
class Include:
    name: str
    source: Path
    constant: str


@dataclass(frozen=True)
class Package:
    root: Path
    module: str
    output: Path
    entries: tuple[Entry, ...]
    includes: tuple[Include, ...]

    @property
    def name(self) -> str:
        return self.module.split("::")[-1]

    @property
    def spirv(self) -> Path:
        return self.root / "shaders" / "spv"

    @property
    def include_root(self) -> Path:
        return self.root / "shaders" / "include"


def log(message: str) -> None:
    print(f"[shaders] {message}", flush=True)


def display(path: Path) -> str:
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def required(raw: dict, key: str, label: str):
    if key not in raw:
        raise ManifestError(f"{label}: missing '{key}'")
    return raw[key]


def parse_entries(raw_entries: list, flags: list[str], source_root: Path, label: str) -> list[Entry]:
    entries: list[Entry] = []
    seen: set[tuple[str, tuple[str, ...]]] = set()
    for raw in raw_entries:
        shader = required(raw, "shader", label)
        stage = required(raw, "stage", f"{label} {shader}")
        if stage not in STAGES:
            raise ManifestError(f"{label} {shader}: unknown stage '{stage}'")
        source = source_root / required(raw, "source", f"{label} {shader}")
        if not source.exists():
            raise ManifestError(f"{label} {shader}: source {display(source)} does not exist")
        unknown = [define for define in raw.get("defines", []) if define not in flags]
        if unknown:
            raise ManifestError(f"{label} {shader}: defines not declared in flags: {', '.join(unknown)}")
        defines = tuple(flag for flag in flags if flag in raw.get("defines", []))
        key = (shader, defines)
        if key in seen:
            raise ManifestError(f"{label} {shader}: duplicate entry for defines {list(defines)}")
        seen.add(key)
        entries.append(Entry(shader, source, stage, defines))
    return entries


def parse_probes(raw_probes: list, include_names: set[str]) -> list[Probe]:
    probes: list[Probe] = []
    for raw in raw_probes:
        include = required(raw, "include", "public_includes")
        stage = required(raw, "stage", f"public_includes {include}")
        if include not in include_names:
            raise ManifestError(f"public_includes: '{include}' is not in the include roots")
        if stage not in STAGES:
            raise ManifestError(f"public_includes {include}: unknown stage '{stage}'")
        probe = Probe(include, stage, tuple(raw.get("defines", [])))
        if probe in probes:
            raise ManifestError(f"public_includes {include}: duplicate probe ({stage}, {list(probe.defines)})")
        probes.append(probe)
    return probes


def load_manifest(include_names: set[str]) -> tuple[list[str], list[Entry], list[Probe]]:
    with MANIFEST.open() as handle:
        manifest = json.load(handle)
    flags: list[str] = list(manifest.get("flags", []))
    if len(flags) > MAX_FLAGS:
        raise ManifestError(f"{len(flags)} flags declared; ShaderVariant holds {MAX_FLAGS}")
    if len(set(flags)) != len(flags):
        raise ManifestError("duplicate flag names")

    entries = parse_entries(manifest.get("entries", []), flags, SHADERS, display(MANIFEST))
    shaders = shader_names(entries)
    if len(shaders) > MAX_SHADERS:
        raise ManifestError(f"{len(shaders)} shader names; ShaderVariant holds {MAX_SHADERS}")
    return flags, entries, parse_probes(manifest.get("public_includes", []), include_names)


def shader_names(entries: list[Entry]) -> list[str]:
    names: list[str] = []
    for entry in entries:
        if entry.shader not in names:
            names.append(entry.shader)
    return names


def compile_one(glslang: str, entry: Entry, output: Path, include_dirs: tuple[Path, ...], verbose: bool) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        glslang,
        "-V",
        "--target-env", TARGET_ENV,
        "--target-env", TARGET_SPIRV,
        "-S", entry.stage,
        f"-P{INCLUDE_PREAMBLE}",
    ]
    command += [f"-D{define}" for define in entry.defines]
    command += [f"-I{directory}" for directory in include_dirs]
    command += ["-o", str(output), str(entry.source)]
    if verbose:
        log(f"$ {' '.join(command)}")
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise CompileError(
            f"glslang failed on {display(entry.source)} ({result.returncode})",
            result.stdout + result.stderr,
        )


def compile_probes(glslang: str, probes: list[Probe], verbose: bool) -> None:
    PROBES.mkdir(parents=True, exist_ok=True)
    for probe in probes:
        source = PROBES / f"{probe.name}.{probe.stage}.glsl"
        lines = ["#version 460"] + [f'#include "{name}"' for name in (*PROBE_PRELUDE, probe.include)]
        source.write_text("\n".join(lines + ["void main() {}", ""]), encoding="utf-8", newline="\n")
        try:
            compile_one(
                glslang,
                Entry(probe.name, source, probe.stage, probe.defines),
                source.with_suffix(".spv"),
                INCLUDE_DIRS,
                verbose,
            )
        except CompileError as error:
            defines = ", ".join(probe.defines) or "no defines"
            raise CompileError(
                f"public include {probe.include} is not self-contained ({probe.stage}, {defines})",
                error.output,
            ) from None


def emit_variants_c3(flags: list[str], entries: list[Entry]) -> str:
    lines = [
        f"// Generated by build_shaders.py from {MANIFEST.relative_to(ROOT).as_posix()} - do not edit.",
        "module c3d::shader;",
        "",
        "<*",
        " Stage families compiled into the registry.",
        "*>",
        "enum ShaderName : int {",
    ]
    lines += [f"    {name.upper()}," for name in shader_names(entries)]
    lines.append("}")

    for bit, flag in enumerate(flags):
        lines += [
            "",
            "<*",
            f" Flag bit for {flag}.",
            "*>",
            f"const uint SHADER_FLAG_{flag} = 1 << {bit};",
        ]

    lines.append("")
    for entry in entries:
        lines.append(
            f'const char[*] {entry.embed_constant} @private = $embed("{EMBED_PREFIX}{entry.spirv_name}");'
        )

    lines += [
        "",
        "<*",
        " Every compiled stage, in manifest order.",
        "*>",
        f"const ShaderEntry[{len(entries)}] SHADER_ENTRIES = {{",
    ]
    for entry in entries:
        variant = f".shader = {entry.shader.upper()}"
        if entry.defines:
            mask = " | ".join(f"SHADER_FLAG_{define}" for define in entry.defines)
            variant += f", .flags = {mask}"
        lines.append(f"    {{ .variant = {{ {variant} }}, .spirv = {entry.embed_constant}[..] }},")
    lines.append("};")
    return "\n".join(lines) + "\n"


def collect_includes() -> list[Include]:
    includes: list[Include] = []
    seen: dict[str, Path] = {}
    for root, prefix in zip(INCLUDE_DIRS, INCLUDE_ROOT_PREFIXES):
        for source in sorted(root.rglob("*.glsl")):
            name = source.relative_to(root).as_posix()
            if name in seen:
                raise ManifestError(f"include '{name}' exists under both {seen[name]} and {source}")
            seen[name] = source
            mangled = name.removesuffix(".glsl").replace("/", "_").replace(".", "_").upper()
            includes.append(Include(name, source, f"{prefix}_{mangled}_TEXT"))
    return includes


def emit_includes_c3(includes: list[Include]) -> str:
    lines = [
        f"// Generated by build_shaders.py from the GLSL include roots - do not edit.",
        "module c3d::shader;",
        "",
        "import c3d::asset;",
        "",
    ]
    for include in includes:
        relative = Path("../../..") / include.source.relative_to(ROOT)
        lines.append(f'const char[*] {include.constant} @private = $embed("{relative.as_posix()}");')
    lines += [
        "",
        "<*",
        " Every include a custom stage may resolve, in table order.",
        "*>",
        f"const asset::ShaderInclude[{len(includes)}] SHADER_INCLUDES = {{",
    ]
    for include in includes:
        lines.append(f'    {{ .name = "{include.name}", .text = (String){include.constant}[..] }},')
    lines.append("};")
    return "\n".join(lines) + "\n"


def discover_packages() -> list[Path]:
    roots: list[Path] = []
    for pattern in IN_REPO_PACKAGE_PATTERNS:
        roots += sorted(path for path in ROOT.glob(pattern) if (path / PACKAGE_MANIFEST).exists())
    return roots


def named_packages(directories: list[Path]) -> list[Path]:
    roots: list[Path] = []
    for directory in directories:
        root = directory.resolve()
        if not (root / PACKAGE_MANIFEST).exists():
            raise ManifestError(f"--package {directory}: no {PACKAGE_MANIFEST.as_posix()}")
        if root not in roots:
            roots.append(root)
    return roots


def collect_package_includes(include_root: Path, name: str) -> list[Include]:
    includes: list[Include] = []
    if not include_root.exists():
        return includes
    for source in sorted(include_root.rglob("*.glsl")):
        relative = source.relative_to(include_root).as_posix()
        if not relative.startswith(f"{name}/"):
            raise ManifestError(f"{display(source)}: package includes live under shaders/include/{name}/")
        mangled = relative.removesuffix(".glsl").replace("/", "_").replace(".", "_").upper()
        includes.append(Include(relative, source, f"INCLUDE_{mangled}_TEXT"))
    return includes


def load_package(root: Path) -> Package:
    manifest_path = root / PACKAGE_MANIFEST
    label = display(manifest_path)
    with manifest_path.open() as handle:
        manifest = json.load(handle)
    module, output, flags, raw_entries = (required(manifest, field, label) for field in PACKAGE_FIELDS)
    if len(set(flags)) != len(flags):
        raise ManifestError(f"{label}: duplicate flag names")
    entries = parse_entries(raw_entries, list(flags), root / "shaders", label)
    name = module.split("::")[-1]
    includes = collect_package_includes(root / "shaders" / "include", name)
    return Package(root, module, root / output, tuple(entries), tuple(includes))


def check_package_names(packages: list[Package], core_includes: list[Include]) -> None:
    core_names = {include.name for include in core_includes}
    core_directories = {name.split("/")[0] for name in core_names if "/" in name}
    owners: dict[str, Package] = {}
    for package in packages:
        label = display(package.root / PACKAGE_MANIFEST)
        if package.name in core_directories:
            raise ManifestError(f"{label}: '{package.name}' is an include directory of core")
        for include in package.includes:
            if include.name in core_names:
                raise ManifestError(f"{label}: include '{include.name}' is a core include")
            if include.name in owners:
                raise ManifestError(
                    f"{label}: include '{include.name}' is also in {display(owners[include.name].root)}"
                )
            owners[include.name] = package


def compile_package(glslang: str, package: Package, verbose: bool) -> None:
    include_dirs = INCLUDE_DIRS + ((package.include_root,) if package.includes else ())
    for entry in package.entries:
        compile_one(glslang, entry, package.spirv / entry.spirv_name, include_dirs, verbose)


def relative_posix(target: Path, base: Path) -> str:
    return Path(os.path.relpath(target, base)).as_posix()


def emit_package_c3(package: Package) -> str:
    base = package.output.parent
    lines = [
        f"// Generated by build_shaders.py from {PACKAGE_MANIFEST.as_posix()} - do not edit.",
        f"module {package.module};",
        "",
    ]
    if package.includes:
        lines += ["import c3d::asset;", ""]
    for entry in package.entries:
        path = relative_posix(package.spirv / entry.spirv_name, base)
        lines.append(f'const char[*] {entry.embed_constant} @private = $embed("{path}");')
    for include in package.includes:
        path = relative_posix(include.source, base)
        lines.append(f'const char[*] {include.constant} @private = $embed("{path}");')
    if package.includes:
        lines += [
            "",
            "<*",
            " GLSL includes of this package, by the name a shader writes.",
            "*>",
            f"const asset::ShaderInclude[{len(package.includes)}] {package.name.upper()}_SHADER_INCLUDES = {{",
        ]
        for include in package.includes:
            lines.append(f'    {{ .name = "{include.name}", .text = (String){include.constant}[..] }},')
        lines.append("};")
    return "\n".join(lines) + "\n"


def compile_all(glslang: str, entries: list[Entry], verbose: bool) -> None:
    for entry in entries:
        compile_one(glslang, entry, SPIRV / entry.spirv_name, INCLUDE_DIRS, verbose)


def is_current(path: Path, expected: str) -> bool:
    return path.exists() and path.read_text(encoding="utf-8") == expected


def gpu_include_tables() -> list[tuple[Path, str]]:
    if not GPU_INCLUDE_SOURCE.exists():
        raise ManifestError(f"no gpu.c3l include tree at {display(GPU_INCLUDE_SOURCE)}")
    return [
        (GPU_INCLUDE_COPY / source.relative_to(GPU_INCLUDE_SOURCE), source.read_text(encoding="utf-8"))
        for source in sorted(GPU_INCLUDE_SOURCE.rglob("*.glsl"))
    ]


def orphan_gpu_includes(tables: list[tuple[Path, str]]) -> list[Path]:
    expected = {path for path, _ in tables}
    return [path for path in sorted(GPU_INCLUDE_COPY.rglob("*.glsl")) if path not in expected]


def core_tables(flags: list[str], entries: list[Entry], includes: list[Include]) -> list[tuple[Path, str]]:
    return [
        (GENERATED_C3, emit_variants_c3(flags, entries)),
        (GENERATED_INCLUDES_C3, emit_includes_c3(includes)),
    ]


def package_tables(packages: list[Package]) -> list[tuple[Path, str]]:
    return [(package.output, emit_package_c3(package)) for package in packages]


def stale_tables(tables: list[tuple[Path, str]]) -> list[str]:
    return [display(path) for path, text in tables if not is_current(path, text)]


def write_tables(tables: list[tuple[Path, str]]) -> None:
    for path, text in tables:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")


def report_or_write(tables: list[tuple[Path, str]], orphans: list[Path], check: bool) -> bool:
    if check:
        stale = stale_tables(tables) + [display(path) for path in orphans]
        if stale:
            log(f"stale: {', '.join(stale)} (run scripts/build.py --regen, or build_shaders.py without --check)")
            return False
        return True
    write_tables(tables)
    for path in orphans:
        path.unlink()
    return True


def run_packages(glslang: str, directories: list[Path], check: bool, verbose: bool) -> int:
    includes = collect_includes()
    packages = [load_package(root) for root in named_packages(directories)]
    check_package_names(packages, includes)
    for package in packages:
        compile_package(glslang, package, verbose)
    if not report_or_write(package_tables(packages), [], check):
        return EXIT_FAILED
    package_stages = sum(len(package.entries) for package in packages)
    log(f"compiled {package_stages} stage(s) in {len(packages)} package(s), "
        f"tables {'checked' if check else 'written'}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="c3d shader compilation")
    parser.add_argument("--glslang", default="glslangValidator", help="glslang executable")
    parser.add_argument("--check", action="store_true", help="verify the committed tables instead of writing them")
    parser.add_argument(
        "--package",
        action="append",
        default=[],
        type=Path,
        metavar="DIR",
        help="compile only the shader package at DIR (repeatable)",
    )
    parser.add_argument("--verbose", action="store_true", help="print every command")
    arguments = parser.parse_args()

    if not arguments.package and not MANIFEST.exists():
        log(f"no manifest at {MANIFEST.relative_to(ROOT).as_posix()}")
        return 0

    glslang = shutil.which(arguments.glslang)
    if glslang is None:
        log(f"'{arguments.glslang}' not found on PATH")
        return EXIT_FAILED

    try:
        if arguments.package:
            return run_packages(glslang, arguments.package, arguments.check, arguments.verbose)
        gpu_includes = gpu_include_tables()
        orphans = orphan_gpu_includes(gpu_includes)
        if not arguments.check:
            report_or_write(gpu_includes, orphans, check=False)
            orphans = []
        includes = collect_includes()
        flags, entries, probes = load_manifest({include.name for include in includes})
        packages = [load_package(root) for root in discover_packages()]
        check_package_names(packages, includes)
        compile_all(glslang, entries, arguments.verbose)
        compile_probes(glslang, probes, arguments.verbose)
        for package in packages:
            compile_package(glslang, package, arguments.verbose)
        tables = core_tables(flags, entries, includes) + package_tables(packages)
        if arguments.check:
            tables = gpu_includes + tables
        if not report_or_write(tables, orphans, arguments.check):
            return EXIT_FAILED
    except ManifestError as error:
        log(f"manifest error: {error}")
        return EXIT_FAILED
    except CompileError as error:
        log(str(error))
        print(error.output.rstrip(), flush=True)
        return EXIT_FAILED

    package_stages = sum(len(package.entries) for package in packages)
    log(f"compiled {len(entries)} stage(s), {len(probes)} probe(s), {package_stages} stage(s) in "
        f"{len(packages)} package(s), {len(includes)} include(s), tables {'checked' if arguments.check else 'written'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
