#!/usr/bin/env python3
"""Read ignored local credentials without printing or embedding them in source."""
import json
import os
import plistlib
import re
import sys
import tempfile
from pathlib import Path

def read_key(root):
    local = Path(root) / 'Configuration' / 'Secrets.local.json'
    if local.exists() or local.is_symlink():
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

def bundle_key(root, target):
    """Use the same ignored local configuration for Debug and Release builds."""
    temporary = None
    try:
        key = read_key(root)
        if not key:
            target.unlink(missing_ok=True)
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor, filename = tempfile.mkstemp(prefix='.dev-key-', dir=target.parent)
        temporary = Path(filename)
        # mkstemp creates the file with mode 0600 before any credential is written.
        with os.fdopen(descriptor, 'w', encoding='utf-8') as output:
            output.write(key)
        temporary.replace(target)
    except (ValueError, OSError):
        # A failed build must not leave a previous configuration's credential
        # ready to be packaged by a later incremental build.
        target.unlink(missing_ok=True)
        raise
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    try:
        root = os.environ['SRCROOT']
        target = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'dev-key.txt'
        bundle_key(root, target)
    except (KeyError, ValueError, OSError):
        # Never interpolate an exception: decoder and filesystem messages can
        # include input data. A fixed diagnostic also keeps build logs private.
        sys.stderr.write('Bundled credential generation failed. Check the local secrets file and build output permissions; credential values were not logged.\n')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
