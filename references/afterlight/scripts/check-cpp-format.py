"""Check/reproduce formatting of the six mid-declaration CPP exclusions.

Uses the repository's verified, pinned Ormolu, never --unsafe. Each declaration
is formatted in both configurations with temporary boundary comments, then
woven back together only if shared text agrees exactly. These temporary comments
keep CPP boundaries on their own lines; none are written to the source.

--write additionally proves safe-Ormolu canonical equality before/after actual
CPP preprocessing for both hosts, before writing any source or manifest. This is
source equivalence evidence, not a runtime/typechecking or graphics test.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FOUNDATION = ROOT.parents[1]
sys.path.insert(0, str(FOUNDATION / 'tools'))
import formatter

DECLARATIONS = {
    'runtime/Garden/Render/Radiance.hs': ['acquireRadiance'],
    'runtime/Garden/Render.hs': ['renderInterface', 'renderMenu'],
    'runtime/Garden/Runtime.hs': ['beginGarden', 'advancePreparation', 'stepFrame'],
}
REGION = re.compile(r'\{- ORMOLU_DISABLE -\}\n(.*?)\{- ORMOLU_ENABLE -\}', re.S)
MARKER = r'^[ \t]*-- AFTERLIGHT_CPP_BOUNDARY_(\d+)\n'
PREAMBLE = 'module CPPFormatting where\n\n'
OLD_NOTE = '-- CPP splits this declaration; retain both host branches verbatim.\n'
NOTE = '-- CPP branches are formatted by scripts/check-cpp-format.py.\n'


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def format_haskell(executable, source):
    result = subprocess.run([str(executable), '--no-cabal', '--check-idempotence', '--ghc-opt=-XGHC2021'],
                            input=source, capture_output=True, text=True, encoding='utf-8', timeout=60, check=True)
    return result.stdout


def project(source, wasm):
    """Annotate supported, unnested host conditionals; reject new CPP shapes."""
    lines, directives, active, inside, seen_else = [], {}, True, False, False
    for number, line in enumerate(source.splitlines()):
        if line.startswith('#'):
            directives[str(number)] = line
            lines.append(f'-- AFTERLIGHT_CPP_BOUNDARY_{number}')
            if line in ('#if defined(wasm32_HOST_ARCH)', '#if !defined(wasm32_HOST_ARCH)') and not inside:
                inside, seen_else = True, False
                active = not wasm if '!defined' in line else wasm
            elif line == '#else' and inside and not seen_else:
                active, seen_else = not active, True
            elif line == '#endif' and inside:
                active, inside = True, False
            else:
                raise ValueError('Unsupported CPP directive: ' + line)
        elif active:
            lines.append(line)
    if inside:
        raise ValueError('Unclosed CPP conditional')
    return '\n'.join(lines) + '\n', directives


def weave(source, executable):
    parts = []
    projections = [project(source, wasm) for wasm in (False, True)]
    formatted = [format_haskell(executable, PREAMBLE + item[0]) for item in projections]
    if any(not text.startswith(PREAMBLE) for text in formatted):
        raise ValueError('Unexpected formatter module preamble')
    native, wasm = [re.split(MARKER, text[len(PREAMBLE):], flags=re.M) for text in formatted]
    directives = projections[0][1]
    if native[1::2] != list(directives) or wasm[1::2] != list(directives):
        raise ValueError('CPP boundary moved or lost')
    active = [True, True]
    for index in range(0, len(native), 2):
        if all(active) and native[index] != wasm[index]:
            raise ValueError('Shared text formats differently across CPP branches')
        parts.append(native[index] if active[0] else wasm[index])
        if index + 1 < len(native):
            directive = directives[native[index + 1]]
            parts.append(directive + '\n')
            if directive.startswith('#if '):
                active = [True, False] if '!defined' in directive else [False, True]
            elif directive == '#else':
                active = [not value for value in active]
            else:
                active = [True, True]
    return ''.join(parts).rstrip() + '\n\n'


def canonical(source, wasm, executable):
    source = source.replace(OLD_NOTE, '').replace(NOTE, '')
    source = re.sub(r'^\{- ORMOLU_(?:DISABLE|ENABLE) -\}\n', '', source, flags=re.M)
    command = ['cpp', '-traditional-cpp', '-P']
    if wasm:
        command.append('-Dwasm32_HOST_ARCH')
    result = subprocess.run(command, input=source, capture_output=True, text=True, encoding='utf-8', timeout=30, check=True)
    return format_haskell(executable, result.stdout)


def checked_targets(root):
    """Validate the whole write plan before reading or changing any target."""
    paths = {}
    for name in [*DECLARATIONS, 'docs/FORMAT-MANIFEST.json']:
        path = formatter.local_path(root, name)
        if not path.is_file() or path.stat().st_nlink != 1:
            raise ValueError('Refusing a missing, non-file, or hardlinked target: ' + name)
        paths[name] = path
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    executable = formatter.verified(FOUNDATION)
    targets = checked_targets(ROOT)
    manifest_path = targets['docs/FORMAT-MANIFEST.json']
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    outputs, comparisons = {}, []
    for name, declarations in DECLARATIONS.items():
        source = targets[name].read_text(encoding='utf-8')
        regions = REGION.findall(source)
        if [re.match(r'(\w+) ::', region).group(1) for region in regions] != declarations:
            raise ValueError('Unexpected excluded declarations in ' + name)
        candidate = REGION.sub(lambda match: '{- ORMOLU_DISABLE -}\n' + weave(match[1], executable)
                               + '{- ORMOLU_ENABLE -}', source).replace(OLD_NOTE, NOTE)
        for wasm in (False, True):
            before, after = [canonical(text, wasm, executable) for text in (source, candidate)]
            if before != after:
                raise ValueError('CPP canonical source changed: ' + name + ' wasm=' + str(wasm))
            comparisons.append({'path': name, 'configuration': 'wasm' if wasm else 'native',
                                'normalized_preprocessed_sha256': sha(after), 'same': True})
        outputs[name] = candidate
        if not args.write and source != candidate:
            raise ValueError('CPP formatting drift: ' + name + '; run this script with --write')
    if manifest['cpp_normalized_comparison'] != comparisons:
        raise ValueError('CPP canonical source differs from reviewed manifest; refusing to relock semantic drift')
    if args.write:
        targets = checked_targets(ROOT)
        for name, source in outputs.items():
            targets[name].write_text(source, encoding='utf-8', newline='\n')
        for row in manifest['files']:
            if row['path'] in outputs:
                row['formatted_sha256'] = sha(outputs[row['path']])
        manifest['branch_formatted_cpp_declarations'] = DECLARATIONS
        manifest.pop('verbatim_cpp_declarations', None)
        manifest['cpp_normalized_comparison'] = comparisons
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8', newline='\n')
    else:
        if manifest.get('branch_formatted_cpp_declarations') != DECLARATIONS:
            raise ValueError('CPP declaration manifest differs')
    print('PASS six CPP declarations: reproducible branch-aware formatting and both host projections')


if __name__ == '__main__':
    main()
