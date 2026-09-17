#!/usr/bin/env python3
"""Prepare a stable upstream release merge; the workflow tests before pushing."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

UPSTREAM = 'realskyrin/capcap'
STATE = '.github/upstream-release.json'


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def version(tag):
    match = re.fullmatch(r'release-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', tag)
    if not match:
        raise RuntimeError(f'Invalid official release tag: {tag}')
    return tuple(map(int, match.groups()))


def ancestor(root, base, head):
    result = subprocess.run(['git', '-C', str(root), 'merge-base', '--is-ancestor', base, head])
    if result.returncode not in (0, 1):
        raise RuntimeError('Cannot verify upstream history')
    return result.returncode == 0


def fetch_tag(root, remote, tag):
    version(tag)
    ref = f'refs/remotes/upstream-releases/{tag}'
    git(root, 'fetch', '--no-tags', remote, f'+refs/tags/{tag}:{ref}')
    return git(root, 'rev-parse', f'{ref}^{{commit}}')


def sync_release(root, release, remote=f'https://github.com/{UPSTREAM}.git'):
    root = Path(root)
    if release.get('draft') is not False or release.get('prerelease') is not False:
        raise RuntimeError('Only published stable releases are accepted')
    tag = release['tag_name']
    latest_version = version(tag)
    if git(root, 'status', '--porcelain'):
        raise RuntimeError('Release sync requires a clean worktree')
    state = json.loads((root / STATE).read_text())
    previous_version = version(state['tag'])
    bases = {state['commit'], state['history_commit']}
    for base in bases:
        if not re.fullmatch(r'[0-9a-f]{40}', base) or not ancestor(root, base, 'HEAD'):
            raise RuntimeError('Tracked upstream history is not contained in private main')
    previous_sha = fetch_tag(root, remote, state['tag'])
    if previous_sha != state['commit']:
        raise RuntimeError(f"Upstream tag changed: {state['tag']} was {state['commit']}, now {previous_sha}; manual review required")
    if latest_version < previous_version:
        raise RuntimeError('Latest release is older than tracked release; refusing downgrade')
    if tag == state['tag']:
        print(f'No new official release: {tag}')
        return False
    target = fetch_tag(root, remote, tag)
    if not any(ancestor(root, base, target) for base in bases):
        raise RuntimeError('Upstream release history was rewritten; manual reconciliation required')
    result = subprocess.run(['git', '-C', str(root), 'merge', '--no-commit', '--no-ff', target])
    if result.returncode:
        conflicts = git(root, 'diff', '--name-only', '--diff-filter=U')
        git(root, 'merge', '--abort')
        raise RuntimeError(f'Upstream release merge conflict; manual resolution required:\n{conflicts}')
    (root / STATE).write_text(json.dumps({'tag': tag, 'commit': target, 'history_commit': target}, indent=2) + '\n')
    git(root, 'add', STATE)
    git(root, 'commit', '-m', f'Sync official upstream release {tag}')
    print(f'Prepared {tag} at {target}; remote main has not been changed')
    return True


def main():
    release = json.loads(subprocess.check_output(['gh', 'api', f'repos/{UPSTREAM}/releases/latest'], text=True))
    root = git('.', 'rev-parse', '--show-toplevel')
    git(root, 'config', 'user.name', 'github-actions[bot]')
    git(root, 'config', 'user.email', 'github-actions[bot]@users.noreply.github.com')
    changed = sync_release(root, release)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'changed={str(changed).lower()}\n')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(f"## Official release sync\n\n{release['tag_name']}: " + ('merge prepared for validation' if changed else 'already synchronized') + '\n')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, ValueError, KeyError) as error:
        message = f'Official release sync stopped: {error}'
        print(message, file=sys.stderr)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
                summary.write(f'## Official release sync stopped\n\n{message}\n')
        sys.exit(1)
