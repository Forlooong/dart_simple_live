"""Prepare a manual, SHA-bound fork release from the unified installer workflow."""
import argparse
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
JOBS = {'android-apk', 'tv-apk', 'ios', 'macos', 'windows', 'linux'}
TARGETS = [('main', 'Android', 'android', arch) for arch in ('arm32', 'arm64', 'x64')] + [
    ('tv', 'Android-TV', 'android', arch) for arch in ('arm32', 'arm64', 'x64')] + [
    ('main', 'Windows', 'windows', 'x64'), ('main', 'macOS', 'macos', 'universal'),
    ('main', 'Linux', 'linux', 'x64'), ('main', 'iOS', 'ios', 'arm64')]


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


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
            run['head_branch'] == 'master' and run['event'] in ('push', 'workflow_dispatch') and
            run['path'] == '.github/workflows/installers.yml' and
            run['status'] == 'completed' and run['conclusion'] == 'success',
            'Require a successful trusted master installer run')
    require({j['name'] for j in jobs} == JOBS and len(jobs) == 6 and
            all(j['conclusion'] == 'success' and j['run_attempt'] == run['run_attempt']
                for j in jobs), 'All six jobs must succeed in the same attempt')


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
    manifest = {'schemaVersion': 1, 'repository': REPOSITORY, 'sourceSha': actual}
    for app, (name, build) in versions.items():
        manifest[app] = {'version': name, 'notes': '非官方个人维护版本。源码：' +
            f'https://github.com/{REPOSITORY}/commit/{actual}', 'packages': []}
    artifacts = api.pages(f'/actions/runs/{args.run_id}/artifacts', 'artifacts')
    require(len(artifacts) == 10, 'Expected exactly ten installer artifacts')
    for app, label, platform, arch in TARGETS:
        name, build = versions[app]
        identity = f'{name}+{build}-r{run["run_number"]}.{run["run_attempt"]}-{actual[:7]}'
        suffix = {'android': f'{arch}-ReleaseSigned.apk',
                  'windows': 'x64-Setup-Unsigned.exe', 'macos': 'universal-Unsigned.dmg',
                  'linux': 'x64.deb', 'ios': 'arm64-Unsigned.ipa'}[platform]
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
    (output / 'update.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    shutil.copyfile(root / 'LICENSE', output / 'LICENSE.txt')
    notice_paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '*LICENSE*', '*NOTICE*'], text=True).splitlines()
    with zipfile.ZipFile(output / 'THIRD-PARTY-NOTICES.zip', 'w', zipfile.ZIP_DEFLATED) as notices:
        for relative in notice_paths + ['docs/fork-builds.md']:
            notices.write(root / relative, relative)
    subprocess.run(['git', '-C', str(root), 'archive', '--format=tar.gz', f'--output={output / "source.tar.gz"}', actual], check=True)
    (output / 'SHA256SUMS.txt').write_text(''.join(
        f'{sha(path)}  {path.name}\n' for path in sorted(output.iterdir()) if path.is_file()), encoding='utf-8')
    notes = ('非官方免费 fork，由 Forlooong 独立维护，原作者及直播平台未为本版本背书。\n\n'
        f'上游：https://github.com/xiaoyaocz/dart_simple_live\n源码提交：{actual}\n'
        '许可：GPLv3；第三方组件保留各自授权。源码和许可证随附件提供。\n'
        'Android/TV 使用固定签名；不保证覆盖不同证书的历史安装。\n'
        'Windows 未签名；macOS 未签名、未公证；iOS IPA 未签名，须使用适当签名渠道安装。\n'
        '构建校验不等于真机跨版本升级验证；问题请提交到本 fork 的 Issues。\n')
    (output.parent / 'release-notes.md').write_text(notes, encoding='utf-8')
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as destination:
        destination.write(f'tag={tag}\nsha={actual}\n')


if __name__ == '__main__':
    main()
