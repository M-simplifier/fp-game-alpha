"""Select the alpha-checks jobs for the exact tree that Actions checks out."""
import json
import os
from pathlib import Path
import re
import subprocess


SOURCE = 'source-and-kernel'
NATIVE = 'native-tooling'
AFTERLIGHT = 'afterlight-pure-core'
AFTERLIGHT_WINDOWS = 'afterlight-windows-native'
EDITOR = 'haskell-design-linux'
LINUX = 'ubuntu-latest'
WINDOWS = 'windows-latest'
MACOS = 'macos-latest'
HOSTS = [LINUX, WINDOWS, MACOS]
KERNEL_HOSTS = [LINUX, WINDOWS]
FULL = {SOURCE: KERNEL_HOSTS, NATIVE: HOSTS, AFTERLIGHT: True, AFTERLIGHT_WINDOWS: True, EDITOR: True}

# These documents are also inputs to the generated game distribution.
RENDERED_DOCS = {
    'docs/architecture.md', 'docs/editors.md', 'docs/failure-prevention.md',
    'docs/formatting.md', 'docs/haskell.md', 'docs/learn-code.md',
    'docs/native-tooling.md', 'docs/tooling.md', 'docs/practice/LICENSE.upstream',
    'docs/practice/haskell/technique-choices.md',
    'docs/practice/haskell/verification-review.md',
}
PUBLIC_FILES = {
    'README.md', 'PUBLICATION-MANIFEST.json', 'PUBLICATION-MANIFEST.md',
    'publication/provenance.json', 'docs/support/routes.json',
    'research/catalog.json', 'research/frontiers/category/finite_witness.py',
    'research/frontiers/category/finite-results.json',
    'tools/check_site.py', 'tools/research.py',
    'tools/test_research.py', 'tools/test_research_ui.cjs',
}
NATIVE_HOST_BOUNDARIES = {
    'tools/haskell/src/FpGame/Command.hs', 'tools/haskell/src/FpGame/Config.hs',
    'tools/haskell/src/FpGame/Create/Distribution.hs', 'tools/haskell/src/FpGame/Create/Filesystem.hs',
    'tools/haskell/src/FpGame/Process.hs',
    'tools/haskell/test/CreateSpec.hs', 'tools/haskell/test/ProcessSpec.hs',
    'tools/test_native_cli.py', 'tools/test_workspace.py',
}


def selection(paths):
    jobs = {}
    source, native = set(), set()
    for path in paths:
        if path in RENDERED_DOCS or path.startswith('.agents/skills/learn-code/'):
            native.add(LINUX)
        elif (path in PUBLIC_FILES or path.startswith('site/')
              or (path.startswith(('docs/', 'research/', '.agents/skills/')) and path.endswith('.md'))):
            # The public job checks content, generated site output, and source hashes.
            continue
        elif path.startswith('libraries/'):
            source.add(LINUX)
            native.add(LINUX)
            jobs[AFTERLIGHT] = True
            jobs[AFTERLIGHT_WINDOWS] = True
            if path.endswith('.cabal'):
                source.add(WINDOWS)
                native.add(WINDOWS)
        elif path.startswith('templates/'):
            source.add(LINUX)
            native.add(LINUX)
            if path.endswith(('/cabal.project', '/build.config', '.cabal', '.cabal.tmpl')):
                source.add(WINDOWS)
                native.add(WINDOWS)
        elif path in {'tools/publication.py', 'publication/policy.json', 'tools/test_tools.py',
                      'cabal.project', 'tools/play.py', 'tools/test_play.py'}:
            source.update(KERNEL_HOSTS)
        elif (path.startswith((
              'references/garden/', 'references/lantern/', 'references/paper-circuit/',
              'references/river/', 'references/station/', 'references/tapline/'))
              or path in {'tools/test_lantern_api.py', 'tools/test_river_api.py', 'tools/test_station_api.py'}):
            source.add(LINUX)
            if path.endswith('.cabal'):
                source.add(WINDOWS)
        elif path == 'cabal.project.gameio-afterlight':
            jobs[AFTERLIGHT_WINDOWS] = True
        elif path.startswith('references/afterlight/'):
            source.add(LINUX)
            jobs[AFTERLIGHT] = True
            if not path.startswith('references/afterlight/web/'):
                jobs[AFTERLIGHT_WINDOWS] = True
        elif path.startswith(('references/red-dune/', 'references/signal-courier/',
                              'research/frontiers/free/', 'tools/quantity/')):
            source.add(LINUX)
        elif path.startswith(('editors/haskell-design/', 'editors/neovim/')):
            source.add(LINUX)
            jobs[EDITOR] = True
            if path.startswith('editors/neovim/'):
                native.add(LINUX)
        elif path.startswith('editors/vscode/'):
            source.add(LINUX)
            native.update(KERNEL_HOSTS)
        elif path in NATIVE_HOST_BOUNDARIES or path.startswith(('tools/acceptance/', 'tools/haskell/cabal.project')) or (
                path.startswith('tools/haskell/') and path.endswith('.cabal')):
            native.update(HOSTS)
        elif path == 'tools/bootstrap-fp-game.sh':
            native.update((LINUX, MACOS))
        elif path.startswith('tools/windows-console/') or path in {
                'tools/bootstrap-fp-game.ps1', 'tools/test_windows_toolchain_paths.py'}:
            source.add(LINUX)
            native.add(WINDOWS)
        elif path.startswith('tools/haskell/'):
            # The native job already checks the CLI's own formatting and tests.
            native.update(KERNEL_HOSTS)
        elif path == 'tools/inspect_haskell.py':
            source.add(LINUX)
            native.update(KERNEL_HOSTS)
        elif path == 'tools/docs_lint.py':
            native.add(LINUX)
        else:
            # CI, formatter/toolchain configuration and unfamiliar paths run everything.
            return FULL
    if source:
        jobs[SOURCE] = [host for host in KERNEL_HOSTS if host in source]
    if native:
        jobs[NATIVE] = [host for host in HOSTS if host in native]
    return jobs


def git(*args):
    return subprocess.check_output(['git', *args], stderr=subprocess.PIPE, timeout=30)


def changed_paths(event_name, event, revision):
    if event_name == 'pull_request':
        pr = event['pull_request']
        base = pr['base']['sha']
        # Actions tests the synthetic merge. Comparing against its first parent
        # excludes changes already on the target branch, even for an older PR.
        parents = git('rev-parse', 'HEAD^1', 'HEAD^2').decode('ascii').splitlines()
        if parents != [base, pr['head']['sha']]:
            raise ValueError('The checkout is not the event merge commit')
    elif event_name == 'push':
        base = event['before']
    else:
        return None
    if not re.fullmatch(r'[0-9a-f]{40}', base) or base == '0' * 40:
        raise ValueError('The event has no comparison revision')
    if git('rev-parse', 'HEAD').decode('ascii').strip() != revision:
        raise ValueError('The checkout does not match the event revision')
    if event_name == 'push':
        try:
            git('cat-file', '-e', f'{base}^{{commit}}')
        except subprocess.CalledProcessError:
            git('fetch', '--no-tags', '--depth=1', 'origin', base)
    # Keep both sides of a rename and handle names with spaces or line breaks.
    diff = git('diff', '--no-renames', '--name-only', '-z', base, revision, '--')
    return [path for path in diff.decode('utf-8').split('\0') if path]


def previous_main_passed(base):
    # A newer docs push may finish before an earlier source push. Do not
    # inherit the earlier tree's checks until that exact push has passed.
    repository = os.environ['GITHUB_REPOSITORY']
    result = subprocess.check_output([
        'gh', 'api', '--method', 'GET', f'repos/{repository}/actions/workflows/ci.yml/runs',
        '-f', 'branch=main', '-f', 'event=push', '-f', f'head_sha={base}',
        '--jq', 'any(.workflow_runs[]; .conclusion == "success")',
    ], stderr=subprocess.PIPE, timeout=15)
    return result.strip() == b'true'


def select_event(event_name, event, revision):
    paths = changed_paths(event_name, event, revision)
    jobs = FULL if paths is None else selection(paths)
    if event_name == 'push' and jobs != FULL and not previous_main_passed(event['before']):
        print('Previous main revision has no successful alpha push run. Running all alpha checks.')
        return FULL
    return jobs


def main():
    try:
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
        jobs = select_event(os.environ['GITHUB_EVENT_NAME'], event, os.environ['GITHUB_SHA'])
    except (OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError):
        print('Could not establish the event comparison. Running all alpha checks.')
        jobs = FULL
    encoded = json.dumps(jobs, separators=(',', ':'))
    print(f'Selected alpha checks: {encoded}')
    with Path(os.environ['GITHUB_OUTPUT']).open('a', encoding='utf-8') as output:
        print(f'selection={encoded}', file=output)


if __name__ == '__main__':
    main()
