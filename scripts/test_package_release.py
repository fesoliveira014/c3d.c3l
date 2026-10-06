"""Release packing: artifact set, manifests, file selection, embed resolution and dependency pins."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import package_release  # noqa: E402

ROOT = package_release.ROOT
VERSION = "0.1.0"
PINS = {"b3": "v0.4.0", "clay": "v0.1.1", "gpu": "v0.7.0", "sdl3": "v0.1.0", "shaderc": "v0.1.0", "vk": "v0.1.0"}
FORBIDDEN_PREFIXES = ("test/", "tests/", "examples/", "lib/", "build/", "images/", "test_order/")


def tagged_everywhere(arguments: list[str], cwd: Path) -> str:
    if arguments[0] == "rev-parse":
        return "1" * 40 + "\n"
    return f"{'1' * 40}\trefs/tags/v9.9.9\n"


class PackReleaseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not (ROOT / "shaders" / "spv").is_dir():
            raise unittest.SkipTest("shaders/spv missing; run scripts/build.py first")
        cls.packed = package_release.artifacts(ROOT, VERSION, PINS)

    def test_every_package_packs_with_its_manifest_at_the_root(self) -> None:
        addons = sorted(path for path in (ROOT / "addons").glob("*.c3l"))
        expected = {"c3d_core-v0.1.0.c3l", "c3d_shader_tools-v0.1.0.zip"}
        expected |= {f"{package_release.provides_of(addon)}-v0.1.0.c3l" for addon in addons}
        self.assertEqual({artifact.name for artifact in self.packed}, expected)
        self.assertEqual(len(expected), 13)

        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            checksums = package_release.write_artifacts(self.packed, Path(first))
            package_release.write_artifacts(self.packed, Path(second))
            for line in checksums.read_text(encoding="utf-8").splitlines():
                digest, name = line.split("  ")
                data = (Path(first) / name).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
                self.assertEqual(data, (Path(second) / name).read_bytes(), name)
                if name.endswith(".c3l"):
                    with zipfile.ZipFile(Path(first) / name) as archive:
                        manifest = json.loads(archive.read("manifest.json"))
                    self.assertEqual(manifest["vendor"]["c3d"]["version"], VERSION)

    def test_core_manifest_pins_only_its_dependencies(self) -> None:
        core = next(artifact for artifact in self.packed if artifact.name.startswith("c3d_core-"))
        manifest = json.loads(core.entries["manifest.json"])
        self.assertEqual(manifest["provides"], "c3d")
        self.assertEqual(manifest["vendor"]["c3d"]["requires"], {"gpu": "v0.7.0", "sdl3": "v0.1.0", "vk": "v0.1.0"})

    def test_packed_libraries_carry_no_repository_only_files(self) -> None:
        for artifact in self.packed:
            for entry in artifact.entries:
                relative = entry.removeprefix("c3d_shader_tools/")
                self.assertFalse(relative.startswith(FORBIDDEN_PREFIXES), f"{artifact.name}: {entry}")
                self.assertNotEqual(Path(entry).name, "project.json", f"{artifact.name}: {entry}")

    def test_missing_embed_target_fails_naming_the_file(self) -> None:
        entries = {"src/shaders.c3": b'const char[*] DATA = $embed("../shaders/spv/missing.spv");'}

        with self.assertRaisesRegex(package_release.PackagingError, "src/shaders.c3 embeds ../shaders/spv/missing.spv"):
            package_release.check_embeds("c3d_example-v0.1.0.c3l", entries)

    def test_submodule_off_a_tag_fails(self) -> None:
        def untagged(arguments: list[str], cwd: Path) -> str:
            if arguments[0] == "rev-parse":
                return "2" * 40 + "\n"
            return f"{'1' * 40}\trefs/tags/v0.1.0\n"

        with self.assertRaisesRegex(package_release.PackagingError, "lib/sdl3.c3l is at 2222222"):
            package_release.release_tag(ROOT, "lib/sdl3.c3l", "https://example.invalid/sdl3.c3l", untagged)

    def test_annotated_version_tag_resolves_through_its_peeled_commit(self) -> None:
        def annotated(arguments: list[str], cwd: Path) -> str:
            if arguments[0] == "rev-parse":
                return "3" * 40 + "\n"
            return (
                f"{'3' * 40}\trefs/tags/nightly\n"
                f"{'4' * 40}\trefs/tags/v0.2.0\n"
                f"{'3' * 40}\trefs/tags/v0.2.0^{{}}\n"
            )

        tag = package_release.release_tag(ROOT, "lib/sdl3.c3l", "https://example.invalid/sdl3.c3l", annotated)

        self.assertEqual(tag, "v0.2.0")

    def test_pins_include_the_gpu_backends(self) -> None:
        pins = package_release.resolve_pins(ROOT, tagged_everywhere)

        for name in ("gpu", "vk", "vma", "spvreflect", "sdl3", "c3imgui", "c3cg", "cgltf", "ufbx", "b3", "clay", "shaderc"):
            self.assertEqual(pins.get(name), "v9.9.9", name)


if __name__ == "__main__":
    unittest.main()
