"""Prepare a manual, SHA-bound fork release from the unified installer workflow."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

from publish_prerelease import GitHub, require
from verify_apk_signer import expected_signer, verify_report

REPOSITORY = 'Forlooong/dart_simple_live'
JOBS = {'android-apk', 'tv-apk', 'windows', 'linux'}
TARGETS = [('main', 'Android', 'android', arch) for arch in ('arm32', 'arm64', 'x64')] + [
    ('tv', 'Android-TV', 'android', arch) for arch in ('arm32', 'arm64', 'x64')] + [
    ('main', 'Windows', 'windows', 'x64'), ('main', 'Linux', 'linux', 'x64')]


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def release_changes(root, head, previous, tag):
    notes_path = root / 'docs' / 'release-notes' / f'{tag}.txt'
    if notes_path.is_file():
        notes = notes_path.read_text(encoding='utf-8').strip()
        require(notes, f'Empty release notes for {tag}')
        return notes
    if not isinstance(previous, str) or not re.fullmatch(r'[0-9a-f]{40}', previous):
        return ''
    history = subprocess.run(
        ['git', '-C', str(root), 'log', '--no-merges', '-n', '30', '--format=%s',
         f'{previous}..{head}'],
        capture_output=True, encoding='utf-8', check=False,
    )
    if history.returncode:
        return ''
    titles = [line.strip() for line in history.stdout.splitlines()
              if line.strip() and not re.match(r'^(?:ci|docs|build|test)(?:[:(])', line, re.I)
              and '[skip ci]' not in line]
    return '\n'.join(f'- {title}' for title in dict.fromkeys(titles))


def notes_for_app(notes, app):
    parts = re.split(r'^## (共通|主应用|TV)[ \t]*$', notes, flags=re.M)
    if len(parts) == 1:
        return notes
    sections = dict(zip(parts[1::2], parts[2::2]))
    require(len(parts) == 7 and not parts[0].strip() and
            set(sections) == {'共通', '主应用', 'TV'}, 'Invalid Chinese update detail sections')
    target = '主应用' if app == 'main' else 'TV'
    return '\n\n'.join(f'{label}\n{sections[label].strip()}'
                        for label in ('共通', target) if sections[label].strip())


def release_body(notes, manifest_bytes):
    encoded = base64.b64encode(manifest_bytes).decode('ascii')
    return f'{notes.rstrip()}\n\n<!-- simple-live-update-manifest:v1\n{encoded}\n-->\n'


def version(root, app):
    directory = 'simple_live_app' if app == 'main' else 'simple_live_tv_app'
    text = (root / directory / 'pubspec.yaml').read_text(encoding='utf-8')
    match = re.search(r'^version: (\d+\.\d+\.\d+)\+(\d+)\s*$', text, re.M)
    require(match is not None, 'Invalid source version')
    return match[1], int(match[2])


def minimum_sdk(badging):
    match = re.search(r"^\s*(?:sdkVersion|minSdkVersion):\s*'(\d+)'", badging, re.M)
    require(match is not None, 'Missing Android minimum SDK; manifest report: ' + badging[:4096])
    return int(match[1])


def validate_run(run, jobs):
    require(run['repository']['full_name'] == REPOSITORY and
            run['head_repository']['full_name'] == REPOSITORY and
            run['head_branch'] == 'codex/simple-live-maintenance' and run['event'] == 'workflow_dispatch' and
            run['id'] == 45768643574 and run['head_sha'] == 'e733362d4052aaae5ea9f5003bf10aff659ca204' and
            run['path'] == '.github/workflows/installers.yml' and
            run['status'] == 'completed' and run['conclusion'] == 'success',
            'Require the explicitly pinned maintenance installer dispatch')
    require({j['name'] for j in jobs} == JOBS and len(jobs) == len(JOBS) and
            all(j['conclusion'] == 'success' and j['run_attempt'] == run['run_attempt']
                for j in jobs), 'All four jobs must succeed in the same attempt')


def verify_uploaded(assets, output):
    expected = {p.name: p for p in output.iterdir() if p.is_file()}
    require(len(assets) == len(expected) and {a['name'] for a in assets} == set(expected),
            'Release assets are incomplete or unexpected')
    for asset in assets:
        path = expected[asset['name']]
        require(asset['state'] == 'uploaded' and asset['size'] == path.stat().st_size and
                asset.get('digest') == 'sha256:' + sha(path), 'Release asset integrity mismatch')


def main():
    import os
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_id', type=int, nargs='?')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--apksigner')
    parser.add_argument('--aapt2')
    parser.add_argument('--verify-tag')
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    api = GitHub(os.environ['GH_TOKEN'])
    if args.verify_tag:
        raise SystemExit('Read-only candidate evidence preparation')
        require(re.fullmatch(r'fork-main-[0-9.]+-build[0-9]+-tv-[0-9.]+-build[0-9]+', args.verify_tag),
                'Invalid release tag')
        releases = api.pages('/releases')
        release = next(r for r in releases if r['tag_name'] == args.verify_tag)
        require(release['draft'], 'Only a draft can be promoted')
        verify_uploaded(api.pages(f'/releases/{release["id"]}/assets'), args.output)
        return
    require(args.run_id and args.apksigner and args.aapt2, 'Missing preparation inputs')
    run = api.request(f'/actions/runs/{args.run_id}')
    jobs = api.pages(f'/actions/runs/{args.run_id}/jobs', 'jobs')
    validate_run(run, jobs)
    root = (args.source or Path(__file__).resolve().parents[1]).resolve()
    actual = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    require(actual == run['head_sha'], 'Checkout must match the built source SHA')
    versions = {app: version(root, app) for app in ('main', 'tv')}
    tag = 'fork-main-%s-build%s-tv-%s-build%s' % (*versions['main'], *versions['tv'])
    latest = api.request('/releases/latest', allow_missing=True)
    if latest:
        previous = re.fullmatch(r'fork-main-([0-9.]+)-build(\d+)-tv-([0-9.]+)-build(\d+)', latest['tag_name'])
        require(previous is not None, 'Existing latest release uses an unrecognized version scheme')
        for app, name_index, build_index in [('main', 1, 2), ('tv', 3, 4)]:
            old_name = tuple(map(int, previous[name_index].split('.')))
            new_name = tuple(map(int, versions[app][0].split('.')))
            require(new_name >= old_name and versions[app][1] >= int(previous[build_index]),
                    'Refusing to publish a version older than the latest release')
    output = args.output
    output.mkdir(parents=True, exist_ok=False)
    changes = release_changes(root, actual, latest.get('target_commitish') if latest else None, tag)
    manifest = {'schemaVersion': 1, 'repository': REPOSITORY, 'sourceSha': actual}
    for app, (name, build) in versions.items():
        manifest[app] = {'version': name, 'notes': notes_for_app(changes, app), 'packages': []}
    artifacts = api.pages(f'/actions/runs/{args.run_id}/artifacts', 'artifacts')
    require(len(artifacts) == len(TARGETS),
            f'Expected exactly {len(TARGETS)} installer artifacts')
    for app, label, platform, arch in TARGETS:
        name, build = versions[app]
        identity = f'{name}+{build}-r{run["run_number"]}.{run["run_attempt"]}-{actual[:7]}'
        suffix = {'android': f'{arch}-ReleaseSigned.apk',
                  'windows': 'x64-Setup-Unsigned.exe', 'linux': 'x64.deb'}[platform]
        filename = f'Simple-Live-{identity}-{label}-{suffix}'
        matches = [a for a in artifacts if a['name'] == filename]
        require(len(matches) == 1, f'Missing installer {filename}')
        artifact = matches[0]
        require(not artifact['expired'] and artifact.get('digest', '').startswith('sha256:') and
                artifact['workflow_run']['head_sha'] == actual, 'Invalid artifact provenance')
        raw = output / (filename + '.download')
        api.download(artifact['id'], raw)
        require('sha256:' + sha(raw) == artifact['digest'], 'Artifact digest mismatch')
        target = output / filename
        # v7 non-archived artifacts are raw; older APIs may wrap a single file.
        if zipfile.is_zipfile(raw):
            with zipfile.ZipFile(raw) as archive:
                if archive.namelist() == [filename]:
                    with archive.open(filename) as source, target.open('xb') as dest:
                        shutil.copyfileobj(source, dest)
        if not target.exists():
            raw.rename(target)
        else:
            raw.unlink()
        item = {'platform': platform, 'arch': arch, 'build': build,
                'size': target.stat().st_size, 'sha256': sha(target),
                'url': f'https://github.com/{REPOSITORY}/releases/download/{tag}/{filename}'}
        if platform == 'android':
            report = subprocess.check_output([args.apksigner, 'verify', '--print-certs', str(target)], text=True)
            baseline = root / 'tool/signing-baseline.json'
            verify_report(app, report, baseline)
            badging = subprocess.check_output([args.aapt2, 'dump', 'badging', str(target)], text=True)
            package = 'com.xycz.simple_live' + ('_tv' if app == 'tv' else '')
            code = build + {'arm32': 1000, 'arm64': 2000, 'x64': 4000}[arch]
            require(f"name='{package}'" in badging and f"versionCode='{code}'" in badging and
                    f"versionName='{name}'" in badging, 'APK identity/version mismatch')
            abi = {'arm32': 'armeabi-v7a', 'arm64': 'arm64-v8a', 'x64': 'x86_64'}[arch]
            require(f"native-code: '{abi}'" in badging, 'APK architecture mismatch')
            item.update(build=code, packageId=package, certificate=expected_signer(app, baseline),
                        minSdk=minimum_sdk(badging))
        manifest[app]['packages'].append(item)
    fresh = api.request(f'/actions/runs/{args.run_id}')
    require(fresh['run_attempt'] == run['run_attempt'] and fresh['conclusion'] == 'success',
            'Source run changed during preparation')
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    (output / 'update.json').write_bytes(manifest_bytes)
    shutil.copyfile(root / 'LICENSE', output / 'LICENSE.txt')
    notice_paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '*LICENSE*', '*NOTICE*'], text=True).splitlines()
    with zipfile.ZipFile(output / 'THIRD-PARTY-NOTICES.zip', 'w', zipfile.ZIP_DEFLATED) as notices:
        for relative in notice_paths + ['docs/fork-builds.md']:
            notices.write(root / relative, relative)
    subprocess.run(['git', '-C', str(root), 'archive', '--format=tar.gz', f'--output={output / "source.tar.gz"}', actual], check=True)
    (output / 'SHA256SUMS.txt').write_text(''.join(
        f'{sha(path)}  {path.name}\n' for path in sorted(output.iterdir()) if path.is_file()), encoding='utf-8')
    title = f'Simple Live {versions["main"][0]} / TV {versions["tv"][0]}'
    description = re.sub(r'^• ', '- ', changes, flags=re.M)
    notes = ((description + '\n\n') if description else '') + (
        '- Android / TV 可使用相同签名的新版覆盖安装；桌面端下载对应安装包更新。\n'
        '- 本分支提供 Android、Android TV、Windows 和 Linux 安装包。\n\n'
        '基于 [Simple Live](https://github.com/xiaoyaocz/dart_simple_live)，'
        '由 Forlooong 维护。源码、GPLv3 许可证及第三方声明见附件。\n')
    (output.parent / 'release-notes.md').write_text(release_body(notes, manifest_bytes), encoding='utf-8')
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as destination:
        destination.write(f'tag={tag}\nsha={actual}\ntitle={title}\n')


if __name__ == '__main__':
    main()
