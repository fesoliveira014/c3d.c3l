#!/usr/bin/env python3
"""Compile the stages listed in shaders/variants.json to SPIR-V and emit the registry table.

Each manifest entry names one stage source under shaders/, its glslang stage, and the
defines it is compiled with. SPIR-V goes to shaders/spv/<name>.spv on every run and is not
committed; src/c3d/shader/variants.c3, with the ShaderName enum, flag constants, and the
embedded table, is committed.

The GLSL include set (shaders/common, shaders/generated and gpu.c3l's include/shaders) is
embedded as src/c3d/shader/includes.c3 so the in-process compiler resolves #include without
a filesystem; it is committed and checked like the registry table.

Each public_includes row of shaders/variants.json is compiled as a probe under
shaders/spv/probes/: the two ABI headers, the include and an empty main, with the row's stage
and defines. A public include that needs another include first fails the run with its name
and glslang's output.

  scripts/build_shaders.py            compile every entry and probe and write the registry and include tables
  scripts/build_shaders.py --check    compile every entry and probe; fail if a committed table is out of date
"""

from __future__ import annotations

import argparse
import json
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
INCLUDE_DIRS = (
    SHADERS / "generated",
    SHADERS / "common",
    ROOT / "lib" / "gpu.c3l" / "include" / "shaders",
)
INCLUDE_ROOT_PREFIXES = ("C3D_GENERATED", "C3D_COMMON", "GPU")
PROBE_PRELUDE = ("generated/shader_abi.glsl", "c3d_abi.glsl")

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


@dataclass(frozen=True)
class Include:
    name: str
    source: Path
    constant: str


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
        "<*",
        " One GLSL include by the name a shader writes.",
        "*>",
        "struct ShaderInclude {",
        "    String name;",
        "    String text;",
        "}",
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
        f"const ShaderInclude[{len(includes)}] SHADER_INCLUDES = {{",
    ]
    for include in includes:
        lines.append(f'    {{ .name = "{include.name}", .text = (String){include.constant}[..] }},')
    lines.append("};")
    return "\n".join(lines) + "\n"


def compile_all(glslang: str, entries: list[Entry], verbose: bool) -> None:
    for entry in entries:
        compile_one(glslang, entry, SPIRV / entry.spirv_name, INCLUDE_DIRS, verbose)


def table_is_current(flags: list[str], entries: list[Entry], includes: list[Include]) -> bool:
    expected = emit_variants_c3(flags, entries)
    expected_includes = emit_includes_c3(includes)
    return (
        GENERATED_C3.exists()
        and GENERATED_C3.read_text(encoding="utf-8") == expected
        and GENERATED_INCLUDES_C3.exists()
        and GENERATED_INCLUDES_C3.read_text(encoding="utf-8") == expected_includes
    )


def write_table(flags: list[str], entries: list[Entry], includes: list[Include]) -> None:
    GENERATED_C3.parent.mkdir(parents=True, exist_ok=True)
    GENERATED_C3.write_text(emit_variants_c3(flags, entries), encoding="utf-8", newline="\n")
    GENERATED_INCLUDES_C3.write_text(emit_includes_c3(includes), encoding="utf-8", newline="\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="c3d shader compilation")
    parser.add_argument("--glslang", default="glslangValidator", help="glslang executable")
    parser.add_argument("--check", action="store_true", help="verify the committed registry table instead of writing it")
    parser.add_argument("--verbose", action="store_true", help="print every command")
    arguments = parser.parse_args()

    if not MANIFEST.exists():
        log(f"no manifest at {MANIFEST.relative_to(ROOT).as_posix()}")
        return 0

    glslang = shutil.which(arguments.glslang)
    if glslang is None:
        log(f"'{arguments.glslang}' not found on PATH")
        return EXIT_FAILED

    try:
        includes = collect_includes()
        flags, entries, probes = load_manifest({include.name for include in includes})
        compile_all(glslang, entries, arguments.verbose)
        compile_probes(glslang, probes, arguments.verbose)
        if arguments.check:
            if not table_is_current(flags, entries, includes):
                log(f"stale: {GENERATED_C3.relative_to(ROOT).as_posix()} or "
                    f"{GENERATED_INCLUDES_C3.relative_to(ROOT).as_posix()} (run scripts/build.py --regen)")
                return EXIT_FAILED
        else:
            write_table(flags, entries, includes)
    except ManifestError as error:
        log(f"manifest error: {error}")
        return EXIT_FAILED
    except CompileError as error:
        log(str(error))
        print(error.output.rstrip(), flush=True)
        return EXIT_FAILED

    log(f"compiled {len(entries)} stage(s), {len(probes)} probe(s), {len(includes)} include(s), "
        f"tables {'checked' if arguments.check else 'written'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
