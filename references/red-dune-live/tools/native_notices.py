"""Collect native binary notices from the resolved local build; no downloads."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parents[3]


def command(*arguments):
    return subprocess.check_output(arguments, cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    arguments = parser.parse_args()
    plan = json.loads((ROOT / 'dist-newstyle/cache/plan.json').read_text())
    units = {unit['id']: unit for unit in plan['install-plan']}
    root = next(unit for unit in units.values()
                if unit['pkg-name'] == 'red-dune-live'
                and unit.get('component-name') == 'exe:red-dune')
    pending, visited = [root['id']], set()
    while pending:
        identity = pending.pop()
        if identity not in visited:
            visited.add(identity)
            pending.extend(units[identity].get('depends', []))
    paths = json.loads(command('cabal', 'path', '--output-format=json'))
    compiler = Path(command('ghc', '--print-libdir'))
    documents = compiler / 'doc' / (plan['arch'] + '-' + plan['os']
                                    + '-' + plan['compiler-id'])
    notices, packages = [], set()
    for unit in sorted((units[key] for key in visited),
                       key=lambda item: (item['pkg-name'], item['pkg-version'])):
        name, version = unit['pkg-name'], unit['pkg-version']
        label = f'{name}-{version}'
        if label in packages:
            continue
        packages.add(label)
        source = unit.get('pkg-src', {}) or {}
        if source.get('type') == 'local':
            text = (Path(source['path']) / 'LICENSE').read_text(encoding='utf-8')
        elif source.get('type') == 'repo-tar':
            archive = Path(paths['remote-repo-cache']) / 'hackage.haskell.org' / name / version / (label + '.tar.gz')
            with tarfile.open(archive) as bundle:
                text = bundle.extractfile(label + '/LICENSE').read().decode('utf-8')
                if name == 'h-raylib':
                    # Vendored raylib, GLFW and codecs retain their notices in
                    # source comments. Copy notices only, never example assets.
                    seen = set()
                    for member in bundle.getmembers():
                        relative = member.name.removeprefix(label + '/')
                        if not member.isfile() or not relative.startswith('raylib/src/') or not relative.endswith(('.c', '.h')):
                            continue
                        content = bundle.extractfile(member).read().decode('utf-8', errors='replace')
                        for block in re.findall(r'/\*[\s\S]*?\*/|(?:^[ \t]*//[^\n]*(?:\n|$))+', content, re.MULTILINE):
                            if re.search(r'copyright|permission is hereby|license|public domain', block, re.IGNORECASE) and block not in seen:
                                seen.add(block)
                                notices.append(f'{label}: {relative}\n{block}')
        else:
            license_path = documents / label / 'LICENSE'
            if name == 'rts' and not license_path.is_file():
                license_path = documents / plan['compiler-id'] / 'LICENSE'
            text = license_path.read_text(encoding='utf-8')
        notices.append(f'{label}\n{text}')
    arguments.output.write_text(
        'Red Dune native build dependency notices\n\n'
        'This local package uses Windows system fonts in memory; no font files are distributed.\n'
        'Dependency notices below are preserved from the resolved build sources.\n\n'
        + '\n\n'.join(notices), encoding='utf-8', newline='\n')
    print(f'Collected notices for {len(packages)} resolved packages')


if __name__ == '__main__':
    main()
