#!/usr/bin/env python3
"""Download the benchmark scene assets that the repository does not carry.

  scripts/fetch_benchmark_assets.py            download missing or changed files
  scripts/fetch_benchmark_assets.py --force    download everything again

Assets land under examples/assets/benchmark/<model>/ and are gitignored: the
Sponza model files are under the Cryengine Limited License Agreement and must
not be redistributed from this repository. The source is pinned to one commit
of KhronosGroup/glTF-Sample-Assets so a benchmark names an exact asset.
"""

import argparse
import json
from pathlib import Path
import sys
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
DESTINATION = ROOT / "examples/assets/benchmark"
REPOSITORY = "KhronosGroup/glTF-Sample-Assets"
COMMIT = "723ffc6706725b618b8c14ceb82e3e6904b08a76"
MODELS = {"sponza": "Models/Sponza"}
USER_AGENT = "c3d-fetch-benchmark-assets"


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def list_directory(path):
    listing = json.loads(fetch(f"https://api.github.com/repos/{REPOSITORY}/contents/{path}?ref={COMMIT}"))
    return [entry for entry in listing if entry["type"] == "file"]


def download(entry, destination, force):
    if not force and destination.is_file() and destination.stat().st_size == entry["size"]:
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(fetch(entry["download_url"]))
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--force", action="store_true", help="download files even when a same-sized copy exists")
    args = parser.parse_args()
    downloaded = skipped = 0
    try:
        for name, path in MODELS.items():
            entries = list_directory(f"{path}/glTF")
            entries += [entry for entry in list_directory(path) if entry["name"] == "LICENSE.md"]
            for entry in entries:
                relative = Path(entry["path"]).relative_to(path)
                if download(entry, DESTINATION / name / relative, args.force):
                    downloaded += 1
                    print(f"downloaded {name}/{relative}", flush=True)
                else:
                    skipped += 1
    except urllib.error.URLError as error:
        print(f"download failed: {getattr(error, 'url', '')} {error}", file=sys.stderr)
        return 1
    print(f"downloaded {downloaded}, skipped {skipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
