#!/usr/bin/env python3
"""Bump the app version, or verify working-tree / staged version consistency."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = 'Configuration/Version.json'
PROJECT = 'BlindOracle.xcodeproj/project.pbxproj'
README = 'README.md'
VALIDATION = 'Validation.json'
VERSION_PATTERN = r'\bMARKETING_VERSION\s*=\s*"?(\d+\.\d+\.\d+)"?\s*;'
BUILD_PATTERN = r'\bCURRENT_PROJECT_VERSION\s*=\s*"?(\d+)"?\s*;'


def read(path, revision=None):
    if revision is None:
        return (ROOT / path).read_text()
    result = subprocess.run(['git', 'show', f'{revision}:{path}'], cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f'Cannot read {path} from {revision or "the Git index"}.')
    return result.stdout


def parse_manifest(text):
    data = json.loads(text)
    version, build = data.get('version'), data.get('build')
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Version.json must contain a version in X.Y.Z format.')
    if type(build) is not int or build < 1:
        raise ValueError('Version.json build must be a positive integer.')
    return version, build


def project_version(text):
    versions = re.findall(VERSION_PATTERN, text)
    builds = re.findall(BUILD_PATTERN, text)
    if len(versions) != 2 or len(set(versions)) != 1 or len(builds) != 2 or len(set(builds)) != 1:
        raise ValueError('App Debug and Release versions must both exist and agree.')
    return versions[0], int(builds[0])


def check(revision=None):
    version, build = parse_manifest(read(MANIFEST, revision))
    if project_version(read(PROJECT, revision)) != (version, build):
        raise ValueError('Xcode Debug/Release settings do not match Version.json.')
    expected = f'当前版本：**{version}（Build {build}）**'
    if re.findall(r'当前版本：\*\*[^*\n]+\*\*', read(README, revision)) != [expected]:
        raise ValueError('README version does not match Version.json.')
    validation = json.loads(read(VALIDATION, revision))
    if (validation.get('version'), str(validation.get('build'))) != (version, str(build)):
        raise ValueError('Validation.json version does not match Version.json.')
    return version, build


def check_staged():
    version, build = check('')
    head = subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=ROOT, capture_output=True)
    if head.returncode:
        return version, build
    try:
        previous, previous_build = parse_manifest(read(MANIFEST, 'HEAD'))
    except ValueError:
        # Existing repositories adopt the manifest without losing their history.
        previous, previous_build = project_version(read(PROJECT, 'HEAD'))
    if tuple(map(int, version.split('.'))) <= tuple(map(int, previous.split('.'))):
        raise ValueError('Every change must increase the app version compared with HEAD.')
    if build <= previous_build:
        raise ValueError('Every change must increase the Build number compared with HEAD.')
    return version, build


def bump(major=False):
    version, build = check()
    parts = list(map(int, version.split('.')))
    if major:
        parts = [parts[0] + 1, 0, 0]
    else:
        parts[-1] += 1
    updated, next_build = '.'.join(map(str, parts)), build + 1
    project = re.sub(VERSION_PATTERN, f'MARKETING_VERSION = {updated};', read(PROJECT))
    project = re.sub(BUILD_PATTERN, f'CURRENT_PROJECT_VERSION = {next_build};', project)
    readme = re.sub(r'当前版本：\*\*[^*\n]+\*\*', f'当前版本：**{updated}（Build {next_build}）**', read(README))
    validation = json.loads(read(VALIDATION))
    validation['version'], validation['build'] = updated, str(next_build)
    contents = {
        MANIFEST: json.dumps({'version': updated, 'build': next_build}, indent=2) + '\n',
        PROJECT: project,
        README: readme,
        VALIDATION: json.dumps(validation, ensure_ascii=False, indent=2) + '\n',
    }
    for path, content in contents.items():
        (ROOT / path).write_text(content)
    return updated, next_build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check', action='store_true', help='Check the working tree without changing files.')
    mode.add_argument('--check-staged', action='store_true', help='Check the Git index and require an increase over HEAD.')
    mode.add_argument('--major', action='store_true', help='Increase the major version and Build number.')
    args = parser.parse_args()
    try:
        version, build = check_staged() if args.check_staged else check() if args.check else bump(major=args.major)
    except (ValueError, OSError, KeyError) as error:
        print(f'Version check failed: {error}', file=sys.stderr)
        print('Run python3 Scripts/version.py once, then stage Version.json, project.pbxproj, README.md and Validation.json.', file=sys.stderr)
        return 1
    print(f'Version {version} (Build {build}) {"verified" if args.check or args.check_staged else "updated"}.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
