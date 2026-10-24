"""Keep localized Pages output and its versioned assets in sync."""

import hashlib
from html.parser import HTMLParser
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[3]
SITE = ROOT / "Web/site"


class StylesheetLinks(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []
        self.scripts = []
        self.languages = []
        self.html_lang = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "link" and attrs.get("rel") == "stylesheet":
            self.hrefs.append(attrs.get("href"))
        if tag == "script":
            self.scripts.append(attrs.get("src"))
        if tag == "link" and attrs.get("rel") == "alternate":
            self.languages.append(attrs.get("hreflang"))
        if tag == "html":
            self.html_lang = attrs.get("lang")


class SiteAssetsTests(unittest.TestCase):
    def test_stylesheet_url_changes_with_contents(self):
        css_digests = {
            name: hashlib.sha256((SITE / name).read_bytes()).hexdigest()[:12]
            for name in ("tokens.css", "base.css", "styles.css")
        }
        js_digest = hashlib.sha256((SITE / "site.js").read_bytes()).hexdigest()[:12]
        languages = {"en", "tr", "ru", "de", "fr", "zh-Hans", "ja"}
        for language in [None, *sorted(languages)]:
            with self.subTest(language=language):
                path = SITE / language / "index.html" if language else SITE / "index.html"
                links = StylesheetLinks()
                links.feed(path.read_text(encoding="utf-8"))
                prefix = "../" if language else ""
                self.assertEqual(
                    links.hrefs,
                    [f"{prefix}{name}?v={digest}" for name, digest in css_digests.items()],
                )
                script_prefix = "/" if language else ""
                self.assertEqual(links.scripts, [f"{script_prefix}site.js?v={js_digest}"])
                if language:
                    self.assertEqual(links.html_lang, language)
                    self.assertEqual(set(links.languages), languages | {"x-default"})

    def test_generated_pages_are_current(self):
        result = subprocess.run(
            ["python3", str(ROOT / "Web/generate_site.py"), "--check"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_private_repository_is_not_linked_from_public_pages(self):
        generator = (ROOT / "Web/generate_site.py").read_text(encoding="utf-8")
        if "\nPUBLIC_REPO = True" in generator:
            self.skipTest("the repository is public, so the site may link to it")
        for language in ("en", "tr", "ru", "de", "fr", "zh-Hans", "ja"):
            with self.subTest(language=language):
                html = (SITE / language / "index.html").read_text(encoding="utf-8")
                self.assertNotIn("https://github.com/alperenalan/UpdateAtlas", html)
                self.assertNotIn("https://github.com/alperenalan/updateatlas-release", html)

    def test_creator_credit_links_to_main_site(self):
        for language in ("en", "tr", "ru", "de", "fr", "zh-Hans", "ja"):
            with self.subTest(language=language):
                html = (SITE / language / "index.html").read_text(encoding="utf-8")
                self.assertRegex(html, r'<a href="https://alperenalan\.com/">[^<]*Alperen Alan[^<]*</a>')
                if language != "en":
                    self.assertNotIn('>by Alperen Alan</a>', html)


if __name__ == "__main__":
    unittest.main()
