"""Regression checks for useful catalog boundaries, publication and no-JS reading."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

import research
from check_site import Page, check_links


class Catalog(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="research-catalog-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "guide.md").write_text("# A real guide\n", encoding="utf-8")
        (self.root / "source.hs").write_text("module Source where\n", encoding="utf-8")
        self.catalog = dict(schema_version=1, updated="2026-11-06", scope="Test research",
                            topics=[dict(id="time", title="Time", summary="Input boundaries")],
                            entries=[dict(id="ordered-time", title="Ordered time", summary="Two inputs",
                                          topics=["time"], status="experiment", guide="guide.md",
                                          sources=[dict(label="Source", url="source.hs")],
                                          evidence="Finite trace", limits="No device run")])

    def reject(self, mutate, message):
        value = copy.deepcopy(self.catalog)
        mutate(value)
        with self.assertRaisesRegex(ValueError, message):
            research.validate(value, self.root)

    def test_real_source_and_guide_are_required(self):
        research.validate(self.catalog, self.root)
        self.reject(lambda c: c["entries"][0].update(guide="missing.md"), "missing")
        self.reject(lambda c: c["entries"][0]["sources"][0].update(url="missing.hs"), "missing")

    def test_dangling_fragment_is_rejected(self):
        self.reject(lambda c: c["entries"][0].update(guide="guide.md#unknown"), "missing anchor")

    def test_status_is_descriptive_and_explicit(self):
        for status in research.STATUSES:
            value = copy.deepcopy(self.catalog)
            value["entries"][0]["status"] = status
            research.validate(value, self.root)
        self.reject(lambda c: c["entries"][0].update(status="proved"), "unknown status")
        self.reject(lambda c: c["entries"][0].update(evidence=""), "empty text")
        self.reject(lambda c: c["entries"][0].update(limits=""), "empty text")

    def test_stable_ids_and_topics_cannot_silently_collide(self):
        self.reject(lambda c: c["entries"].append(copy.deepcopy(c["entries"][0])), "duplicate entry")
        self.reject(lambda c: c["entries"][0].update(topics=["missing"]), "unknown, missing or duplicate topic")
        self.reject(lambda c: c["topics"].append(dict(id="unused", title="Unused", summary="Unused")), "topic without")

    def test_local_escape_and_private_sources_are_rejected(self):
        for url in ("../secret.md", "/secret.md", "file:///secret.md", "https://" + "localhost/x",
                    "https://user:password@example.org/x", "https://chatgpt.com/c/private"):
            self.reject(lambda c, u=url: c["entries"][0]["sources"][0].update(url=u),
                        "escaping|noncanonical|public HTTPS|private")

    def test_public_https_sources_remain_usable(self):
        self.catalog["entries"][0]["sources"][0]["url"] = "https://github.com/M-simplifier/fp-game-alpha/blob/main/README.md"
        research.validate(self.catalog, self.root)

    def test_duplicate_json_keys_fail_instead_of_replacing_metadata(self):
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            json.loads('{"status":"experiment","status":"implemented"}', object_pairs_hook=research.unique_keys)

    def test_generated_html_is_static_complete_and_escaped(self):
        self.catalog["entries"][0]["summary"] = '<script>alert("bad")</script>'
        document = research.render(self.catalog, self.root)
        page = Page()
        page.feed(document)
        self.assertEqual(page.errors, [])
        self.assertIn("ordered-time", page.ids)
        self.assertNotIn("hidden", page.elements["ordered-time"][1])
        self.assertIn("&lt;script&gt;", document)
        self.assertIn("No device run", document)
        self.assertIn("<noscript>", document)
        self.assertEqual(document, research.render(self.catalog, self.root))

    def test_site_links_stay_local_and_code_links_use_public_repository(self):
        self.assertEqual(research.public_url("site/studies/clock.html#demo", self.root), "studies/clock.html#demo")
        self.assertEqual(research.public_url("source.hs", self.root),
                         research.REPOSITORY + "/blob/main/source.hs")

    def test_image_exception_cannot_admit_remote_or_data_scripts(self):
        page = Page()
        page.feed('<script src="data:text/javascript,alert(1)"></script>')
        check_links(page)
        self.assertTrue(page.errors)
        page = Page()
        page.feed('<img alt="Malformed figure" src="data:image/png;base64,bm90LWEtcG5n">')
        check_links(page)
        self.assertIn("invalid or oversized embedded documentary PNG", page.errors)
        page = Page()
        page.feed('<img alt="Unselected image" src="https://example.org/figure.png">')
        check_links(page)
        self.assertTrue(any("unreviewed remote documentary figure" in error for error in page.errors))


if __name__ == "__main__":
    unittest.main()
