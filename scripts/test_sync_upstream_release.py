"""Exercise release synchronization using real disposable Git repositories."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('sync_upstream_release.py')


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.STDOUT, text=True).strip()


class ReleaseSyncTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.exists(), 'Release-only synchronization is not implemented')
        spec = importlib.util.spec_from_file_location('release_sync', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.up = self.root / 'upstream'
        self.up.mkdir()
        git(self.up, 'init', '-b', 'main')
        git(self.up, 'config', 'user.name', 'Test')
        git(self.up, 'config', 'user.email', 'test@example.invalid')
        self.old = self.commit(self.up, 'app.txt', 'base\n')
        git(self.up, 'tag', 'release-v1.0.0')
        self.fork = self.root / 'fork'
        git(self.root, 'clone', str(self.up), str(self.fork))
        git(self.fork, 'config', 'user.name', 'Test')
        git(self.fork, 'config', 'user.email', 'test@example.invalid')
        self.state = self.fork / '.github/upstream-release.json'
        self.state.parent.mkdir()
        self.state.write_text(json.dumps({'tag': 'release-v1.0.0', 'commit': self.old, 'history_commit': self.old}))
        git(self.fork, 'add', '.')
        git(self.fork, 'commit', '-m', 'Track release')
        self.commit(self.fork, 'private.txt', 'AI Calendar\n')

    def commit(self, root, path, text):
        (root / path).write_text(text)
        git(root, 'add', '.')
        git(root, 'commit', '-m', path)
        return git(root, 'rev-parse', 'HEAD')

    def sync(self, tag='release-v1.0.0', **fields):
        return self.module.sync_release(self.fork, {'tag_name': tag, 'draft': False, 'prerelease': False, **fields}, str(self.up))

    def test_no_new_release_ignores_main_changes(self):
        self.commit(self.up, 'unpublished.txt', 'not released')
        before = git(self.fork, 'rev-parse', 'HEAD')
        self.assertFalse(self.sync())
        self.assertEqual(before, git(self.fork, 'rev-parse', 'HEAD'))
        self.assertFalse((self.fork / 'unpublished.txt').exists())

    def test_new_release_merges_only_tag_and_records_state(self):
        new = self.commit(self.up, 'released.txt', 'released')
        git(self.up, 'tag', '-a', 'release-v1.0.1', '-m', 'Release')
        self.commit(self.up, 'unpublished.txt', 'not released')
        self.assertTrue(self.sync('release-v1.0.1'))
        self.assertEqual((self.fork / 'private.txt').read_text(), 'AI Calendar\n')
        self.assertTrue((self.fork / 'released.txt').exists())
        self.assertFalse((self.fork / 'unpublished.txt').exists())
        self.assertEqual(json.loads(self.state.read_text())['commit'], new)
        self.assertEqual(git(self.fork, 'status', '--porcelain'), '')
        self.assertFalse(self.sync('release-v1.0.1'))

    def test_moved_previous_tag_fails_even_with_new_release(self):
        self.commit(self.up, 'new.txt', 'new')
        git(self.up, 'tag', '-f', 'release-v1.0.0')
        git(self.up, 'tag', 'release-v1.0.1')
        with self.assertRaisesRegex(RuntimeError, 'tag changed'):
            self.sync('release-v1.0.1')

    def test_invalid_releases_fail(self):
        for tag, fields in [('release-v1.0.0', {'draft': True}), ('release-v1.0.0', {'prerelease': True}), ('main', {}), ('release-v0.9.0', {})]:
            with self.subTest(tag=tag, fields=fields), self.assertRaises(RuntimeError):
                self.sync(tag, **fields)

    def test_rewritten_history_stops(self):
        git(self.up, 'checkout', '--orphan', 'rewritten')
        self.commit(self.up, 'app.txt', 'rewritten')
        git(self.up, 'tag', 'release-v1.0.1')
        with self.assertRaisesRegex(RuntimeError, 'history'):
            self.sync('release-v1.0.1')

    def test_conflict_aborts_without_advancing_state(self):
        self.commit(self.fork, 'app.txt', 'private change')
        before = git(self.fork, 'rev-parse', 'HEAD')
        state = self.state.read_text()
        self.commit(self.up, 'app.txt', 'upstream change')
        git(self.up, 'tag', 'release-v1.0.1')
        with self.assertRaisesRegex(RuntimeError, 'conflict'):
            self.sync('release-v1.0.1')
        self.assertEqual(before, git(self.fork, 'rev-parse', 'HEAD'))
        self.assertEqual(state, self.state.read_text())
        self.assertEqual(git(self.fork, 'status', '--porcelain'), '')

    def test_future_settings_icon_update_preserves_private_integration(self):
        # Real settings sources, merged through the production release sync path
        project = SCRIPT.parent.parent
        tracked = json.loads((project / '.github/upstream-release.json').read_text())
        path = 'capcap/Settings/SettingsView.swift'
        official = git(project, 'show', tracked['commit'] + ':' + path) + '\n'
        private = (project / path).read_text()
        for root in [self.up, self.fork]:
            (root / 'capcap/Settings').mkdir(parents=True)
        base = self.commit(self.up, path, official)
        git(self.up, 'tag', 'release-v1.0.1')
        git(self.fork, 'fetch', str(self.up), base)
        git(self.fork, 'merge', '--no-edit', base)
        state = {'tag': 'release-v1.0.1', 'commit': base, 'history_commit': base}
        self.commit(self.fork, '.github/upstream-release.json', json.dumps(state))
        self.commit(self.fork, path, private)
        icon = re.search(r'case \.translation: return "([^"\n]+)"', official)
        self.assertIsNotNone(icon, 'Official translation icon declaration changed')
        future_line = f'case .translation: return "{icon.group(1)}.test"'
        changed = official.replace(icon.group(0), future_line, 1)
        self.commit(self.up, path, changed)
        git(self.up, 'tag', 'release-v1.0.2')
        self.assertTrue(self.sync('release-v1.0.2'))
        merged = (self.fork / path).read_text()
        self.assertIn(future_line, merged)
        self.assertIn('case .aiCalendar: return "calendar.badge.plus"', merged)
        self.assertIn('paneViews[.aiCalendar] = buildAICalendarPane()', merged)
        self.assertIn('aiCalendarPane?.cancelConnectionTest()', merged)

    def test_explicit_reconciled_history_accepts_future_release(self):
        git(self.up, 'checkout', '--orphan', 'rewritten')
        git(self.up, 'commit', '-m', 'Same tree new history')
        anchor = git(self.up, 'rev-parse', 'HEAD')
        self.assertEqual(git(self.up, 'rev-parse', 'HEAD^{tree}'), git(self.up, 'rev-parse', self.old + '^{tree}'))
        git(self.fork, 'fetch', str(self.up), anchor)
        git(self.fork, 'merge', '-s', 'ours', '--allow-unrelated-histories', '--no-edit', anchor)
        state = json.loads(self.state.read_text())
        state['history_commit'] = anchor
        self.commit(self.fork, '.github/upstream-release.json', json.dumps(state))
        self.commit(self.up, 'next.txt', 'new release')
        git(self.up, 'tag', 'release-v1.0.1')
        self.assertTrue(self.sync('release-v1.0.1'))
        self.assertTrue((self.fork / 'private.txt').exists())


if __name__ == '__main__':
    unittest.main()
