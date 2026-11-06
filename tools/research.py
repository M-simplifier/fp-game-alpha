"""Validate the authored research catalog and render its static, searchable page.

The JSON describes questions, results and their limits. Implementation details
remain in their original source; the generated HTML is a reader-facing index.
Only Python's standard library is needed, including in the existing Pages CI.
"""

import argparse
from datetime import date
from html import escape
import json
from pathlib import Path
import re
import sys
from urllib.parse import quote, unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
CATALOG = "research/catalog.json"
PAGE = "site/research.html"
REPOSITORY = "https://github.com/M-simplifier/fp-game-alpha"
STATUSES = {
    "implemented": "実装に接続",
    "example": "具体的な作品",
    "experiment": "実験",
    "question": "未解決の問い",
    "historical": "過去の研究",
}
SLUG = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*\Z")
FORBIDDEN_PARTS = {".git", ".codex", ".scratch", "node_modules", "brain", "AGENTS.md"}


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_catalog(root=ROOT):
    return json.loads((root / CATALOG).read_text(encoding="utf-8"), object_pairs_hook=unique_keys)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def text_field(value, label):
    require(isinstance(value, str) and bool(value.strip()), f"{label}: empty text")
    require(not re.search(r"(?:\b[A-Za-z]:[/\\]|file:|codex:|chatgpt\.com/c/)", value),
            f"{label}: private or local locator")


def local_target(value, root, label):
    parsed = urlsplit(value)
    require(not parsed.scheme and not parsed.netloc and not parsed.query,
            f"{label}: expected a repository-relative path")
    name = unquote(parsed.path)
    require(name and not name.startswith("/") and "\\" not in name and ":" not in name,
            f"{label}: noncanonical relative path")
    parts = name.split("/")
    require(not any(part in {"", ".", ".."} or part in FORBIDDEN_PARTS for part in parts),
            f"{label}: escaping or private path")
    path = root / name
    require(path.resolve().is_relative_to(root.resolve()), f"{label}: escaping path")
    require(path.exists(), f"{label}: missing {name}")
    require(not any(parent.is_symlink() for parent in [path, *path.parents] if parent != root.parent),
            f"{label}: linked source")
    if parsed.fragment and path.suffix.lower() in {".html", ".md"}:
        content = path.read_text(encoding="utf-8")
        if path.suffix.lower() == ".html":
            ids = set(re.findall(r'\bid=["\']([^"\']+)', content))
        else:
            from docs_lint import anchors
            ids = anchors(content)
        require(unquote(parsed.fragment) in ids, f"{label}: missing anchor {parsed.fragment}")
    return path


def source_target(value, root, label):
    text_field(value, label)
    parsed = urlsplit(value)
    if parsed.scheme:
        require(parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username
                and not parsed.password, f"{label}: source needs public HTTPS")
        require(parsed.hostname not in {"localhost", "127.0.0.1"}
                and not re.match(r"(?:10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)", parsed.hostname),
                f"{label}: private host")
        require(parsed.hostname not in {"chatgpt.com", "team-mystudio.slack.com"},
                f"{label}: private conversation")
    else:
        local_target(value, root, label)


def validate(catalog, root=ROOT):
    require(isinstance(catalog, dict) and set(catalog) ==
            {"schema_version", "updated", "scope", "topics", "entries"}, "catalog: unsupported fields")
    require(type(catalog["schema_version"]) is int and catalog["schema_version"] == 1,
            "catalog: unsupported schema")
    require(date.fromisoformat(catalog["updated"]).isoformat() == catalog["updated"],
            "catalog: invalid date")
    text_field(catalog["scope"], "scope")
    require(isinstance(catalog["topics"], list) and bool(catalog["topics"]), "catalog: missing topics")
    topics = set()
    for topic in catalog["topics"]:
        require(isinstance(topic, dict) and set(topic) == {"id", "title", "summary"}, "topic: unsupported fields")
        require(isinstance(topic["id"], str) and SLUG.fullmatch(topic["id"]), "topic: invalid id")
        require(topic["id"] not in topics, f"duplicate topic: {topic['id']}")
        topics.add(topic["id"])
        text_field(topic["title"], topic["id"])
        text_field(topic["summary"], topic["id"])
    require(isinstance(catalog["entries"], list) and bool(catalog["entries"]), "catalog: missing entries")
    identifiers, covered = set(), set()
    fields = {"id", "title", "summary", "topics", "status", "guide", "sources", "evidence", "limits"}
    for entry in catalog["entries"]:
        require(isinstance(entry, dict) and set(entry) == fields, "entry: unsupported fields")
        identifier = entry["id"]
        require(isinstance(identifier, str) and SLUG.fullmatch(identifier), "entry: invalid id")
        require(identifier not in identifiers, f"duplicate entry: {identifier}")
        identifiers.add(identifier)
        for field in ("title", "summary", "evidence", "limits"):
            text_field(entry[field], f"{identifier}/{field}")
        require(entry["status"] in STATUSES, f"{identifier}: unknown status")
        chosen = entry["topics"]
        require(isinstance(chosen, list) and chosen and all(isinstance(t, str) for t in chosen)
                and len(set(chosen)) == len(chosen) and set(chosen) <= topics,
                f"{identifier}: unknown, missing or duplicate topic")
        covered.update(chosen)
        path = local_target(entry["guide"], root, f"{identifier}/guide")
        require(path.is_file() and path.suffix.lower() in {".md", ".html"},
                f"{identifier}: guide must be a readable document")
        require(isinstance(entry["sources"], list) and entry["sources"], f"{identifier}: no sources")
        urls = set()
        for source in entry["sources"]:
            require(isinstance(source, dict) and set(source) == {"label", "url"},
                    f"{identifier}: invalid source")
            text_field(source["label"], f"{identifier}/source label")
            source_target(source["url"], root, f"{identifier}/source")
            require(source["url"] not in urls, f"{identifier}: duplicate source")
            urls.add(source["url"])
    require(covered == topics, "catalog: topic without any entry")
    return catalog


def public_url(target, root=ROOT):
    if urlsplit(target).scheme:
        return target
    parsed = urlsplit(target)
    path = unquote(parsed.path)
    if path.startswith("site/"):
        result = quote(path[5:], safe="/-._~")
    else:
        kind = "tree" if (root / path).is_dir() else "blob"
        result = f"{REPOSITORY}/{kind}/main/" + quote(path, safe="/-._~")
    return result + ("#" + quote(unquote(parsed.fragment), safe="-._~") if parsed.fragment else "")


def render(catalog, root=ROOT):
    esc = escape
    topics = {topic["id"]: topic for topic in catalog["topics"]}
    lines = [
        "<!doctype html>", '<html lang="ja">', '<head>', '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        '<meta name="color-scheme" content="light">',
        '<meta name="description" content="ゲーム開発研究の問い、実装、検証範囲を主題から探す。">',
        '<title>研究目録 · fp-game-alpha</title>',
        '<link rel="canonical" href="https://m-simplifier.github.io/fp-game-alpha/research.html">',
        '<link rel="icon" href="icon.svg" type="image/svg+xml">', '<link rel="stylesheet" href="research.css">',
        '<script src="research.js" defer></script>', '</head>', '<body>',
        '<a class="skip" href="#main">本文へ</a>', '<header class="site-header wrap">',
        '<a class="brand" href="index.html"><span aria-hidden="true">↦</span> fp-game-alpha <small>α</small></a>',
        '<nav aria-label="主な案内">',
        '<a href="research.html" aria-current="page">研究目録</a> <a href="guide.html">考え方を読む</a> '
        '<a href="index.html#studies">教材</a> <a href="create.html">AIと作る ↗</a>',
        '</nav>', '</header>', '<main id="main" class="wrap">', '<header class="catalog-header">',
        '<p class="eyebrow">研究目録</p>', '<h1>問いから研究を探す</h1>',
        '<p>入力の順序を変えると何が壊れるか。影と本体が同じ形を描くには何を揃えるか。'
        '知りたいことから、説明、実装、確かめた範囲へ進めます。</p>',
        f'<p>{esc(catalog["scope"])}</p>',
        f'<p class="meta">整理日 <time datetime="{esc(catalog["updated"])}">{esc(catalog["updated"])}</time> · '
        f'<a href="{REPOSITORY}/blob/main/research/coverage.md">調査した資料と残る範囲</a> · '
        f'<a href="{REPOSITORY}/blob/main/research/catalog.json">目録の元データ</a></p>', '</header>',
        '<section aria-labelledby="find-heading" class="catalog-search">', '<h2 id="find-heading">絞り込む</h2>',
        '<p>区分は研究の置かれている状態です。優劣の順位ではありません。'
        '実装に接続した研究にも、未検証の範囲があります。</p>',
        '<form id="research-filters" class="catalog-controls" role="search" hidden>',
        '<label for="research-search">言葉で探す',
        '<input id="research-search" type="search" autocomplete="off" placeholder="例：保存、観測、音楽"></label>',
        '<label for="research-topic">主題', '<select id="research-topic"><option value="">すべての主題</option>',
    ]
    lines.extend(f'<option value="{esc(topic["id"])}">{esc(topic["title"])}</option>' for topic in catalog["topics"])
    lines += ['</select></label>', '<label for="research-status">区分',
              '<select id="research-status"><option value="">すべての区分</option>']
    lines.extend(f'<option value="{value}">{label}</option>' for value, label in STATUSES.items())
    lines += ['</select></label>', '<button class="button" type="reset">絞り込みを戻す</button>', '</form>',
              '<noscript><p>すべての研究を以下に表示しています。ページ内検索も使えます。</p></noscript>',
              f'<p id="research-count" role="status" aria-live="polite">{len(catalog["entries"])}件の研究</p>', '</section>',
              '<section aria-labelledby="entries-heading" class="catalog">', '<h2 id="entries-heading">研究一覧</h2>']
    for entry in catalog["entries"]:
        lines += [f'<article id="{esc(entry["id"])}" class="catalog-entry" '
                  f'data-topics="{esc(" ".join(entry["topics"]))}" data-status="{esc(entry["status"])}">',
                  f'<p class="entry-meta"><span class="status-label">{STATUSES[entry["status"]]}</span></p>',
                  f'<h3><a href="{esc(public_url(entry["guide"], root))}">{esc(entry["title"])}</a></h3>',
                  f'<p>{esc(entry["summary"])}</p>', '<p class="topic-labels">']
        lines.extend(f'<span class="topic-label">{esc(topics[identifier]["title"])}</span>' for identifier in entry["topics"])
        lines += ['</p>', '<dl>', f'<dt>確かめたこと</dt><dd>{esc(entry["evidence"])}</dd>',
                  f'<dt>残る範囲</dt><dd>{esc(entry["limits"])}</dd>', '</dl>',
                  '<ul class="entry-sources" aria-label="実装と根拠">']
        lines.extend(f'<li><a href="{esc(public_url(source["url"], root))}">{esc(source["label"])}</a></li>'
                     for source in entry["sources"])
        lines += ['</ul>', '</article>']
    lines += ['</section>', '<p id="research-empty" hidden>該当する研究はありません。言葉や区分を変えてください。</p>',
              '</main>', '<footer class="site-footer wrap"><p>実装の正本と、有限の検査、実機での観察、人の評価を区別して読みます。</p></footer>',
              '</body>', '</html>', '']
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "check"])
    args = parser.parse_args()
    try:
        catalog = validate(read_catalog())
        expected = render(catalog)
        if args.action == "build":
            (ROOT / PAGE).write_text(expected, encoding="utf-8", newline="\n")
        else:
            require((ROOT / PAGE).read_text(encoding="utf-8") == expected,
                    "generated page differs; run python tools/research.py build")
        print(f"research catalog: PASS ({len(catalog['entries'])} entries; {len(catalog['topics'])} topics; {args.action})")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"research catalog: FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
