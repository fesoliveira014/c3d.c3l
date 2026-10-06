"""Package-only mode of build_shaders.py, run from a tree shaped like the release's shader tools archive."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EMBED = re.compile(r'\$embed\("([^"]+)"\)')


class PackageModeTest(unittest.TestCase):
    def setUp(self) -> None:
        if shutil.which("glslangValidator") is None:
            self.skipTest("glslangValidator not on PATH")
        self.temporary = tempfile.TemporaryDirectory()
        self.tools = Path(self.temporary.name) / "tools"
        (self.tools / "scripts").mkdir(parents=True)
        shutil.copy2(ROOT / "scripts" / "build_shaders.py", self.tools / "scripts")
        for include_root in ("common", "generated", "gpu"):
            shutil.copytree(ROOT / "shaders" / include_root, self.tools / "shaders" / include_root)
        self.package = Path(self.temporary.name) / "package"
        shutil.copytree(
            ROOT / "test" / "shaders",
            self.package / "shaders",
            ignore=shutil.ignore_patterns("spv", "*.c3"),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_tools(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(self.tools / "scripts" / "build_shaders.py"), "--package", str(self.package)],
            capture_output=True,
            text=True,
        )

    def test_package_compiles_without_core_manifest_or_lib(self) -> None:
        result = self.run_tools()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        output = self.package / "shaders" / "shader_package.c3"
        paths = EMBED.findall(output.read_text(encoding="utf-8"))
        self.assertTrue(paths)
        for path in paths:
            self.assertTrue((output.parent / path).exists(), path)
        self.assertFalse((self.tools / "src").exists())
        self.assertFalse((self.tools / "shaders" / "spv").exists())

    def test_package_named_like_a_core_include_directory_fails(self) -> None:
        manifest_path = self.package / "shaders" / "shaders.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["module"] = "c3d::test::generated"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        include_root = self.package / "shaders" / "include"
        (include_root / "shader_package").rename(include_root / "generated")

        result = self.run_tools()

        self.assertEqual(result.returncode, 1)
        self.assertIn("is an include directory of core", result.stdout)


if __name__ == "__main__":
    unittest.main()
