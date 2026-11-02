#!/usr/bin/env python3
"""Read ignored local credentials without printing or embedding them in source."""
import json
import os
import plistlib
import re
from pathlib import Path

def read_key(root):
    local = Path(root) / 'Configuration' / 'Secrets.local.json'
    if local.is_file():
        try:
            config = json.loads(local.read_text(encoding='utf-8'))
        except (ValueError, OSError):
            raise ValueError('Configuration/Secrets.local.json is not valid readable JSON.') from None
        if not isinstance(config, dict) or not isinstance(config.get('deepseek_api_key'), str):
            raise ValueError('Local secrets must contain a string field named deepseek_api_key.')
        value = config['deepseek_api_key'].strip()
        if not value:
            return None
        if not re.fullmatch(r'sk-[A-Za-z0-9_-]{12,}', value):
            raise ValueError('The local DeepSeek key format is invalid; the value was not logged.')
        return value
    # Backward compatibility with the original developer-provided Finder clipping.
    candidates = sorted((Path(root).parent / 'key').glob('*'))
    for path in candidates:
        if not path.is_file() or path.name.startswith('.'):
            continue
        data = path.read_bytes()
        values = []
        try:
            def walk(value):
                if isinstance(value, str): values.append(value)
                elif isinstance(value, bytes): values.append(value.decode('utf-8', errors='ignore'))
                elif isinstance(value, dict):
                    for v in value.values(): walk(v)
                elif isinstance(value, (tuple, list)):
                    for v in value: walk(v)
            walk(plistlib.loads(data))
        except Exception:
            values.append(data.decode('utf-8', errors='ignore'))
        for value in values:
            match = re.search(r'\bsk-[A-Za-z0-9_-]{12,}\b', value)
            if match:
                return match.group(0)
    return None

if __name__ == '__main__':
    if os.environ.get('CONFIGURATION', '') != 'Debug':
        # A preceding Debug build must not leave a secret in a reused output directory.
        output = os.environ.get('TARGET_BUILD_DIR', '')
        bundle = os.environ.get('UNLOCALIZED_RESOURCES_FOLDER_PATH', '')
        if output and bundle:
            (Path(output) / bundle / 'dev-key.txt').unlink(missing_ok=True)
        raise SystemExit(0)
    key = read_key(os.environ['SRCROOT'])
    target = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'dev-key.txt'
    if key:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(key, encoding='utf-8')
        target.chmod(0o600)
    else:
        target.unlink(missing_ok=True)
