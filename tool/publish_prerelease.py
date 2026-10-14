"""Publish one explicitly enabled, reviewed set of six SHA-bound CI artifacts.

Only this publisher's workflow supplies GH_TOKEN. Downloaded binaries are never
executed. No overwrite/delete, force-push, credential creation, or CI dispatch.
"""

import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "Forlooong/dart_simple_live"
BRANCH = "fix/known-issues-release"
API = f"https://api.github.com/repos/{REPOSITORY}"
UPLOAD = f"https://uploads.github.com/repos/{REPOSITORY}"
MAX_FILE = 2 * 1024**3
MAX_EXPANDED = 8 * 1024**3
MAX_ENTRIES = 100000
PUBLISHER_FILES = {
    ".github/workflows/publish_verified_prerelease.yml",
    "tool/prerelease-target.json", "tool/publish_prerelease.py",
    "tool/test_publish_prerelease.py", "docs/verified-prerelease.md",
}
PLATFORMS = {
    "android": ("fork_android_apk.yml", "android-apk", "Android-Release", [
        "Check player and notification code", "Test player lifecycle and live notifications",
        "Build release APKs", "Verify every native library, ABI and APK ZIP alignment",
        "Verify APK signatures and prepare artifacts", "Upload installable APKs"]),
    "tv": ("fork_tv_apk.yml", "tv-apk", "Android-TV-Release", [
        "Test TV danmaku batching and follow polling", "Build release APKs",
        "Verify every native library, ABI and APK ZIP alignment",
        "Verify APK signatures and prepare artifacts", "Upload installable APKs"]),
    "ios": ("fork_ios.yml", "build", "iOS-arm64-Unsigned", [
        "Test native assets on iOS simulator", "Build unsigned iOS app",
        "Verify device native libraries", "Package unsigned IPA", "Upload iOS package"]),
    "macos": ("fork_macos.yml", "build", "macOS-universal-Unsigned", [
        "Build console with native asset bundle", "Build unsigned universal macOS app",
        "Verify both native library architectures", "Package macOS app", "Upload macOS package"]),
    "windows": ("fork_windows.yml", "build", "Windows-x64-Unsigned", [
        "Build console with native asset bundle", "Build Windows release",
        "Load bundled native ABI", "Package portable Windows app", "Upload Windows package"]),
    "linux": ("fork_linux.yml", "build", "Linux-x64-Release", [
        "Build console with native asset bundle", "Build Linux release",
        "Load bundled native ABI", "Package Linux bundle", "Upload Linux package"]),
}
COMMON_STEPS = ["Check version and prepare build identity", "Run ./.github/actions/check-native"]
ABIS = {"arm64": ("arm64-v8a", 2000), "arm32": ("armeabi-v7a", 1000), "x64": ("x86_64", 4000)}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def command(*args):
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, check=False)
    require(result.returncode == 0, f"{args[0]} failed: {result.stderr[:1000]}")
    return result.stdout


def validate_plan(plan):
    require(set(plan) == {"enabled", "source_sha", "main_version", "tv_version", "runs"}, "Unexpected target fields")
    require(type(plan["enabled"]) is bool, "enabled must be a boolean")
    require(bool(re.fullmatch(r"[0-9a-f]{40}", plan["source_sha"])), "Require full immutable source SHA")
    for key in ("main_version", "tv_version"):
        require(bool(re.fullmatch(r"\d+\.\d+\.\d+\+[1-9]\d*", plan[key])), f"Invalid {key}")
    require(set(plan["runs"]) == set(PLATFORMS), "Exactly six platforms required")
    ids = []
    for platform, pin in plan["runs"].items():
        keys = {"id", "attempt", "signing"} if platform in ("android", "tv") else {"id", "attempt"}
        require(set(pin) == keys, f"Unexpected {platform} pin fields")
        for key in ("id", "attempt"):
            require(type(pin[key]) is int and pin[key] >= (1 if plan["enabled"] else 0), f"Invalid {platform} {key}")
        if "signing" in pin:
            require(pin["signing"] in ("TestSigned", "ReleaseSigned"), "Explicit signing label required")
        ids.append(pin["id"])
    if plan["enabled"]:
        require(len(set(ids)) == 6, "Each platform must pin a distinct workflow run")


def release_tag(plan):
    return f"repair-pre-{plan['main_version'].replace('+', '-build')}-{plan['source_sha'][:12]}"


def validate_context(plan, env):
    require(env.get("GITHUB_REPOSITORY") == REPOSITORY, "Wrong publishing repository")
    require(env.get("GITHUB_EVENT_NAME") == "push", "Only a trusted branch push may publish")
    require(env.get("GITHUB_REF") == f"refs/heads/{BRANCH}", "Wrong publishing branch")
    head = env.get("GITHUB_SHA", "")
    require(bool(re.fullmatch(r"[0-9a-f]{40}", head)), "Invalid publishing SHA")
    require(command("git", "rev-parse", "HEAD").strip() == head, "Checkout does not match publisher SHA")
    source = plan["source_sha"]
    command("git", "merge-base", "--is-ancestor", source, head)
    changed = set(filter(None, command("git", "diff", "--name-only", source, head, "--").splitlines()))
    require(changed <= PUBLISHER_FILES, "Publisher commit includes changes to unbuilt source/build files")
    for directory, key in (("simple_live_app", "main_version"), ("simple_live_tv_app", "tv_version")):
        text = command("git", "show", f"{source}:{directory}/pubspec.yaml")
        require(re.findall(r"^version: *(\S+) *$", text, re.M) == [plan[key]], f"Source {key} mismatch")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


class GitHub:
    def __init__(self, token):
        require(bool(token), "Missing ephemeral GH_TOKEN")
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, path, method="GET", value=None, file=None, accept="application/vnd.github+json", allow_missing=False):
        # Caller-controlled paths are only repository-relative API paths, never URLs.
        require(path.startswith("/") and not path.startswith("//"), "Invalid API path")
        data = json_bytes(value) if value is not None else None
        headers = {"Authorization": "Bearer " + self.token, "Accept": accept,
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "verified-prerelease"}
        base = API
        if file is not None:
            base = UPLOAD
            headers.update({"Content-Type": "application/octet-stream", "Content-Length": str(file.stat().st_size)})
            data = file.open("rb")
        elif value is not None:
            headers["Content-Type"] = "application/json"
        try:
            request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
            with self.opener.open(request, timeout=300) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if allow_missing and error.code == 404:
                return None
            # Do not log response URLs, which may contain signed download credentials.
            raise ValueError(f"GitHub {method} failed with HTTP {error.code}") from None
        finally:
            if file is not None:
                data.close()

    def pages(self, path, key=None):
        result = []
        for page in range(1, 101):
            value = self.request(f"{path}{'&' if '?' in path else '?'}per_page=100&page={page}")
            items = value[key] if key else value
            require(isinstance(items, list), "Invalid paginated API response")
            result.extend(items)
            if len(items) < 100:
                return result
        raise ValueError("API pagination exceeded safety limit")

    def download(self, artifact_id, path):
        request = urllib.request.Request(API + f"/actions/artifacts/{artifact_id}/zip", headers={
            "Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "verified-prerelease"})
        try:
            response = self.opener.open(request, timeout=60)
        except urllib.error.HTTPError as error:
            require(error.code in (301, 302, 303, 307, 308), f"Artifact download failed: HTTP {error.code}")
            url = error.headers.get("Location", "")
            # The GitHub API authenticates this redirect. Never forward GH_TOKEN.
            for _ in range(5):
                parsed = urllib.parse.urlsplit(url)
                require(parsed.scheme == "https" and parsed.hostname and not parsed.username and not parsed.password,
                        "Unsafe artifact download redirect")
                try:
                    response = self.opener.open(urllib.request.Request(url), timeout=300)
                    break
                except urllib.error.HTTPError as redirect:
                    require(redirect.code in (301, 302, 303, 307, 308), f"Artifact storage failed: HTTP {redirect.code}")
                    url = urllib.parse.urljoin(url, redirect.headers.get("Location", ""))
            else:
                raise ValueError("Too many artifact download redirects")
        with response, path.open("xb") as output:
            size = 0
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                require(size <= MAX_FILE, "Artifact exceeds compressed size limit")
                output.write(chunk)


def validate_run(platform, run, jobs, plan):
    pin = plan["runs"][platform]
    workflow, expected_job, _, expected_steps = PLATFORMS[platform]
    require(run["id"] == pin["id"] and run["run_attempt"] == pin["attempt"], f"{platform}: run attempt changed")
    require(run["head_sha"] == plan["source_sha"] and run["head_branch"] == BRANCH, f"{platform}: wrong source")
    require(run["event"] == "push", f"{platform}: untrusted run event")
    # A trusted branch push may be associated with a PR. The event and exact
    # repository/branch checks exclude pull_request and pull_request_target runs.
    require(run["repository"]["full_name"] == REPOSITORY and run["head_repository"]["full_name"] == REPOSITORY,
            f"{platform}: foreign repository")
    require(run["path"] == f".github/workflows/{workflow}", f"{platform}: wrong workflow")
    require(run["status"] == "completed" and run["conclusion"] == "success", f"{platform}: workflow is not successful")
    require(len(jobs) == 1 and jobs[0]["name"] == expected_job, f"{platform}: unexpected/missing jobs")
    job = jobs[0]
    require(job["status"] == "completed" and job["conclusion"] == "success", f"{platform}: job failed or skipped")
    require(job.get("run_attempt") == pin["attempt"] and job["head_sha"] == plan["source_sha"], f"{platform}: job identity mismatch")
    for name in COMMON_STEPS + expected_steps:
        steps = [step for step in job["steps"] if step["name"] == name]
        require(len(steps) == 1 and steps[0]["status"] == "completed" and steps[0]["conclusion"] == "success",
                f"{platform}: expected gate failed, skipped or missing: {name}")


def artifact_identity(platform, run, plan):
    version = plan["tv_version" if platform == "tv" else "main_version"]
    identity = f"{version}-r{run['run_number']}.{run['run_attempt']}-{plan['source_sha'][:7]}"
    suffix = PLATFORMS[platform][2]
    if platform in ("android", "tv"):
        suffix += "-" + plan["runs"][platform]["signing"]
    return identity, f"Simple-Live-{identity}-{suffix}"


def choose_artifact(platform, artifacts, run, plan):
    _, expected = artifact_identity(platform, run, plan)
    matches = [artifact for artifact in artifacts if artifact["name"] == expected]
    require(len(matches) == 1, f"{platform}: missing or ambiguous artifact {expected}")
    artifact = matches[0]
    require(not artifact["expired"] and 0 < artifact["size_in_bytes"] <= MAX_FILE, f"{platform}: empty, expired or oversized artifact")
    expires = dt.datetime.fromisoformat(artifact["expires_at"].replace("Z", "+00:00"))
    require(expires > dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=45), f"{platform}: artifact too close to expiry")
    require(bool(re.fullmatch(r"sha256:[0-9a-f]{64}", (artifact.get("digest") or ""))), f"{platform}: missing archive SHA-256")
    provenance = artifact["workflow_run"]
    require(provenance["id"] == run["id"] and provenance["head_sha"] == plan["source_sha"]
            and provenance["head_branch"] == BRANCH
            and provenance["repository_id"] == run["repository"]["id"]
            and provenance["head_repository_id"] == run["repository"]["id"], f"{platform}: artifact source mismatch")
    created = dt.datetime.fromisoformat(artifact["created_at"].replace("Z", "+00:00"))
    started = dt.datetime.fromisoformat(run["run_started_at"].replace("Z", "+00:00"))
    require(created >= started, f"{platform}: artifact predates pinned attempt")
    return artifact


def safe_member(name):
    require(name and "\\" not in name and "\x00" not in name and not name.startswith("/"), "Unsafe archive path")
    parts = PurePosixPath(name).parts
    require(not any(part == ".." or ":" in part for part in parts), "Archive path escapes root")
    return str(PurePosixPath(name))


def inspect_zip(path, flat=False):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(len(entries) <= MAX_ENTRIES, "Too many ZIP entries")
        names = set()
        expanded = 0
        for entry in entries:
            name = safe_member(entry.filename)
            require(name not in names, "Duplicate ZIP entry")
            names.add(name)
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), "Special ZIP file forbidden")
            if flat:
                require(not entry.is_dir() and "/" not in name and kind != stat.S_IFLNK, "Actions artifact must contain flat regular files")
            expanded += entry.file_size
            require(entry.file_size <= MAX_FILE and expanded <= MAX_EXPANDED, "ZIP expanded size limit")
            require(not entry.flag_bits & 1 and entry.file_size <= max(entry.compress_size, 1) * 1000, "Encrypted or excessive-ratio ZIP")
            if kind == stat.S_IFLNK:
                require(entry.file_size <= 4096, "Oversized symlink")
                safe_member(archive.read(entry).decode("utf-8"))
            else:
                # Read to EOF for CRC integrity without extracting/executing code.
                with archive.open(entry) as stream:
                    while stream.read(1024 * 1024):
                        pass
        return names


def inspect_tar(path):
    expanded, count, seen = 0, 0, set()
    with tarfile.open(path, "r|gz") as archive:
        for entry in archive:
            name = safe_member(entry.name)
            require(name not in seen, "Duplicate tar entry")
            seen.add(name)
            count += 1
            expanded += entry.size
            require(count <= MAX_ENTRIES and entry.size <= MAX_FILE and expanded <= MAX_EXPANDED, "tar expansion limit")
            require(entry.isfile() or entry.isdir() or entry.issym(), "Special/hardlink tar entry forbidden")
            if entry.issym():
                safe_member(entry.linkname)
            if entry.isfile():
                with archive.extractfile(entry) as stream:
                    while stream.read(1024 * 1024):
                        pass
    require(expanded <= max(path.stat().st_size, 1) * 1000, "Excessive-ratio tar")


def expected_packages(platform, identity, plan):
    prefix = f"Simple-Live-{identity}-"
    if platform in ("android", "tv"):
        label = plan["runs"][platform]["signing"]
        device = "Android-TV" if platform == "tv" else "Android"
        return {f"{prefix}{device}-{arch}-{label}.apk" for arch in ABIS}
    suffix = {"ios": "iOS-arm64-Unsigned.ipa", "macos": "macOS-universal-Unsigned.zip",
              "windows": "Windows-x64-Unsigned.zip", "linux": "Linux-x64.tar.gz"}[platform]
    return {prefix + suffix}


def parse_sums(text):
    sums = {}
    for line in text.lstrip("\ufeff").splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *]([^/\\]+)", line)
        require(match is not None and match[2] not in sums, "Invalid or duplicate SHA256SUMS line")
        sums[match[2]] = "sha256:" + match[1].lower()
    return sums


def sdk_tools():
    root = Path(os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME") or "/missing")
    versions = [path for path in (root / "build-tools").glob("*") if re.fullmatch(r"\d+\.\d+\.\d+", path.name)]
    require(bool(versions), "Android SDK build tools unavailable; cannot verify APK bytes")
    directory = max(versions, key=lambda path: tuple(map(int, path.name.split("."))))
    result = {name: str(directory / name) for name in ("apksigner", "aapt2", "zipalign")}
    require(all(os.access(path, os.X_OK) for path in result.values()), "Required Android SDK verifier unavailable")
    return result


def certificate_digest(text):
    matches = re.findall(r"^Signer #1 certificate SHA-256 digest: ([0-9a-fA-F]{64})$", text, re.M)
    require(len(matches) == 1 and not re.search(r"^Signer #(?:[2-9]|\d\d)", text, re.M), "Require one unambiguous APK signer")
    return matches[0].lower()


def validate_badging(text, version, abi, offset, package):
    name, build = version.split("+")
    lines = [line for line in text.splitlines() if line.startswith("package:")]
    require(len(lines) == 1, "APK manifest missing or ambiguous")
    values = dict(re.findall(r"(\w+)='([^']*)'", lines[0]))
    require(values.get("name") == package and values.get("versionName") == name
            and values.get("versionCode") == str(int(build) + offset), "APK byte-derived package/version mismatch")
    native = re.findall(r"^native-code: (.*)$", text, re.M)
    require(len(native) == 1 and re.findall(r"'([^']+)'", native[0]) == [abi], "APK byte-derived ABI mismatch")


def verify_apk_bytes(path, platform, identity, plan, files, tools):
    arch = next(arch for arch in ABIS if f"-{arch}-" in path.name)
    abi, offset = ABIS[arch]
    version = plan["tv_version" if platform == "tv" else "main_version"]
    package = "com.xycz.simple_live_tv" if platform == "tv" else "com.xycz.simple_live"
    cert = command(tools["apksigner"], "verify", "--print-certs", str(path))
    signer = certificate_digest(cert)
    require(signer == certificate_digest(files[f"{abi}-SIGNING-CERT.txt"].decode()), "APK cert differs from CI certificate evidence")
    badging = command(tools["aapt2"], "dump", "badging", str(path))
    validate_badging(badging, version, abi, offset, package)
    command(tools["zipalign"], "-c", "-P", "16", "4", str(path))
    # Only a static APK parser from the reviewed publisher checkout is imported.
    from verify_native_bundle import verify_apk
    verify_apk(path, abi)
    expected_mode = "debug-signed-test-only" if plan["runs"][platform]["signing"] == "TestSigned" else "release-signed"
    info = files["BUILD-INFO.txt"].decode()
    for field in (f"Commit: {plan['source_sha']}", f"Source version: {version}", f"Artifact version: {identity}",
                  f"Signing: {expected_mode}", f"Package: {package}"):
        require(info.splitlines().count(field) == 1, "APK build metadata mismatch")
    return {"certificate_sha256": signer, "signature_verified": True, "manifest_verified": True,
            "native_static_verified": True, "zipalign_16k_verified": True,
            "signing_label": plan["runs"][platform]["signing"], "historical_certificate_match": "not verified",
            "device_installation": "not tested"}


def prepare_artifact(platform, archive_path, output, run, plan, tools):
    identity, _ = artifact_identity(platform, run, plan)
    names = inspect_zip(archive_path, flat=True)
    packages = expected_packages(platform, identity, plan)
    metadata = {"SHA256SUMS.txt"}
    if platform in ("android", "tv"):
        metadata |= {"BUILD-INFO.txt", "FLUTTER-VERSION.txt", "pubspec.lock"}
        metadata |= {f"{abi}-{kind}.txt" for abi, _ in ABIS.values() for kind in ("SIGNING-CERT", "VERSION")}
        if platform == "android":
            metadata.add("arm64-SHA256SUMS.txt")
    elif platform == "windows":
        metadata.add("BUILD-INFO.txt")
    require(names == packages | metadata, f"{platform}: missing or unexpected artifact contents")
    with zipfile.ZipFile(archive_path) as archive:
        files = {}
        for name in metadata:
            require(archive.getinfo(name).file_size <= 2 * 1024**2, "Oversized metadata")
            files[name] = archive.read(name)
        sums = parse_sums(files["SHA256SUMS.txt"].decode("utf-8-sig"))
        require(set(sums) == packages, f"{platform}: checksum list does not match package set")
        records = []
        for name in sorted(packages):
            path = output / name
            with archive.open(name) as source, path.open("xb") as destination:
                while chunk := source.read(1024 * 1024):
                    destination.write(chunk)
            digest = digest_file(path)
            require(digest == sums[name], f"{platform}: package checksum mismatch")
            if name.endswith(".tar.gz"):
                inspect_tar(path)
            else:
                inspect_zip(path)
            record = {"name": name, "sha256": digest, "size": path.stat().st_size, "platform": platform}
            if name.endswith(".apk"):
                record["apk_verification"] = verify_apk_bytes(path, platform, identity, plan, files, tools)
            records.append(record)
        if platform in ("android", "tv"):
            require(len({record["apk_verification"]["certificate_sha256"] for record in records}) == 1,
                    "Split APKs have inconsistent signing certificates")
        for name, data in sorted(files.items()):
            target = output / f"{platform}-{name}"
            target.write_bytes(data)
        return records


def notes(plan, provenance):
    lines = [f"Simple Live {plan['main_version']} repair prerelease; TV {plan['tv_version']}", "",
             f"Source commit: {plan['source_sha']}", "",
             "This is a qualified test prerelease, not a stable or universally compatible release.",
             "All six pinned source-SHA build workflows and required automated gates succeeded. Artifact archives and packages passed SHA-256 checks. APK signatures, manifest identities/versions, static native ABI/alignment and ZIP alignment were checked again during publication.", "",
             "Signing and data safety:",
             "- Android / TV: labels and certificate fingerprints are recorded per APK in PROVENANCE.json. TestSigned is release-mode code signed by an ephemeral test key; it cannot update an installation with a different certificate, including the known old 1.12.5 installation. ReleaseSigned alone would not prove a historical certificate match. No installed-certificate match is claimed.",
             "- Keep your existing app/data. For the main app, export follows from the follow page AND export settings via Settings → Other → Export configuration separately. Settings export does not include follows. Verify both files outside the app before any user-chosen uninstall. These are not complete account/session/history backups. Uninstall deletes local data; nothing here uninstalls automatically.",
             "- TV: verify an available backup/migration route before replacing an existing installation; do not assume the main-app export UI exists on TV.",
             "- iOS is unsigned and needs authorized Apple signing. macOS is unsigned and unnotarized. Windows is unsigned and needs Microsoft Visual C++ x64 runtime. Linux needs GTK 3 and libmpv. Extract complete desktop bundles.", "",
             "Validation limits and known unresolved issues:",
             "- No installed-device or 16 KiB Android runtime smoke test has been performed here. Static checks do not guarantee playback, all phones/tablets/TVs, operating systems or ABI combinations. macOS universal means packaged arm64+x64, not universal device compatibility.",
             "- The frequent Android spinner/buffering symptom has no established root cause; this prerelease does not claim to resolve every stall.",
             "- TV legacy playback risks remain pending: duplicate error/EOF recovery, stale asynchronous work after room changes/disposal, reused expiring stream URLs, incomplete native command serialization and force-seekable compatibility. Packaging success does not mean these defects were repaired.", "",
             "Pinned build evidence:"]
    for platform, item in sorted(provenance.items()):
        lines.append(f"- {platform}: https://github.com/{REPOSITORY}/actions/runs/{item['run_id']}/attempts/{item['run_attempt']} (artifact {item['artifact_id']})")
    lines += ["", "Verify downloaded files against SHA256SUMS.txt. PROVENANCE.json records the exact source, workflow attempts, Actions archive digests and package verification. Source APK signing, native static checks and real-device validation are distinct.", ""]
    return "\n".join(lines)


def validate_existing_release(release, plan, body):
    require(release["tag_name"] == release_tag(plan) and release["target_commitish"] == plan["source_sha"], "Existing release target differs")
    require(release["prerelease"] is True and release["body"] == body, "Existing release notes/type differ; refusing overwrite")
    require(release["name"] == f"Simple Live {plan['main_version']} repair prerelease", "Existing release name differs")


def validate_assets(existing, expected, complete=False):
    seen = set()
    for asset in existing:
        name = asset["name"]
        require(name in expected and name not in seen, "Unexpected/duplicate existing release asset")
        seen.add(name)
        require(asset["state"] == "uploaded" and asset["size"] == expected[name]["size"]
                and asset.get("digest") == expected[name]["sha256"], "Existing release asset mismatch or missing digest")
    if complete:
        require(seen == set(expected), "Release asset set incomplete")
    return seen


def validate_tag(api, plan, required=False):
    ref = api.request("/git/ref/tags/" + urllib.parse.quote(release_tag(plan), safe=""), allow_missing=True)
    if ref is None:
        require(not required, "Release tag missing")
        return
    # Only an exact lightweight tag is accepted; no mutation/force correction.
    require(ref["object"]["type"] == "commit" and ref["object"]["sha"] == plan["source_sha"], "Existing tag differs from source SHA")


def publish(api, plan, output, body, recheck):
    expected = {path.name: {"size": path.stat().st_size, "sha256": digest_file(path)} for path in output.iterdir()}
    matches = [release for release in api.pages("/releases") if release["tag_name"] == release_tag(plan)]
    require(len(matches) <= 1, "Ambiguous existing releases")
    validate_tag(api, plan)
    recheck()
    if matches:
        release = matches[0]
        validate_existing_release(release, plan, body)
    else:
        release = api.request("/releases", "POST", {
            "tag_name": release_tag(plan), "target_commitish": plan["source_sha"],
            "name": f"Simple Live {plan['main_version']} repair prerelease", "body": body,
            "draft": True, "prerelease": True, "make_latest": "false", "generate_release_notes": False})
        validate_existing_release(release, plan, body)
        require(release["draft"] is True, "New release must be a draft")
    release_id = release["id"]
    existing = api.pages(f"/releases/{release_id}/assets")
    present = validate_assets(existing, expected, complete=not release["draft"])
    if not release["draft"]:
        validate_tag(api, plan, required=True)
        return release["html_url"]  # Exact already-published result; no mutation.
    for name in sorted(set(expected) - present):
        asset = api.request(f"/releases/{release_id}/assets?name=" + urllib.parse.quote(name, safe=""), "POST", file=output / name)
        validate_assets([asset], expected)
    validate_assets(api.pages(f"/releases/{release_id}/assets"), expected, complete=True)
    # Re-read all six workflow attempts and artifact records immediately before promotion.
    recheck()
    validate_tag(api, plan)
    fresh = api.request(f"/releases/{release_id}")
    validate_existing_release(fresh, plan, body)
    require(fresh["draft"] is True, "Draft changed concurrently; refusing promotion")
    validate_assets(api.pages(f"/releases/{release_id}/assets"), expected, complete=True)
    release = api.request(f"/releases/{release_id}", "PATCH", {"draft": False, "prerelease": True, "make_latest": "false"})
    validate_existing_release(release, plan, body)
    require(release["draft"] is False, "Release did not publish")
    validate_tag(api, plan, required=True)
    validate_assets(api.pages(f"/releases/{release_id}/assets"), expected, complete=True)
    return release["html_url"]


def main():
    plan = json.loads((ROOT / "tool/prerelease-target.json").read_text())
    validate_plan(plan)
    if not plan["enabled"]:
        print("Publisher is disabled. No GitHub API request or release mutation performed.")
        return
    validate_context(plan, os.environ)
    api = GitHub(os.environ.get("GH_TOKEN"))
    runs, artifacts, provenance, packages = {}, {}, {}, []

    def inspect_run(platform):
        pin = plan["runs"][platform]
        run = api.request(f"/actions/runs/{pin['id']}")
        jobs = api.pages(f"/actions/runs/{pin['id']}/attempts/{pin['attempt']}/jobs", "jobs")
        validate_run(platform, run, jobs, plan)
        artifact = choose_artifact(platform, api.pages(f"/actions/runs/{pin['id']}/artifacts", "artifacts"), run, plan)
        return run, artifact

    for platform in PLATFORMS:
        runs[platform], artifacts[platform] = inspect_run(platform)

    def recheck():
        for platform in PLATFORMS:
            run, artifact = inspect_run(platform)
            require(run["run_attempt"] == runs[platform]["run_attempt"], "Workflow attempt changed")
            require(artifact["id"] == artifacts[platform]["id"] and artifact["digest"] == artifacts[platform]["digest"],
                    "Artifact changed during publication")

    tools = sdk_tools()
    with tempfile.TemporaryDirectory(prefix="verified-prerelease-") as temporary:
        root = Path(temporary)
        output = root / "assets"
        output.mkdir()
        for platform in PLATFORMS:
            artifact, run = artifacts[platform], runs[platform]
            archive = root / f"{platform}.zip"
            api.download(artifact["id"], archive)
            require(digest_file(archive) == artifact["digest"], f"{platform}: Actions archive digest mismatch")
            packages += prepare_artifact(platform, archive, output, run, plan, tools)
            provenance[platform] = {"run_id": run["id"], "run_attempt": run["run_attempt"],
                "workflow": run["path"], "artifact_id": artifact["id"], "artifact_name": artifact["name"],
                "artifact_archive_sha256": artifact["digest"], "artifact_expires_at": artifact["expires_at"]}
            archive.unlink()  # Temporary local download only; no remote asset deletion.
        (output / "PROVENANCE.json").write_bytes(json_bytes({
            "repository": REPOSITORY, "source_sha": plan["source_sha"], "main_version": plan["main_version"],
            "tv_version": plan["tv_version"], "workflows": provenance, "packages": packages,
            "validation_limits": {"real_device": "not tested", "historical_signing_match": "not verified",
                                  "buffering_root_cause": "unresolved", "tv_legacy_playback_defects": "pending"}}))
        (output / "SHA256SUMS.txt").write_text("".join(
            f"{digest_file(path).removeprefix('sha256:')}  {path.name}\n" for path in sorted(output.iterdir())), encoding="utf-8")
        url = publish(api, plan, output, notes(plan, provenance), recheck)
        print(f"Verified prerelease: {url}")
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
                summary.write(f"Published/verified qualified prerelease: {url}\n\nSource: {plan['source_sha']}\n")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, tarfile.TarError) as error:
        print(f"Prerelease gate failed: {error}", file=sys.stderr)
        sys.exit(1)
