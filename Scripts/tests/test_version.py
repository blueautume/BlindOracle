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
VERSION_FILES = [
    'Configuration/Version.json',
    'BlindOracle.xcodeproj/project.pbxproj',
    'README.md',
    'Validation.json',
]


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='blindoracle-version-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for folder in ['Scripts', 'Configuration', 'BlindOracle.xcodeproj', 'App', 'no-hooks']:
            (self.root / folder).mkdir()
        shutil.copy2(ROOT / 'Scripts/version.py', self.root / 'Scripts/version.py')
        self.project_template = (ROOT / 'BlindOracle.xcodeproj/project.pbxproj').read_text()
        self.write_versions('0.1.1', 2)
        (self.root / 'App/Example.swift').write_text('let message = "before"\n')
        self.git('init', '--quiet')
        self.git('config', 'user.name', 'Version Test')
        self.git('config', 'user.email', 'version-test@example.invalid')
        self.git('config', 'core.hooksPath', str(self.root / 'no-hooks'))

    def git(self, *arguments):
        return subprocess.run(['git', *arguments], cwd=self.root, capture_output=True,
                              text=True, check=True, env=self.environment())

    @staticmethod
    def environment():
        environment = os.environ.copy()
        environment['GIT_CONFIG_GLOBAL'] = os.devnull
        environment['GIT_CONFIG_NOSYSTEM'] = '1'
        return environment

    def run_version(self, *arguments):
        return subprocess.run([sys.executable, 'Scripts/version.py', *arguments],
                              cwd=self.root, capture_output=True, text=True,
                              env=self.environment())

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def write_versions(self, version, build):
        (self.root / 'Configuration/Version.json').write_text(
            json.dumps({'version': version, 'build': build}) + '\n')
        project = re.sub(r'MARKETING_VERSION\s*=\s*[^;]+;',
                         f'MARKETING_VERSION = {version};', self.project_template)
        project = re.sub(r'CURRENT_PROJECT_VERSION\s*=\s*[^;]+;',
                         f'CURRENT_PROJECT_VERSION = {build};', project)
        (self.root / 'BlindOracle.xcodeproj/project.pbxproj').write_text(project)
        (self.root / 'README.md').write_text(
            f'# 瞎子\n\n当前版本：**{version}（Build {build}）**。\n\n保留这段说明。\n')
        (self.root / 'Validation.json').write_text(
            json.dumps({'version': version, 'build': str(build), 'retained_evidence': True}) + '\n')

    def commit_baseline(self):
        self.git('add', '.')
        self.git('commit', '--quiet', '-m', 'Initial version fixture')

    def assert_synced(self, version, build):
        manifest = json.loads((self.root / VERSION_FILES[0]).read_text())
        self.assertEqual(manifest, {'version': version, 'build': build})
        project = (self.root / VERSION_FILES[1]).read_text()
        marketing = re.findall(r'MARKETING_VERSION\s*=\s*"?([^;"\s]+)"?\s*;', project)
        builds = re.findall(r'CURRENT_PROJECT_VERSION\s*=\s*"?([^;"\s]+)"?\s*;', project)
        self.assertEqual(marketing, [version, version])
        self.assertEqual(builds, [str(build), str(build)])
        self.assertIn(f'当前版本：**{version}（Build {build}）**',
                      (self.root / 'README.md').read_text())
        self.assertIn('保留这段说明。', (self.root / 'README.md').read_text())
        validation = json.loads((self.root / 'Validation.json').read_text())
        self.assertEqual(validation['version'], version)
        self.assertEqual(str(validation['build']), str(build))
        self.assertTrue(validation['retained_evidence'])

    def test_default_bump_updates_debug_release_and_documented_version(self):
        self.commit_baseline()
        self.assert_success(self.run_version())
        self.assert_synced('0.1.2', 3)
        self.assert_success(self.run_version('--check'))

    def test_check_rejects_a_project_configuration_that_drifted_from_manifest(self):
        project = self.root / 'BlindOracle.xcodeproj/project.pbxproj'
        project.write_text(project.read_text().replace('MARKETING_VERSION = 0.1.1;',
                                                       'MARKETING_VERSION = 0.1.9;', 1))
        self.assertNotEqual(self.run_version('--check').returncode, 0)

    def test_staged_check_requires_the_bump_to_be_staged_not_just_in_worktree(self):
        self.commit_baseline()
        (self.root / 'App/Example.swift').write_text('let message = "after"\n')
        self.git('add', 'App/Example.swift')
        self.assert_success(self.run_version())
        self.assert_synced('0.1.2', 3)
        self.assertNotEqual(self.run_version('--check-staged').returncode, 0)
        self.git('add', *VERSION_FILES)
        self.assert_success(self.run_version('--check-staged'))

    def test_staged_check_requires_both_version_and_build_to_increase(self):
        self.commit_baseline()
        for version, build in [('0.1.1', 3), ('0.1.2', 2)]:
            with self.subTest(version=version, build=build):
                self.write_versions(version, build)
                self.assert_success(self.run_version('--check'))
                self.git('add', *VERSION_FILES)
                self.assertNotEqual(self.run_version('--check-staged').returncode, 0)


if __name__ == '__main__':
    unittest.main()
