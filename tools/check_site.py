"""Check the static page's links and recorded Haskell evidence, without a browser."""

from html import unescape
from html.parser import HTMLParser
import base64
import binascii
import json
from pathlib import Path
import re
import struct
from urllib.parse import unquote, urlsplit

from publication import png_problem


ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
PUBLIC_FIGURES = {
    "https://raw.githubusercontent.com/M-simplifier/stillroom/v0.12.0/docs/journey.png",
    "https://raw.githubusercontent.com/M-simplifier/stillroom/v0.12.0/docs/rest-landscape.png",
    "https://m-simplifier.github.io/garden-of-afterlight/guide/assets/night.png",
}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.links = []
        self.errors = []
        self.elements = {}
        self.labels = set()
        self.named_controls = []

    def handle_starttag(self, tag, pairs):
        attributes = dict(pairs)
        if identifier := attributes.get("id"):
            if identifier in self.ids:
                self.errors.append(f"duplicate id: {identifier}")
            self.ids.add(identifier)
            self.elements[identifier] = (tag, attributes)
        if tag == "label" and attributes.get("for"):
            self.labels.add(attributes["for"])
        for name in ("src", "href"):
            if attributes.get(name):
                self.links.append((tag, name, attributes[name], attributes.get("rel")))
        if tag == "html" and attributes.get("lang") != "ja":
            self.errors.append("the Japanese page needs lang=ja")
        if tag == "img" and not attributes.get("alt"):
            self.errors.append("an image needs a meaningful alternative")
        if tag == "form" and attributes.get("action"):
            self.errors.append("the local-only game brief must not have a submission endpoint")
        if tag in {"input", "textarea", "select", "button"} and "name" in attributes:
            self.named_controls.append(attributes["name"])


def check_links(page, page_path=SITE / "index.html"):
    for tag, attribute, target, relation in page.links:
        parsed = urlsplit(target)
        if parsed.scheme:
            if tag == "img" and attribute == "src" and target.startswith("data:image/png;base64,"):
                try:
                    content = base64.b64decode(target.split(",", 1)[1], validate=True)
                    dimensions = struct.unpack('>II', content[16:24]) if len(content) >= 24 else (0, 0)
                    if (len(content) > 524288 or not all(1 <= value <= 4096 for value in dimensions)
                            or png_problem(content, *dimensions)):
                        page.errors.append("invalid or oversized embedded documentary PNG")
                except (ValueError, binascii.Error):
                    page.errors.append("invalid embedded documentary PNG")
                continue
            if parsed.scheme != "https":
                page.errors.append(f"unexpected URL scheme: {target}")
            if tag == "script" or (tag == "link" and relation == "stylesheet"):
                page.errors.append(f"unexpected remote executable/style dependency: {target}")
            if tag == "img" and target not in PUBLIC_FIGURES:
                page.errors.append(f"unreviewed remote documentary figure: {target}")
            for prefix in ("/M-simplifier/fp-game-alpha/blob/main/",
                           "/M-simplifier/fp-game-alpha/tree/main/"):
                if parsed.netloc == "github.com" and parsed.path.startswith(prefix):
                    source = ROOT / unquote(parsed.path[len(prefix):])
                    if not source.exists():
                        page.errors.append(f"missing repository link: {target}")
            continue
        if parsed.netloc:
            page.errors.append(f"protocol-relative dependency: {target}")
            continue
        path = unquote(parsed.path)
        local = (page_path.parent / path).resolve() if path else page_path.resolve()
        if not local.is_relative_to(SITE) or not local.is_file():
            page.errors.append(f"missing or escaping local file: {target}")
        elif parsed.fragment and local.suffix == ".html":
            target_page = page
            if local != page_path.resolve():
                target_page = Page()
                target_page.feed(local.read_text(encoding="utf-8"))
            if unquote(parsed.fragment) not in target_page.ids:
                page.errors.append(f"missing page anchor: {target}")


def check_creator():
    path = SITE / "create.html"
    page = Page()
    page.feed(path.read_text(encoding="utf-8"))
    script = (SITE / "site.js").read_text(encoding="utf-8")
    required = {"brief-form", "game-brief", "game-target", "ai-prompt", "copy-status",
                "copy-brief", "prompt-details", "trace-next", "trace-reset", "trace-count",
                "trace-label", "trace-title", "trace-command", "trace-description",
                "trace-energy", "trace-turn", "trace-delivered"}
    assert required <= page.ids, "creator controls or Station trace disappeared"
    assert not page.named_controls, "brief controls must not serialize into a native form submission"
    for identifier in ("game-brief", "game-target", "ai-prompt"):
        assert identifier in page.labels, f"creator control needs a label: {identifier}"
        assert "name" not in page.elements[identifier][1], "brief must not serialize into a URL"
    assert "disabled" in page.elements["copy-brief"][1], "copy needs JS before native submit is enabled"
    assert not page.elements["brief-form"][1].get("action"), "creator must remain local-only"
    assert ("script", "src", "site.js", None) in page.links, "creator script must load at its new location"
    assert "navigator.clipboard.writeText" in script and "promptBox.select()" in script, "copy needs a manual fallback"
    assert "$new-game" in script and "docs/purpose.md" in script, "creator prompt lost its current source route"


def check_research():
    import research
    catalog = research.validate(research.read_catalog())
    document = (SITE / "research.html").read_text(encoding="utf-8")
    assert document == research.render(catalog), "research page is stale; run tools/research.py build"
    page = Page()
    page.feed(document)
    for identifier in ("research-search", "research-topic", "research-status"):
        assert identifier in page.labels, f"search control needs a label: {identifier}"
    assert '<noscript>' in document and 'aria-live="polite"' in document, "missing accessible search fallback"
    for entry in catalog["entries"]:
        tag, attributes = page.elements[entry["id"]]
        assert tag == "article" and "catalog-entry" in attributes.get("class", "").split()
        assert "hidden" not in attributes, "research must remain readable with JavaScript disabled"
        assert attributes["data-status"] == entry["status"]
    assert ("script", "src", "research.js", None) in page.links, "missing local search script"


def check_lesson_sources(document):
    declarations = {
        "choice": ("Domain", "data Choice ="),
        "applyCost": ("Domain", "applyCost ::"),
        "step": ("Domain", "step ::"),
        "stationStep": ("Adapter", "stationStep ::"),
    }
    blocks = re.findall(r"<!-- source:(\w+) -->(.*?)<!-- /source:\1 -->", document, re.S)
    assert sorted(name for name, _ in blocks) == sorted(declarations), "missing, duplicate or unknown lesson source block"
    for name, excerpt in blocks:
        module, start = declarations[name]
        source = (ROOT / "references/station/src/Station" / (module + ".hs")).read_text(encoding="utf-8")
        declaration = re.search(r"^" + re.escape(start) + r".*?(?=\n\n|\Z)", source, re.M | re.S)
        assert declaration is not None, f"missing source declaration: {name}"
        assert unescape(excerpt) == declaration[0], f"lesson/source mismatch: {name}"


def check_trace():
    trace = json.loads((SITE / "evidence" / "station-trace.json").read_text(encoding="utf-8"))
    assert re.fullmatch(r"[0-9a-f]{40}", trace["source_commit"]), "missing exact source revision"
    assert re.fullmatch(r"[0-9a-f]{64}", trace["source_fingerprint"]), "missing source fingerprint"
    assert trace["source"] == "references/station/app/HeadlessMain.hs"
    assert (ROOT / trace["source"]).is_file()
    assert trace["commands"] == ["act 1 local", "act 1 local"]
    initial, accepted, refused = trace["packets"]
    assert [packet["result"] for packet in trace["packets"]] == ["started", "accepted", "refused"]
    assert all(packet["protocol"] == 1 and packet["game"] == "station"
               for packet in trace["packets"])
    assert initial["turn"] == 1 and accepted["turn"] == 2
    assert initial["resources"]["energy"] - 1 == accepted["resources"]["energy"]
    assert initial["resources"]["delivered"] + 1 == accepted["resources"]["delivered"]
    assert refused["refusal_kind"] == "protocol"
    assert refused["feedback"] == "Stale turn; observe again."
    response_fields = {"result", "feedback", "refusal_kind"}
    state = lambda packet: {key: value for key, value in packet.items() if key not in response_fields}
    assert state(accepted) == state(refused), "the refused operation changed observable game state"


def main():
    errors = []
    links = 0
    pages = sorted(SITE.rglob("*.html"))
    for path in pages:
        page = Page()
        page.feed(path.read_text(encoding="utf-8"))
        check_links(page, path)
        errors.extend(f"{path.relative_to(SITE)}: {error}" for error in page.errors)
        links += len(page.links)
    try:
        check_trace()
        check_lesson_sources((SITE / "learn.html").read_text(encoding="utf-8"))
    except (AssertionError, KeyError, ValueError, OSError) as error:
        errors.append(f"Station evidence: {error}")
    for label, check in (("Creator", check_creator), ("Research", check_research)):
        try:
            check()
        except (AssertionError, KeyError, ValueError, TypeError, OSError) as error:
            errors.append(f"{label}: {error}")
    for error in errors:
        print(error)
    print(f"public site: {'FAIL' if errors else 'PASS'} ({len(pages)} pages; {links} links/assets; catalog, creator, Station record and lesson sources)")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
