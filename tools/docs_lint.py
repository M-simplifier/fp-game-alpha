"""Check local Markdown links and canonical skill/document routing."""
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def main():
    failures = []
    documents = [p for p in ROOT.rglob('*.md') if not any(part in {'.git', '.build', '.runtime', 'dist-newstyle'} for part in p.parts)]
    for document in documents:
        content = document.read_text(encoding='utf-8')
        for target in re.findall(r'\[[^\]]*\]\(([^)]+)\)', content):
            target = target.strip('<>').split(' "')[0]
            parsed = urlsplit(target)
            if parsed.scheme or not parsed.path:
                continue
            destination = (document.parent / unquote(parsed.path)).resolve()
            if not destination.is_relative_to(ROOT) or not destination.exists():
                failures.append(f'{document.relative_to(ROOT)}: broken local link {target}')
    for skill in (ROOT / 'skills').glob('*/SKILL.md'):
        text = skill.read_text(encoding='utf-8')
        if not text.startswith('---\n') or 'name:' not in text or 'description:' not in text:
            failures.append(f'{skill.relative_to(ROOT)}: missing skill frontmatter')
        if len(text.splitlines()) > 70:
            failures.append(f'{skill.relative_to(ROOT)}: move technical content into canonical docs')
        if '../../docs/' not in text:
            failures.append(f'{skill.relative_to(ROOT)}: no canonical document route')
    for failure in failures:
        print(failure)
    print(f"docs/skills lint: {'FAIL' if failures else 'PASS'} ({len(documents)} documents)")
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
