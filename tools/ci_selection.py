"""Select the alpha-checks jobs for the exact tree that Actions checks out."""
import json
import os
from pathlib import Path
import re
import subprocess


SOURCE = 'source-and-kernel'
NATIVE = 'native-tooling'
AFTERLIGHT = 'afterlight-pure-core'
EDITOR = 'haskell-design-linux'
HOSTS = ['ubuntu-latest', 'windows-latest', 'macos-latest']
FULL = {SOURCE: HOSTS, NATIVE: True, AFTERLIGHT: True, EDITOR: True}

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


def selection(paths):
    jobs = {}
    for path in paths:
        if path in RENDERED_DOCS or path.startswith('.agents/skills/learn-code/'):
            jobs[NATIVE] = True
        elif (path in PUBLIC_FILES or path.startswith('site/')
              or (path.startswith(('docs/', 'research/', '.agents/skills/')) and path.endswith('.md'))):
            # The public job checks content, generated site output, and source hashes.
            continue
        elif path.startswith('libraries/'):
            jobs.update({SOURCE: HOSTS, NATIVE: True, AFTERLIGHT: True})
        elif path.startswith('templates/'):
            jobs.update({SOURCE: HOSTS, NATIVE: True})
        elif path in {'tools/publication.py', 'publication/policy.json'}:
            jobs[SOURCE] = HOSTS
        elif (path == 'cabal.project' or path.startswith((
              'references/garden/', 'references/lantern/', 'references/paper-circuit/',
              'references/river/', 'references/station/', 'references/tapline/'))
              or path in {'tools/play.py', 'tools/test_play.py', 'tools/test_lantern_api.py',
                          'tools/test_river_api.py', 'tools/test_station_api.py'}):
            jobs[SOURCE] = HOSTS
        elif path.startswith('references/afterlight/'):
            jobs.setdefault(SOURCE, HOSTS[:1])
            jobs[AFTERLIGHT] = True
        elif path.startswith(('references/red-dune/', 'references/signal-courier/',
                              'research/frontiers/free/', 'tools/quantity/')):
            jobs.setdefault(SOURCE, HOSTS[:1])
        elif path.startswith(('editors/haskell-design/', 'editors/neovim/')):
            jobs.setdefault(SOURCE, HOSTS[:1])
            jobs[EDITOR] = True
            if path.startswith('editors/neovim/'):
                jobs[NATIVE] = True
        elif path.startswith('editors/vscode/'):
            jobs.setdefault(SOURCE, HOSTS[:1])
            jobs[NATIVE] = True
        elif (path.startswith(('tools/haskell/', 'tools/windows-console/', 'tools/acceptance/'))
              or path in {'tools/bootstrap-fp-game.ps1', 'tools/bootstrap-fp-game.sh', 'tools/docs_lint.py',
                          'tools/test_native_cli.py', 'tools/test_windows_toolchain_paths.py', 'tools/test_workspace.py'}):
            jobs.setdefault(SOURCE, HOSTS[:1])
            jobs[NATIVE] = True
        else:
            # CI, formatter/toolchain configuration and unfamiliar paths run everything.
            return FULL
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
