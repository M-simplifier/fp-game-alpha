"""Check canonical links, thin skill routing, support records and rendered docs."""
import json
from pathlib import Path, PurePosixPath
import posixpath
import re
import sys
from urllib.parse import unquote, urlsplit
import uuid

import scaffold

ROOT = Path(__file__).resolve().parents[1]


def anchors(text):
    result, counts = set(), {}
    for heading in re.findall(r'^#{1,6}\s+(.+)$', text, re.MULTILINE):
        heading = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', heading)
        slug = re.sub(r'[^\w\- ]', '', heading.lower()).replace(' ', '-')
        count = counts.get(slug, 0)
        result.add(slug + (f'-{count}' if count else ''))
        counts[slug] = count + 1
    result.update(re.findall(r'\bid=["\']([^"\']+)', text))
    return result


def inspect_documents(files, label):
    failures = []
    for name, content in files.items():
        if not name.endswith('.md'):
            continue
        text = content.decode('utf-8')
        for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', text):
            target = target.strip('<>').split(' "')[0]
            parsed = urlsplit(target)
            if parsed.scheme:
                continue
            destination = posixpath.normpath(posixpath.join(str(PurePosixPath(name).parent), unquote(parsed.path))) if parsed.path else name
            if destination not in files:
                failures.append(f'{label}/{name}: broken local link {target}')
            elif parsed.fragment and destination.endswith('.md') and unquote(parsed.fragment) not in anchors(files[destination].decode('utf-8')):
                failures.append(f'{label}/{name}: broken anchor {target}')
        if name.endswith('/SKILL.md'):
            header = text.split('---', 2)
            if not text.startswith('---\n') or len(header) < 3 or not all(re.search(r'^' + field + r':\s+\S', header[1], re.MULTILINE) for field in ['name', 'description']):
                failures.append(f'{label}/{name}: missing skill frontmatter')
            if len(text.splitlines()) > 70 or 'docs/' not in text:
                failures.append(f'{label}/{name}: keep skills thin and route to canonical docs')
    return failures


def main():
    names = __import__('publication').selected_files()
    files = {name: (ROOT / name).read_bytes().replace(b'\r\n', b'\n') for name in names if not name.startswith('templates/')}
    failures = inspect_documents(files, 'foundation')
    _, rendered = scaffold.prepare('lint-game', ROOT / '.build' / ('docs-check-' + uuid.uuid4().hex), 'Lint game', 'native', 'terminal', 'unlicensed', None)
    failures.extend(inspect_documents(rendered, 'generated-game'))
    contract = json.loads(files['docs/support/routes.json'])
    ids = [route['id'] for route in contract['routes']]
    if len(ids) != len(set(ids)):
        failures.append('duplicate support route')
    for route in contract['routes']:
        if route['status'] not in {'supported', 'experimental', 'planned', 'blocked'}:
            failures.append(route['id'] + ': unknown support status')
        if route['status'] in {'supported', 'experimental'} and (not route['commands'] or not route['evidence']):
            failures.append(route['id'] + ': implemented claim needs executable commands and scoped evidence')
        for path in route['implementation_paths']:
            if not (ROOT / path).exists():
                failures.append(route['id'] + ': missing implementation ' + path)
        for command in route['commands']:
            if len(command) < 2 or not (ROOT / command[1]).is_file():
                failures.append(route['id'] + ': command has no executable script')
        for evidence in route['evidence']:
            if not urlsplit(evidence).scheme and evidence not in files:
                failures.append(route['id'] + ': missing evidence ' + evidence)
    for failure in failures:
        print(failure)
    print(f"docs/skills/support lint: {'FAIL' if failures else 'PASS'} ({len(files)} foundation and {len(rendered)} rendered game files)")
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
