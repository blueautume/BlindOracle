#!/usr/bin/env python3
"""Inspect the Git index. Report paths and reasons, never credential values."""
import argparse
import re
import subprocess
import sys
from pathlib import Path

from development_key import read_key

PROVIDER_KEY = re.compile(rb'\bsk-[A-Za-z0-9_-]{24,}\b')
PRIVATE_KEY = re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----')

def credential_issue(path, data, known_key=None):
    name = Path(path).name.lower()
    if name in {'secrets.local.json', 'dev-key.txt', '.env'} or name.endswith(('.pem', '.p12', '.textclipping')):
        return 'private credential file must not be tracked'
    if known_key and known_key.encode('utf-8') in data:
        return 'contains the configured local credential'
    if PROVIDER_KEY.search(data) or PRIVATE_KEY.search(data):
        return 'contains a credential-shaped value'
    return None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--staged', action='store_true', help='Inspect the complete staged tree (default).')
    args = parser.parse_args()
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
    try:
        known_key = read_key(root)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '-z'], cwd=root).split(b'\0')
    issues = []
    for encoded in filter(None, paths):
        path = encoded.decode('utf-8', errors='surrogateescape')
        data = subprocess.check_output(['git', 'show', ':' + path], cwd=root)
        reason = credential_issue(path, data, known_key)
        if reason:
            issues.append((path, reason))
    for path, reason in issues:
        print(f'Blocked: {path}: {reason}', file=sys.stderr)
    if issues:
        return 1
    print(f'Secret check passed: {len(list(filter(None, paths)))} staged files; no credential values printed.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
