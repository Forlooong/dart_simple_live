"""Verify built Apple installer metadata without changing or signing the bundle."""
import argparse
from pathlib import Path
import plistlib

BUNDLE_IDS = {"ios": "com.xycz.simple-live", "macos": "com.xycz.simpleLiveApp"}


def verify(platform, bundle, package_version):
    name, build = package_version.split("+")
    relative = "Contents/Info.plist" if platform == "macos" else "Info.plist"
    with (Path(bundle) / relative).open("rb") as source:
        values = plistlib.load(source)
    expected = {
        "CFBundleIdentifier": BUNDLE_IDS[platform],
        "CFBundleShortVersionString": name,
        "CFBundleVersion": build,
    }
    for key, value in expected.items():
        if str(values.get(key, "")) != value:
            raise ValueError(f"{platform} {key}: expected {value}, found {values.get(key)!r}")
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=BUNDLE_IDS)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("package_version")
    args = parser.parse_args()
    result = verify(args.platform, args.bundle, args.package_version)
    print(f"Verified {args.platform} bundle identity and version: {result}")


if __name__ == "__main__":
    main()
