"""Keep committed app versions, workflow titles and build artifacts in sync."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
APPS = {
    "main": (
        "simple_live_app",
        {
            "fork_android_apk.yml": "Android",
            "fork_ios.yml": "iOS",
            "fork_macos.yml": "macOS",
            "fork_windows.yml": "Windows",
            "fork_linux.yml": "Linux",
        },
    ),
    "tv": ("simple_live_tv_app", {"fork_tv_apk.yml": "TV"}),
}
VERSION_LINE = re.compile(r"^version: *(\d+\.\d+\.\d+\+\d+) *$", re.MULTILINE)
TITLE_LINE = re.compile(r"^run-name:.*$", re.MULTILINE)


def read_version(text):
    matches = VERSION_LINE.findall(text)
    if len(matches) != 1:
        raise ValueError("Expected one pubspec version in major.minor.patch+build format")
    return matches[0]


def version_parts(version):
    name, build = version.split("+")
    return tuple(map(int, name.split("."))), int(build)


def workflow_title(platform, version):
    return f'run-name: "Release {platform} · {version} · #' + '${{ github.run_number }}"'


def check_sync(root, app):
    directory, workflows = APPS[app]
    version = read_version((root / directory / "pubspec.yaml").read_text(encoding="utf-8"))
    for filename, platform in workflows.items():
        path = root / ".github/workflows" / filename
        if TITLE_LINE.findall(path.read_text(encoding="utf-8")) != [workflow_title(platform, version)]:
            raise ValueError(f"{filename}: title does not match {version}; run python tool/version.py sync {app}")
    return version


def update_versions(root, apps, bump):
    # Prepare every edit before writing, so malformed files cannot cause a partial bump.
    edits = {}
    versions = {}
    for app in apps:
        directory, workflows = APPS[app]
        pubspec = root / directory / "pubspec.yaml"
        text = pubspec.read_text(encoding="utf-8")
        version = read_version(text)
        if bump:
            (major, minor, patch), build = version_parts(version)
            version = f"{major}.{minor}.{patch + 1}+{build + 1}"
            edits[pubspec] = VERSION_LINE.sub(f"version: {version}", text)
        versions[app] = version
        for filename, platform in workflows.items():
            path = root / ".github/workflows" / filename
            text = path.read_text(encoding="utf-8")
            if len(TITLE_LINE.findall(text)) != 1:
                raise ValueError(f"{filename}: expected one run-name")
            edits[path] = TITLE_LINE.sub(lambda _: workflow_title(platform, version), text)
    for path, text in edits.items():
        with path.open("w", encoding="utf-8", newline="\n") as output:
            output.write(text)
    return versions


def git(root, *args):
    result = subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True, encoding="utf-8"
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or "Git command failed")
    return result.stdout


def check_changes(root, app, base):
    if not re.fullmatch(r"[0-9a-fA-F]{40}", base):
        raise ValueError("Base must be a full Git commit SHA")
    directory, _ = APPS[app]
    changed = git(root, "diff", "--name-only", base, "--", directory, "simple_live_core", "packages")
    if not changed.strip():
        return
    old = read_version(git(root, "show", f"{base}:{directory}/pubspec.yaml"))
    new = read_version((root / directory / "pubspec.yaml").read_text(encoding="utf-8"))
    old_name, old_build = version_parts(old)
    new_name, new_build = version_parts(new)
    if new_name <= old_name or new_build <= old_build:
        raise ValueError(
            f"{app} source changed, but both version name and build number must increase "
            f"({old} -> {new}). Run python tool/version.py bump {app} before committing."
        )


def build_metadata(version, environment):
    sha = environment["GITHUB_SHA"]
    run = environment["GITHUB_RUN_NUMBER"]
    attempt = environment["GITHUB_RUN_ATTEMPT"]
    if (
        not re.fullmatch(r"[0-9a-fA-F]{40}", sha)
        or not re.fullmatch(r"[1-9]\d*", run)
        or not re.fullmatch(r"[1-9]\d*", attempt)
    ):
        raise ValueError("Invalid GitHub build identity")
    name, build = version.split("+")
    return {
        "version": name,
        "build_number": build,
        "package_version": version,
        "artifact_version": f"{version}-r{run}.{attempt}-{sha[:7]}",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("bump", "sync", "check", "metadata"))
    parser.add_argument("app", choices=(*APPS, "both"), nargs="?", default="main")
    parser.add_argument("--base", help="Compare changed source against this full commit SHA")
    args = parser.parse_args()
    apps = tuple(APPS) if args.app == "both" else (args.app,)
    if args.command in ("bump", "sync"):
        for app, version in update_versions(ROOT, apps, bump=args.command == "bump").items():
            print(f"{app}: {version}")
        return

    if args.command == "metadata" and len(apps) != 1:
        raise ValueError("Build metadata requires exactly one app")
    base = args.base
    if args.command == "metadata" and os.environ.get("GITHUB_EVENT_NAME") == "push":
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        before = event.get("before", "")
        if before and before != "0" * 40:
            base = before
    for app in apps:
        version = check_sync(ROOT, app)
        if base:
            check_changes(ROOT, app, base)
        print(f"{app}: {version} (synchronized)")
    if args.command == "metadata":
        metadata = build_metadata(version, os.environ)
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            for key, value in metadata.items():
                output.write(f"{key}={value}\n")
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
            output.write(
                "## Build identity\n\n"
                f"- Package version: `{version}`\n"
                f"- Artifact version: `{metadata['artifact_version']}`\n"
                f"- Commit: `{os.environ['GITHUB_SHA']}`\n\n"
            )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print(f"Version error: {error}", file=sys.stderr)
        sys.exit(1)
