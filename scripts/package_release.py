#!/usr/bin/env python3
"""Pack c3d's release artifacts from a built checkout.

Writes one packed library per package (c3d_core-v<version>.c3l and <add-on>-v<version>.c3l),
the shader tools archive (c3d_shader_tools-v<version>.zip) and SHA256SUMS. A packed library is
a zip with manifest.json at its root; its manifest gains a vendor block naming the release
version and the dependency versions it was built against. Those versions are the release tags
of the dependency submodules, so every submodule must sit on a tag.

Run after scripts/build.py, which compiles the SPIR-V the libraries embed. Packing fails when
the tree has tracked modifications, a submodule is off a tag, or a packed source embeds a file
the same artifact lacks.

  scripts/package_release.py --version 0.1.0 --out dist
"""

from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
import re
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent
ADDONS = ROOT / "addons"
ZIP_DATE = (1980, 1, 1, 0, 0, 0)
VERSION_PATTERN = re.compile(r"\d+\.\d+\.\d+")
EMBED_PATTERN = re.compile(r'\$embed\("([^"]+)"\)')
PROVIDES_PATTERN = re.compile(r'"provides"\s*:\s*"([^"]+)"')
SUBMODULE_PATTERN = re.compile(r"^\s*path\s*=\s*(\S+)\s*$|^\s*url\s*=\s*(\S+)\s*$", re.MULTILINE)
NESTED_SUBMODULE_PARENTS = ("lib/gpu.c3l",)
EXIT_FAILED = 1

CORE_FILES = (
    "src/**/*.c3",
    "src/**/*.c3i",
    "csrc/stb_image.c",
    "csrc/stb_image.h",
    "csrc/stb_truetype.c",
    "csrc/stb_truetype.h",
    "csrc/README.md",
    "shaders/spv/*.spv",
    "shaders/common/**/*.glsl",
    "shaders/generated/**/*.glsl",
    "shaders/gpu/**/*.glsl",
    "LICENSE",
    "LICENSE-slug.txt",
    "README.md",
)
CORE_EMPTY_DIRECTORIES = ("linked-libs/linux-x64/", "linked-libs/windows-x64/")
ADDON_FILES = (
    "src/**/*.c3",
    "src/**/*.c3i",
    "shaders/spv/*.spv",
    "shaders/include/**/*.glsl",
    "LICENSE-*.txt",
    "README.md",
)
TOOLS_FILES = (
    "scripts/build_shaders.py",
    "shaders/common/**/*.glsl",
    "shaders/generated/**/*.glsl",
    "shaders/gpu/**/*.glsl",
    "LICENSE",
)
TOOLS_README = """# c3d shader tools

Compiles an application's shader package (a directory with shaders/shaders.json) to SPIR-V and
writes its C3 output file, against the same GLSL includes c3d {version} was built with. Needs
Python 3.10+ and glslangValidator on PATH.

    python3 c3d_shader_tools/scripts/build_shaders.py --package <dir>
    python3 c3d_shader_tools/scripts/build_shaders.py --package <dir> --check
"""


class PackagingError(Exception):
    pass


@dataclass(frozen=True)
class Artifact:
    name: str
    entries: dict[str, bytes]


Runner = Callable[[list[str], Path], str]


def run_git(arguments: list[str], cwd: Path) -> str:
    result = subprocess.run(["git", *arguments], cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise PackagingError(f"git {' '.join(arguments)} in {cwd}: {result.stderr.strip()}")
    return result.stdout


def submodules(parent: Path) -> list[tuple[str, str]]:
    gitmodules = parent / ".gitmodules"
    if not gitmodules.exists():
        return []
    paths: list[str] = []
    urls: list[str] = []
    for path, url in SUBMODULE_PATTERN.findall(gitmodules.read_text(encoding="utf-8")):
        if path:
            paths.append(path)
        if url:
            urls.append(url)
    return list(zip(paths, urls))


def release_tag(parent: Path, path: str, url: str, git: Runner) -> str:
    commit = git(["rev-parse", f"HEAD:{path}"], parent).strip()
    for line in git(["ls-remote", "--tags", url], parent).splitlines():
        sha, reference = line.split("\t")
        tag = reference.removeprefix("refs/tags/").removesuffix("^{}")
        if sha == commit:
            return tag
    raise PackagingError(f"{parent.name}/{path} is at {commit[:7]}, which no release tag of {url} names")


def provides_of(library: Path) -> str:
    match = PROVIDES_PATTERN.search((library / "manifest.json").read_text(encoding="utf-8"))
    if match is None:
        raise PackagingError(f"{library}: manifest names no provides")
    return match.group(1)


def resolve_pins(root: Path, git: Runner = run_git) -> dict[str, str]:
    pins: dict[str, str] = {}
    parents = [root] + [root / parent for parent in NESTED_SUBMODULE_PARENTS]
    for parent in parents:
        for path, url in submodules(parent):
            pins[provides_of(parent / path)] = release_tag(parent, path, url, git)
    return dict(sorted(pins.items()))


def check_clean(root: Path, git: Runner = run_git) -> None:
    modified = git(["status", "--porcelain", "--untracked-files=no", "--ignore-submodules=dirty"], root).strip()
    if modified:
        raise PackagingError(f"tracked modifications:\n{modified}")


def collect(base: Path, patterns: tuple[str, ...]) -> dict[str, bytes]:
    entries: dict[str, bytes] = {}
    for pattern in patterns:
        for path in sorted(base.glob(pattern)):
            if path.is_symlink() or not path.is_file():
                continue
            entries[path.relative_to(base).as_posix()] = path.read_bytes()
    return entries


def manifest_with_vendor(base: Path, version: str, pins: dict[str, str]) -> bytes:
    manifest = json.loads((base / "manifest.json").read_text(encoding="utf-8"))
    names = set(manifest.get("dependencies", []))
    for target in manifest.get("targets", {}).values():
        names |= set(target.get("dependencies", []))
    requires = {name: tag for name, tag in pins.items() if name in names}
    vendor = manifest.setdefault("vendor", {})
    vendor["c3d"] = {"version": version, "requires": requires} if requires else {"version": version}
    return (json.dumps(manifest, indent=2) + "\n").encode("utf-8")


def check_embeds(name: str, entries: dict[str, bytes]) -> None:
    for entry, data in entries.items():
        if not entry.endswith((".c3", ".c3i")):
            continue
        for target in EMBED_PATTERN.findall(data.decode("utf-8")):
            resolved = posixpath.normpath(posixpath.join(posixpath.dirname(entry), target))
            if resolved not in entries:
                raise PackagingError(f"{name}: {entry} embeds {target}, which the artifact lacks")


def core_artifact(root: Path, version: str, pins: dict[str, str]) -> Artifact:
    spirv = root / "shaders" / "spv"
    if not spirv.is_dir():
        raise PackagingError(f"no {spirv.relative_to(root).as_posix()}; run scripts/build.py first")
    entries = collect(root, CORE_FILES)
    entries["manifest.json"] = manifest_with_vendor(root, version, pins)
    for directory in CORE_EMPTY_DIRECTORIES:
        entries[directory] = b""
    return Artifact(f"c3d_core-v{version}.c3l", entries)


def addon_artifact(root: Path, addon: Path, version: str, pins: dict[str, str]) -> Artifact:
    if (addon / "shaders" / "shaders.json").exists() and not (addon / "shaders" / "spv").is_dir():
        raise PackagingError(f"no {addon.name}/shaders/spv; run scripts/build.py first")
    entries = collect(addon, ADDON_FILES)
    entries["manifest.json"] = manifest_with_vendor(addon, version, pins)
    entries["LICENSE"] = (root / "LICENSE").read_bytes()
    return Artifact(f"{provides_of(addon)}-v{version}.c3l", entries)


def tools_artifact(root: Path, version: str) -> Artifact:
    prefix = "c3d_shader_tools/"
    entries = {prefix + name: data for name, data in collect(root, TOOLS_FILES).items()}
    entries[prefix + "README.md"] = TOOLS_README.format(version=version).encode("utf-8")
    return Artifact(f"c3d_shader_tools-v{version}.zip", entries)


def artifacts(root: Path, version: str, pins: dict[str, str]) -> list[Artifact]:
    packed = [core_artifact(root, version, pins)]
    packed += [addon_artifact(root, addon, version, pins) for addon in sorted(ADDONS.glob("*.c3l"))]
    for artifact in packed:
        check_embeds(artifact.name, artifact.entries)
    return packed + [tools_artifact(root, version)]


def write_zip(path: Path, entries: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, ZIP_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o40755 if name.endswith("/") else 0o100644) << 16
            archive.writestr(info, entries[name])


def write_artifacts(packed: list[Artifact], out: Path) -> Path:
    out.mkdir(parents=True, exist_ok=True)
    sums: list[str] = []
    for artifact in packed:
        path = out / artifact.name
        write_zip(path, artifact.entries)
        sums.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {artifact.name}")
    checksums = out / "SHA256SUMS"
    checksums.write_text("\n".join(sorted(sums, key=lambda line: line.split("  ")[1])) + "\n", encoding="utf-8")
    return checksums


def pin_table(pins: dict[str, str]) -> str:
    lines = ["| Library | Version |", "| --- | --- |"]
    lines += [f"| `{name}` | {tag} |" for name, tag in pins.items()]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="pack c3d release artifacts")
    parser.add_argument("--version", required=True, help="release version, for example 0.1.0")
    parser.add_argument("--out", required=True, type=Path, help="output directory")
    parser.add_argument("--pins-table", type=Path, help="also write the dependency pin table (Markdown) here")
    arguments = parser.parse_args()

    try:
        if VERSION_PATTERN.fullmatch(arguments.version) is None:
            raise PackagingError(f"version {arguments.version!r} is not MAJOR.MINOR.PATCH")
        check_clean(ROOT)
        pins = resolve_pins(ROOT)
        packed = artifacts(ROOT, arguments.version, pins)
        write_artifacts(packed, arguments.out)
        if arguments.pins_table is not None:
            arguments.pins_table.write_text(pin_table(pins), encoding="utf-8")
    except PackagingError as error:
        print(f"[package] {error}", flush=True)
        return EXIT_FAILED
    print(f"[package] wrote {len(packed)} artifact(s) and SHA256SUMS to {arguments.out}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
