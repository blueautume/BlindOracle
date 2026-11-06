import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ServiceEnvironmentGeneratorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='blindoracle-environment-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for folder in ['Scripts', 'Configuration', 'Resources']:
            (self.root / folder).mkdir()
        shutil.copy2(ROOT / 'Scripts/generate_project.py', self.root / 'Scripts/generate_project.py')
        (self.root / 'Configuration/Version.json').write_text(json.dumps({'version': '3.0.19', 'build': 45}))

    def generate(self, value=None):
        environment = os.environ.copy()
        environment.pop('BLINDORACLE_SANDBOX', None)
        if value is not None:
            environment['BLINDORACLE_SANDBOX'] = value
        subprocess.run([sys.executable, 'Scripts/generate_project.py'], cwd=self.root,
                       capture_output=True, text=True, check=True, env=environment)
        return (self.root / 'BlindOracle.xcodeproj/project.pbxproj').read_text()

    def test_default_and_non_explicit_values_generate_apple_verified_auto_routing(self):
        for value in [None, '', 'NO', '1', 'yes']:
            with self.subTest(value=value):
                project = self.generate(value)
                self.assertIn('BLINDORACLE_SANDBOX = "NO";', project)
                self.assertIn('BLINDORACLE_APP_DISPLAY_NAME = "瞎子";', project)
                self.assertIn('BLINDORACLE_APP_DISPLAY_NAME_EN = "BlindOracle";', project)
                self.assertIn('ORACLE_SERVICE_ENVIRONMENT = "Production";', project)
                self.assertIn('ORACLE_SERVICE_ENVIRONMENT_RESOLUTION = "AppleVerified";', project)
                flags = re.findall(r'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "([^"]*)";', project)
                self.assertEqual(len(flags), 8)
                self.assertTrue(all('BLINDORACLE_SANDBOX' not in flag for flag in flags))

    def test_explicit_sandbox_sets_all_compile_conditions_and_regeneration_restores_production(self):
        project = self.generate('YES')
        self.assertIn('BLINDORACLE_SANDBOX = "YES";', project)
        self.assertIn('ORACLE_SERVICE_ENVIRONMENT = "Sandbox";', project)
        self.assertIn('ORACLE_SERVICE_ENVIRONMENT_RESOLUTION = "OwnerSandbox";', project)
        self.assertIn('BLINDORACLE_APP_DISPLAY_NAME_EN = "BlindOracle·Test";', project)
        # The project serializer may escape non-ASCII strings; decode them before checking the display name.
        self.assertIn('BLINDORACLE_APP_DISPLAY_NAME = ' + json.dumps('瞎子·测试', ensure_ascii=False) + ';', project)
        flags = re.findall(r'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "([^"]*)";', project)
        self.assertEqual(len(flags), 8)
        self.assertTrue(all('BLINDORACLE_SANDBOX' in flag for flag in flags))
        restored = self.generate()
        self.assertIn('BLINDORACLE_SANDBOX = "NO";', restored)
        self.assertNotIn('$(inherited) BLINDORACLE_SANDBOX', restored)


if __name__ == '__main__':
    unittest.main()
