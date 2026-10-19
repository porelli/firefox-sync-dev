#!/usr/bin/env python3
"""Self-test of tests/check_markdown_links.py on fixtures: python3 -I tests/test_check_markdown_links.py"""

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("checker", Path(__file__).resolve().parent / "check_markdown_links.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def tree(files):
    d = tempfile.TemporaryDirectory()
    for name, text in files.items():
        p = Path(d.name) / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    return d


def run(files, code=False, settings=False):
    with tree(files) as root:
        c = checker.Checker(root)
        c.check_docs()
        if code:
            c.check_code()
        if settings:
            c.check_settings()
        return c.errors


class Slugs(unittest.TestCase):
    def test_slug(self):
        self.assertEqual(checker.slug("Restore with Quadlets"), "restore-with-quadlets")
        self.assertEqual(checker.slug("`SYNC_MAX_USERS`"), "sync_max_users")
        self.assertEqual(checker.slug("Sync on [MariaDB](https://mariadb.org) or MySQL"), "sync-on-mariadb-or-mysql")
        self.assertEqual(checker.slug("The admin UI's own database"), "the-admin-uis-own-database")
        self.assertEqual(checker.slug("MySQL 8 to 9"), "mysql-8-to-9")
        self.assertEqual(checker.slug("Slack, Discord, Teams: webhooks"), "slack-discord-teams-webhooks")
        self.assertEqual(checker.slug("A  -  b"), "a-----b")
        self.assertEqual(checker.slug("_emphasis_ and **bold**"), "emphasis-and-bold")


class Docs(unittest.TestCase):
    def test_duplicate_headings(self):
        errors = run({"a.md": "# T\n## Setup\n## Setup\n## Setup\n[x](#setup) [y](#setup-1) [z](#setup-2)\n[w](#setup-3)\n"})
        self.assertEqual(len(errors), 1)
        self.assertIn("#setup-3", errors[0])
        self.assertTrue(errors[0].startswith("a.md:6:"))

    def test_heading_with_a_link(self):
        self.assertEqual(run({"a.md": "## Sync on [MariaDB](/b.md)\n[x](#sync-on-mariadb)\n", "b.md": ""}), [])

    def test_heading_inside_a_fence(self):
        errors = run({"a.md": "```bash\n# not a heading\n```\n~~~\n## nor this\n~~~\n[x](#not-a-heading) [y](#nor-this)\n"})
        self.assertEqual(len(errors), 2)

    def test_fence_in_a_list(self):
        errors = run({"a.md": "1. Step\n\n    ```bash\n    # comment\n    ```\n\n## After\n[x](#after)\n"})
        self.assertEqual(errors, [])

    def test_relative_link_from_a_subfolder(self):
        files = {"docs/admin/a.md": "[up](../b.md#here) [img](../images/x.png) [dir](../images/) [bad](b.md)\n",
                 "docs/b.md": "## Here\n", "docs/images/x.png": "png"}
        errors = run(files)
        self.assertEqual(len(errors), 1)
        self.assertIn("docs/admin/b.md does not exist", errors[0])

    def test_repository_absolute_link(self):
        files = {"docs/a.md": "[sql](/db/sync.sql) [no](/db/nope.sql) [top](/README.md#credits)\n",
                 "db/sync.sql": "", "README.md": "## Credits\n"}
        errors = run(files)
        self.assertEqual(len(errors), 1)
        self.assertIn("/db/nope.sql", errors[0])

    def test_missing_anchor_in_another_file(self):
        errors = run({"a.md": "[x](b.md#nope)\n", "b.md": "## Yes\n"})
        self.assertEqual(len(errors), 1)
        self.assertIn("no heading for #nope in b.md", errors[0])

    def test_code_spans_and_html(self):
        files = {"a.md": "`[not](a/link.md)` <a id=\"custom\"></a>\n[x](#custom) <img src=\"gone.png\">\n"
                         "[ref]: missing.md\n"}
        errors = run(files)
        self.assertEqual(len(errors), 2)
        self.assertTrue(any("gone.png" in e for e in errors))
        self.assertTrue(any("missing.md" in e for e in errors))

    def test_external_and_blob_urls(self):
        files = {"a.md": "[ext](https://example.com/x.md) [mail](mailto:a@b.c)\n"
                         "[ok](https://github.com/porelli/firefox-sync/blob/main/docs/b.md#yes)\n"
                         "[bad](https://github.com/porelli/firefox-sync/blob/main/docs/b.md#no)\n"
                         "[gone](https://github.com/porelli/firefox-sync/blob/main/HELM.md)\n",
                 "docs/b.md": "## Yes\n"}
        errors = run(files)
        self.assertEqual(len(errors), 2)

    def test_link_with_parentheses_and_title(self):
        self.assertEqual(run({"a.md": "[x](b.md \"title\") [y](<b.md>)\n", "b.md": ""}), [])


class Code(unittest.TestCase):
    def test_references_in_code(self):
        files = {"docs/backups.md": "## Restore\n",
                 "admin/web.go": "// see docs/backups.md#restore\n// and ADMIN.md#restoring\n"
                                 "// docs/backups.md#nope\n// a CHANGELOG.md upstream  # check-links: ignore\n"
                                 "// ${{ env.X }}/CHANGELOG.md > ../release-notes.md\n",
                 "charts/NOTES.txt": "https://github.com/porelli/firefox-sync/blob/main/docs/backups.md#restore\n"
                                     "https://github.com/mozilla/fxa/blob/main/README.md\n"}
        errors = run(files, code=True)
        self.assertEqual(len(errors), 2, errors)
        self.assertTrue(any("ADMIN.md#restoring" in e and e.startswith("admin/web.go:2:") for e in errors))
        self.assertTrue(any("#nope" in e for e in errors))
        self.assertEqual(run(files), [])

    def test_relative_to_the_file(self):
        files = {"charts/c/README.md": "", "charts/c/Chart.yaml": "readme: README.md\n"}
        self.assertEqual(run(files, code=True), [])


class Settings(unittest.TestCase):
    def test_settings(self):
        files = {"docs/reference/settings.md": "| `SYNC_DB` | `database.backend` |\n",
                 ".env-example": "SYNC_DB=mariadb\n# SYNC_MYSQL_IMAGE=mysql:lts\n# a comment, X=1\n",
                 "charts/firefox-sync/values.yaml": "database:\n  backend: mariadb\nbackup:\n  enabled: false\n"}
        errors = run(files, settings=True)
        self.assertEqual(len(errors), 2, errors)
        self.assertTrue(any("SYNC_MYSQL_IMAGE" in e for e in errors))
        self.assertTrue(any("backup is not" in e for e in errors))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
