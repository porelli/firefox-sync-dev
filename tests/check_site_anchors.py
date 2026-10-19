#!/usr/bin/env python3
"""Every #anchor of the docs, as GitHub makes it, is an id of the built site's page.

Usage: python3 -I tests/check_site_anchors.py [--site DIR]   (after mkdocs build; default: site)

tests/check_markdown_links.py computes the anchors of each page of docs/ with GitHub's slug
rules (the headings, <a id>, <a name>): the pages, the admin UI, the scripts and the chart link
to those. This checks that the page MkDocs built from each file has an element with each of
those ids, so the same #anchor works on GitHub and on the site. Stdlib only.
"""

import argparse
import importlib.util
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("checker", ROOT / "tests" / "check_markdown_links.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class Ids(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        for k, v in attrs:
            if k in ("id", "name") and v:
                self.ids.add(v)


def page_of(site, rel):
    """docs/x/README.md -> site/x/index.html, docs/x/y.md -> site/x/y/index.html"""
    return site / rel.parent / ("index.html" if rel.name == "README.md" else f"{rel.stem}/index.html")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--site", default=ROOT / "site", type=Path, help="the built site (default: site)")
    args = p.parse_args(argv)
    errors, anchors = [], 0
    for md in sorted((ROOT / "docs").rglob("*.md")):
        rel = md.relative_to(ROOT / "docs")
        html = page_of(args.site, rel)
        if not html.exists():
            errors.append(f"docs/{rel}: no page {html.relative_to(args.site)} in the site")
            continue
        ids = Ids()
        ids.feed(html.read_text(encoding="utf-8"))
        for a in sorted(checker.Doc(md).anchors):
            anchors += 1
            if a not in ids.ids:
                errors.append(f"docs/{rel}: #{a} is not an id of {html.relative_to(args.site)}")
    for e in errors:
        print(e)
    print(f"{len(errors)} error(s), {anchors} anchors checked", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
