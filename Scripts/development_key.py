#!/usr/bin/env python3
"""Read ignored local credentials without printing or embedding them in source."""
import json
import os
import plistlib
import re
import sys
import tempfile
from pathlib import Path

DEEPSEEK_RESOURCE = 'dev-key.txt'
QWEN_RESOURCE = 'qwen-key.txt'
QWEN_KEY_FILE = 'qwen-bailian.key'
DEEPSEEK_PATTERN = r'sk-[A-Za-z0-9_-]{12,}'
QWEN_PATTERN = r'sk-(?:[A-Za-z0-9_-]{12,}|ws-[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+)'


def read_local_configuration(root):
    local = root / 'Configuration' / 'Secrets.local.json'
    if not (local.exists() or local.is_symlink()):
        return None
    try:
        config = json.loads(local.read_text(encoding='utf-8'))
    except (ValueError, OSError):
        raise ValueError('Configuration/Secrets.local.json is not valid readable JSON.') from None
    if not isinstance(config, dict) or not isinstance(config.get('deepseek_api_key'), str):
        raise ValueError('Local secrets must contain a string field named deepseek_api_key.')
    return config


def validated_key(value, pattern, provider):
    if isinstance(value, str):
        key = value.strip()
        if not key or re.fullmatch(pattern, key):
            return key or None
    raise ValueError(f'The local {provider} key format is invalid; the value was not logged.')


def read_deepseek_key(key_directory, config):
    if config is not None:
        return validated_key(config['deepseek_api_key'], DEEPSEEK_PATTERN, 'DeepSeek')
    # Backward compatibility with the original developer-provided Finder clipping.
    for path in sorted(key_directory.glob('*')):
        if not path.is_file() or path.name.startswith('.') or path.name == QWEN_KEY_FILE:
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
            match = re.search(rf'\b(?!sk-ws-[A-Za-z0-9_-]+\.){DEEPSEEK_PATTERN}\b', value)
            if match:
                return match.group(0)
    return None


def read_qwen_key(key_directory, config):
    if config is not None and 'qwen_api_key' in config:
        return validated_key(config['qwen_api_key'], QWEN_PATTERN, 'Qwen')
    path = key_directory / QWEN_KEY_FILE
    if not (path.exists() or path.is_symlink()):
        return None
    try:
        value = path.read_text(encoding='utf-8')
    except (ValueError, OSError):
        raise ValueError('The local Qwen key file is not valid readable text.') from None
    return validated_key(value, QWEN_PATTERN, 'Qwen')


def read_keys(root):
    root = Path(root)
    config = read_local_configuration(root)
    key_directory = root.parent / 'key'
    return {
        DEEPSEEK_RESOURCE: read_deepseek_key(key_directory, config),
        QWEN_RESOURCE: read_qwen_key(key_directory, config),
    }


def write_bundle_key(target, key):
    if key is None:
        target.unlink(missing_ok=True)
        return
    temporary = None
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor, filename = tempfile.mkstemp(prefix='.dev-key-', dir=target.parent)
        temporary = Path(filename)
        # mkstemp creates the file with mode 0600 before any credential is written.
        with os.fdopen(descriptor, 'w', encoding='utf-8') as output:
            output.write(key)
        temporary.replace(target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def bundle_keys(root, resources):
    """Use the same ignored local credentials for Debug and Release builds."""
    try:
        for name, key in read_keys(root).items():
            write_bundle_key(resources / name, key)
    except (ValueError, OSError):
        # Clear both resources after a failure, including partially updated builds.
        for name in (DEEPSEEK_RESOURCE, QWEN_RESOURCE):
            (resources / name).unlink(missing_ok=True)
        raise


def main():
    try:
        root = os.environ['SRCROOT']
        resources = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']
        bundle_keys(root, resources)
    except (KeyError, ValueError, OSError):
        # Never interpolate an exception: decoder and filesystem messages can
        # include input data. A fixed diagnostic also keeps build logs private.
        sys.stderr.write('Bundled credential generation failed. Check the local secrets file and build output permissions; credential values were not logged.\n')
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
