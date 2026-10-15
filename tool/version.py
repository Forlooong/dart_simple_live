"""Keep committed app versions, the shared workflow title and artifacts in sync."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
APPS = {"main": "simple_live_app", "tv": "simple_live_tv_app"}
WORKFLOW = ".github/workflows/fork_all_platforms.yml"
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+([0-9]+)")
VERSION_LINE = re.compile(r"^version: *(.*?) *$", re.MULTILINE)
TITLE_LINE = re.compile(r"^run-name:.*$", re.MULTILINE)
DISPLAY_LINE = re.compile(r"^(?:name|run-name):.*$", re.MULTILINE)
ANDROID_ABI_OFFSET = 4000
ANDROID_MAX_VERSION_CODE = 2100000000
WINDOWS_MAX_COMPONENT = 65535


def read_version(text):
    matches = VERSION_LINE.findall(text)
    if len(matches) != 1 or not VERSION.fullmatch(matches[0]):
        raise ValueError("Expected one pubspec version in major.minor.patch+build format")
    return matches[0]


def version_parts(version):
    match = VERSION.fullmatch(version)
    if not match:
        raise ValueError("Expected a version in major.minor.patch+build format")
    values = tuple(map(int, match.groups()))
    return values[:3], values[3]


def validate_version(app, version):
    name, build = version_parts(version)
    if app == "main" and any(value > WINDOWS_MAX_COMPONENT for value in (*name, build)):
        raise ValueError(f"{app} version {version}: Windows version components must be <=65535")
    if build + ANDROID_ABI_OFFSET > ANDROID_MAX_VERSION_CODE:
        raise ValueError(
            f"{app} version {version}: Android build number + {ANDROID_ABI_OFFSET} "
            f"must be <={ANDROID_MAX_VERSION_CODE}"
        )


def read_versions(root):
    versions = {}
    for app, directory in APPS.items():
        version = read_version((root / directory / "pubspec.yaml").read_text(encoding="utf-8"))
        validate_version(app, version)
        versions[app] = version
    return versions


def workflow_title(versions):
    return (
        f'run-name: "Build all platforms · Main {versions["main"]} · TV {versions["tv"]} · #'
        + '${{ github.run_number }}"'
    )


def check_sync(root, app):
    versions = read_versions(root)
    if TITLE_LINE.findall((root / WORKFLOW).read_text(encoding="utf-8")) != [workflow_title(versions)]:
        raise ValueError(f"{WORKFLOW}: title does not match committed versions; run python tool/version.py sync both")
    return versions[app]


def update_versions(root, apps, bump):
    # Prepare and validate every edit before writing; a main-only bump preserves TV.
    edits = {}
    versions = read_versions(root)
    for app in apps:
        pubspec = root / APPS[app] / "pubspec.yaml"
        if bump:
            (major, minor, patch), build = version_parts(versions[app])
            versions[app] = f"{major}.{minor}.{patch + 1}+{build + 1}"
            validate_version(app, versions[app])
            text = pubspec.read_text(encoding="utf-8")
            edits[pubspec] = VERSION_LINE.sub(f"version: {versions[app]}", text)
    workflow = root / WORKFLOW
    text = workflow.read_text(encoding="utf-8")
    if len(TITLE_LINE.findall(text)) != 1:
        raise ValueError(f"{WORKFLOW}: expected one run-name")
    edits[workflow] = TITLE_LINE.sub(lambda _: workflow_title(versions), text)
    for path, text in edits.items():
        with path.open("w", encoding="utf-8", newline="\n") as output:
            output.write(text)
    return {app: versions[app] for app in apps}


def git(root, *args):
    result = subprocess.run(
        ["git", "-C", str(root), *args], capture_output=True, text=True, encoding="utf-8"
    )
    if result.returncode:
        raise ValueError(result.stderr.strip() or "Git command failed")
    return result.stdout


def input_paths(app):
    return (APPS[app], "simple_live_core", "packages", ".github/actions", "tool", WORKFLOW)


def committed_file(root, commit, path):
    if not git(root, "ls-tree", "--name-only", commit, "--", path).strip():
        return ""
    return git(root, "show", f"{commit}:{path}")


def input_changes(root, app, base, target=None):
    revisions = (base, target) if target else (base,)
    changed = git(root, "diff", "--name-only", "-z", *revisions, "--", *input_paths(app))
    paths = set(changed.rstrip("\0").split("\0")) if changed else set()
    if paths - {WORKFLOW}:
        return True
    if WORKFLOW not in paths:
        return False
    before = committed_file(root, base, WORKFLOW)
    if target:
        after = committed_file(root, target, WORKFLOW)
    else:
        path = root / WORKFLOW
        after = path.read_text(encoding="utf-8") if path.exists() else ""
    # Top-level display labels do not change installers. Nested job/step names
    # and all other workflow content remain guarded build inputs.
    return DISPLAY_LINE.sub("<display metadata>", before) != DISPLAY_LINE.sub("<display metadata>", after)


def check_changes(root, app, base):
    if not re.fullmatch(r"[0-9a-fA-F]{40}", base):
        raise ValueError("Base must be a full Git commit SHA")
    if not input_changes(root, app, base):
        return
    old_text = committed_file(root, base, f"{APPS[app]}/pubspec.yaml")
    if not old_text:
        # A newly introduced app has no earlier package version to increase.
        return
    old = read_version(old_text)
    new = read_version((root / APPS[app] / "pubspec.yaml").read_text(encoding="utf-8"))
    validate_version(app, new)
    old_name, old_build = version_parts(old)
    new_name, new_build = version_parts(new)
    if new_name <= old_name or new_build <= old_build:
        raise ValueError(
            f"{app} source changed, but both version name and build number must increase "
            f"({old} -> {new}). Run python tool/version.py bump {app} before committing."
        )


def check_history(root, app):
    """Prevent manual runs (including after docs commits) from bypassing the guard.

    Check the latest installer-affecting first-parent commit against its parent.
    A corrective bump after an unversioned change is allowed. Conversely, a bump
    committed before a later input change needs another bump. Full history is
    required so a shallow boundary cannot silently become a trusted baseline.
    """
    if git(root, "rev-parse", "--is-shallow-repository").strip() != "false":
        raise ValueError("Version history guard requires full Git history; use checkout fetch-depth: 0")
    head = git(root, "rev-parse", "HEAD").strip()
    check_changes(root, app, head)
    commits = git(root, "log", "--first-parent", "--format=%H", "HEAD", "--", *input_paths(app))
    for commit in commits.splitlines():
        parents = git(root, "rev-list", "--parents", "-n", "1", commit).split()[1:]
        if not parents:
            return  # Initial repository contents establish the first version.
        parent = parents[0]
        if input_changes(root, app, parent, commit):
            check_changes(root, app, parent)
            return


def build_metadata(version, environment, app="main"):
    validate_version(app, version)
    sha = environment["GITHUB_SHA"]
    run = environment["GITHUB_RUN_NUMBER"]
    attempt = environment["GITHUB_RUN_ATTEMPT"]
    if (
        not re.fullmatch(r"[0-9a-fA-F]{40}", sha)
        or not re.fullmatch(r"[1-9][0-9]*", run)
        or not re.fullmatch(r"[1-9][0-9]*", attempt)
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
        if args.command == "metadata":
            check_history(ROOT, app)
        print(f"{app}: {version} (synchronized)")
    if args.command == "metadata":
        metadata = build_metadata(version, os.environ, apps[0])
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
