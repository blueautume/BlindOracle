import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from development_key import DEEPSEEK_RESOURCE, RETIRED_KEY_FILE, RETIRED_RESOURCE, read_keys
from check_secrets import credential_issue


class DevelopmentKeyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.root = self.parent / 'App'
        (self.root / 'Configuration').mkdir(parents=True)
        self.file = self.root / 'Configuration/Secrets.local.json'
        self.key = 'sk-' + 'x' * 32
        self.qwen_file = self.parent / 'key' / RETIRED_KEY_FILE
        self.qwen_key = 'sk-ws-' + '.'.join(['a', 'b' * 5, 'c' * 64])
        self.private_values = [self.key, 'sk-' + 'y' * 32, self.qwen_key]

    def write_config(self, value):
        self.file.write_text(json.dumps({'deepseek_api_key': value}))
        if isinstance(value, str) and value:
            self.private_values.append(value)

    def legacy(self):
        folder = self.parent / 'key'; folder.mkdir(exist_ok=True)
        (folder / 'legacy.textClipping').write_bytes(plistlib.dumps({'public.utf8-plain-text': 'sk-' + 'y' * 32}))

    def write_qwen_file(self):
        self.qwen_file.parent.mkdir(exist_ok=True)
        self.qwen_file.write_text(self.qwen_key + '\n')

    def test_local_file_is_preferred_to_legacy_clipping(self):
        self.legacy(); self.write_config(self.key)
        self.assertEqual(read_keys(self.root)[DEEPSEEK_RESOURCE], self.key)

    def test_legacy_clipping_remains_compatible(self):
        self.legacy()
        self.assertEqual(read_keys(self.root)[DEEPSEEK_RESOURCE], 'sk-' + 'y' * 32)

    def test_empty_local_file_does_not_reactivate_old_key(self):
        self.legacy(); self.write_config('')
        self.assertIsNone(read_keys(self.root)[DEEPSEEK_RESOURCE])

    def test_malformed_json_does_not_print_its_contents(self):
        self.file.write_text(self.key + '{')
        with self.assertRaises(ValueError) as failure:
            read_keys(self.root)
        self.assertNotIn(self.key, str(failure.exception))

    def test_invalid_schema_is_rejected(self):
        self.file.write_text(json.dumps({'deepseek_api_key': 123}))
        with self.assertRaises(ValueError): read_keys(self.root)

    def build(self, configuration, succeeds=True):
        output = self.parent / 'products'
        environment = dict(os.environ, CONFIGURATION=configuration, SRCROOT=str(self.root),
                           TARGET_BUILD_DIR=str(output), UNLOCALIZED_RESOURCES_FOLDER_PATH='Test.app')
        result = subprocess.run([sys.executable, str(SCRIPTS / 'development_key.py')], env=environment,
                                capture_output=True, text=True)
        if succeeds:
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout + result.stderr, '')
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Bundled credential generation failed.', result.stderr)
            self.assertNotIn('Traceback', result.stderr)
        for value in self.private_values:
            self.assertNotIn(value, result.stdout + result.stderr)
        return output / 'Test.app/dev-key.txt'

    def test_debug_build_reads_local_file_with_private_permissions(self):
        self.write_config(self.key)
        target = self.build('Debug')
        self.assertEqual(target.read_text(), self.key)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)

    def test_release_build_packages_the_local_credential_with_private_permissions(self):
        self.legacy(); self.write_config(self.key)
        target = self.build('Release')
        self.assertEqual(target.read_text(), self.key)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)

    def test_retired_key_file_never_supplies_the_reading_credential(self):
        self.qwen_file.parent.mkdir()
        self.qwen_file.write_text(self.key)
        self.assertEqual(read_keys(self.root), {DEEPSEEK_RESOURCE: None})

    def test_legacy_provider_field_is_ignored_and_only_deepseek_is_bundled(self):
        self.write_qwen_file()
        self.file.write_text(json.dumps({'deepseek_api_key': self.key, 'qwen_api_key': 'retired-invalid-value'}))
        deepseek = self.build('Release')
        self.assertEqual(deepseek.read_text(), self.key)
        self.assertEqual(list(deepseek.parent.iterdir()), [deepseek])

    def test_every_build_removes_retired_bundled_resource(self):
        for configuration in ['Debug', 'Release']:
            with self.subTest(configuration=configuration):
                self.write_config(self.key)
                target = self.build(configuration)
                retired = target.with_name(RETIRED_RESOURCE)
                retired.write_text(self.qwen_key)
                self.build(configuration)
                self.assertFalse(retired.exists())
                self.assertEqual(target.read_text(), self.key)

    def test_invalid_configuration_removes_active_and_retired_resources(self):
        self.write_config(self.key)
        target = self.build('Release')
        retired = target.with_name(RETIRED_RESOURCE)
        retired.write_text(self.qwen_key)
        self.file.write_text(self.key + '{')
        self.build('Release', succeeds=False)
        self.assertFalse(target.exists())
        self.assertFalse(retired.exists())

    def test_rotation_updates_the_packaged_credential_across_build_configurations(self):
        values = [self.key, 'sk-' + 'z' * 32, 'sk-' + 'w' * 32]
        for configuration, value in zip(['Debug', 'Release', 'Debug'], values):
            with self.subTest(configuration=configuration):
                self.write_config(value)
                target = self.build(configuration)
                self.assertEqual(target.read_text(), value)
                self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
                self.assertEqual(list(target.parent.iterdir()), [target])

    def test_debug_removes_stale_credential_after_empty_configuration(self):
        self.write_config(self.key); target = self.build('Debug')
        self.write_config(''); self.build('Debug')
        self.assertFalse(target.exists())

    def test_empty_local_configuration_clears_resource_without_legacy_fallback(self):
        self.legacy()
        for previous, current in [('Debug', 'Release'), ('Release', 'Debug'), ('Release', 'Release')]:
            with self.subTest(previous=previous, current=current):
                self.write_config(self.key); target = self.build(previous)
                self.write_config('  '); self.build(current)
                self.assertFalse(target.exists())

    def test_missing_local_and_legacy_credentials_remove_stale_resource(self):
        self.write_config(self.key); target = self.build('Debug')
        self.file.unlink()
        self.build('Release')
        self.assertFalse(target.exists())

    def test_invalid_json_fails_both_configurations_and_clears_previous_resource_without_logging(self):
        self.legacy()
        for previous, current in [('Debug', 'Release'), ('Release', 'Debug')]:
            with self.subTest(previous=previous, current=current):
                self.write_config(self.key); target = self.build(previous)
                self.file.write_text(self.key + '{')
                self.build(current, succeeds=False)
                self.assertFalse(target.exists())

    def test_invalid_schema_and_format_fail_without_printing_private_values(self):
        values = [{'unexpected': self.key}, self.key + '\nnot-a-key']
        for configuration in ['Debug', 'Release']:
            for value in values:
                with self.subTest(configuration=configuration, kind=type(value).__name__):
                    self.write_config(self.key); target = self.build(configuration)
                    self.write_config(value)
                    self.build(configuration, succeeds=False)
                    self.assertFalse(target.exists())

    def test_non_file_local_configuration_fails_without_legacy_fallback(self):
        self.legacy(); self.file.mkdir()
        self.build('Release', succeeds=False)

    def test_staged_scan_rejects_private_file_and_embedded_value(self):
        self.assertIsNotNone(credential_issue('Configuration/Secrets.local.json', b'{}'))
        self.assertIsNotNone(credential_issue(RETIRED_KEY_FILE, b''))
        self.assertIsNotNone(credential_issue(RETIRED_RESOURCE, b''))
        self.assertIsNotNone(credential_issue('example.swift', self.key.encode()))
        self.assertIsNotNone(credential_issue('example.swift', self.qwen_key.encode()))
        self.assertIsNone(credential_issue('Configuration/Secrets.example.json', b'{"deepseek_api_key":""}'))


if __name__ == '__main__':
    unittest.main()
