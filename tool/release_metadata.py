"""Derive TV release identity from pubspec, never legacy update-channel JSON."""

import os
from pathlib import Path
import sys

from version import ROOT, read_version


def tv_release_metadata(version, tag):
    name, build = version.split("+")
    if tag != f"tv_{name}":
        raise ValueError(f"TV release tag must be tv_{name} for pubspec {version}; got {tag!r}")
    return {"version": name, "package_version": version, "build_number": build,
            "release_name": f"Simple Live TV {version}"}


def main():
    version = read_version((ROOT / "simple_live_tv_app/pubspec.yaml").read_text(encoding="utf-8"))
    metadata = tv_release_metadata(version, os.environ["GITHUB_REF_NAME"])
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        for key, value in metadata.items():
            output.write(f"{key}={value}\n")
    print(f"TV release source: {version}; draft prerelease only")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print(f"Release metadata error: {error}", file=sys.stderr)
        sys.exit(1)
