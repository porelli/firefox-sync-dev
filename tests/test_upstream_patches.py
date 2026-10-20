#!/usr/bin/env python3
"""Unit tests of .github/scripts/upstream-patches.py, without the network: GitHub is a
fake with fixtures, the patches go to a git repository in a temporary directory.

Usage: python3 tests/test_upstream_patches.py [-v]
"""

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("upstream_patches", os.path.join(ROOT, ".github", "scripts", "upstream-patches.py"))
up = importlib.util.module_from_spec(spec)
spec.loader.exec_module(up)

PINNED = "a" * 40
NEWER = "b" * 40
BASE = "c" * 40
MERGE = "d" * 40
OTHER = "e" * 40

ORIGINAL = "one\ntwo\nthree\n"
PATCHED = "one\n2\nthree\n"
DIFF = """diff --git a/file.txt b/file.txt
--- a/file.txt
+++ b/file.txt
@@ -1,3 +1,3 @@
 one
-two
+2
 three
"""


def entry(**kw):
    e = {"id": "fix", "repo": "up/stream", "pr": 7, "head_repo": "me/stream", "base": BASE, "sha": PINNED,
         "component": "fxa-mono", "why": "because", "when_released": "drop the workaround in tests/e2e.sh"}
    e.update(kw)
    return e


def pull(state="open", merged=False, head=PINNED, head_repo="me/stream", changed_files=1):
    return {"state": state, "merged": merged, "merge_commit_sha": MERGE, "changed_files": changed_files,
            "head": {"sha": head, "repo": {"full_name": head_repo} if head_repo else None}, "base": {"sha": OTHER}}


# the history: BASE -> PINNED -> NEWER, MERGE in the release only when a test says so
HISTORY = {(BASE, PINNED), (BASE, NEWER), (PINNED, NEWER)}


class FakeGitHub:
    def __init__(self, pulls, contained=(), diff=DIFF, history=HISTORY):
        self.pulls, self.contained, self._diff = pulls, set(contained) | set(history), diff
        self.calls = []

    def pull(self, repo, number):
        self.calls.append(("pull", repo, number))
        return self.pulls[(repo, number)]

    def contains(self, repo, commit, tag):
        self.calls.append(("compare", f"{commit}...{tag}"))
        return commit == tag or (commit, tag) in self.contained

    def diff(self, repo, base, sha):
        self.calls.append(("diff", f"{base}...{sha}"))
        return self._diff


class Checkout:
    """A git repository with file.txt as the release has it."""

    def __init__(self, content=ORIGINAL):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = self.tmp.name
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        with open(os.path.join(self.path, "file.txt"), "w") as f:
            f.write(content)
        for cmd in (["init", "-q"], ["add", "file.txt"], ["commit", "-qm", "release"]):
            subprocess.run(["git", "-C", self.path, *cmd], check=True, env=env)

    def read(self):
        with open(os.path.join(self.path, "file.txt")) as f:
            return f.read()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.tmp.cleanup()


def run(entries, gh, checkout=None, component="fxa-mono", root=None):
    return up.run(entries, component, "v1.2.3", gh, checkout.path if checkout else None, log=lambda *_: None,
                  root=root or ROOT)


# a release where the pull request's diff does not apply (the line moved on), and its port
MOVED = "one\ntwo\nthree\nfour\n".replace("one\n", "zero\n")
PORT = """diff --git a/file.txt b/file.txt
--- a/file.txt
+++ b/file.txt
@@ -1,4 +1,4 @@
 zero
-two
+2
 three
 four
"""


class Ports:
    """A directory like this repository's with ports/fix/<tag>.diff files."""

    def __init__(self, files):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = self.tmp.name
        os.makedirs(os.path.join(self.path, "ports", "fix"))
        for name, content in files.items():
            with open(os.path.join(self.path, "ports", "fix", name), "w") as f:
                f.write(content)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.tmp.cleanup()


class Decisions(unittest.TestCase):
    def test_open_is_applied(self):
        gh = FakeGitHub({("up/stream", 7): pull()})
        with Checkout() as c:
            r = run([entry()], gh, c)
            self.assertEqual(c.read(), PATCHED)
        self.assertEqual([e["id"] for e in r["applied"]], ["fix"])
        self.assertEqual(r["obsolete"], [])
        self.assertEqual(r["notices"], [])
        # the diff of the pinned commit since the pinned base, not the pull request's base now
        self.assertIn(("diff", f"{BASE}...{PINNED}"), gh.calls)
        self.assertNotIn(OTHER, str(gh.calls))
        out = up.outputs(r)
        self.assertEqual(out["applied"], "up/stream#7@ccccccc..aaaaaaa")
        self.assertEqual(out["label"], "up/stream#7@ccccccc..aaaaaaa")
        self.assertEqual(out["obsolete"], "")
        self.assertEqual(out["obsolete_json"], "[]")

    def test_merged_and_released_is_obsolete(self):
        gh = FakeGitHub({("up/stream", 7): pull("closed", True)}, contained={(MERGE, "v1.2.3")})
        with Checkout(PATCHED) as c:
            r = run([entry()], gh, c)
            self.assertEqual(c.read(), PATCHED, "not applied again")
        self.assertEqual(r["applied"], [])
        self.assertEqual([e["id"] for e in r["obsolete"]], ["fix"])
        # plan: no diff needed
        gh = FakeGitHub({("up/stream", 7): pull("closed", True)}, contained={(MERGE, "v1.2.3")})
        r = run([entry()], gh)
        self.assertEqual([e["id"] for e in r["obsolete"]], ["fix"])
        self.assertNotIn("diff", [call[0] for call in gh.calls])
        out = up.outputs(r)
        self.assertEqual(out["label"], "none")
        self.assertEqual(json.loads(out["obsolete_json"]),
                         [{"id": "fix", "pr": "up/stream#7@ccccccc..aaaaaaa", "when_released": "drop the workaround in tests/e2e.sh"}])

    def test_merged_not_released_is_applied(self):
        gh = FakeGitHub({("up/stream", 7): pull("closed", True)})
        with Checkout() as c:
            r = run([entry()], gh, c)
            self.assertEqual(c.read(), PATCHED)
        self.assertEqual([e["id"] for e in r["applied"]], ["fix"])
        self.assertIn(("compare", f"{MERGE}...v1.2.3"), gh.calls)

    def test_merged_and_released_but_not_in_the_sources_fails(self):
        gh = FakeGitHub({("up/stream", 7): pull("closed", True)}, contained={(MERGE, "v1.2.3")})
        with Checkout() as c:
            with self.assertRaisesRegex(up.Fail, "its changes are not in the sources"):
                run([entry()], gh, c)

    def test_sha_not_in_the_pull_requests_history_fails(self):
        # e.g. a commit of another fork of the network, which compare resolves too
        gh = FakeGitHub({("up/stream", 7): pull(head=NEWER)}, history={(BASE, PINNED), (BASE, NEWER)})
        with self.assertRaisesRegex(up.Fail, "not in the history of the pull request"):
            run([entry()], gh)

    def test_base_not_an_ancestor_fails(self):
        gh = FakeGitHub({("up/stream", 7): pull()}, history=set())
        with self.assertRaisesRegex(up.Fail, "not an ancestor"):
            run([entry()], gh)

    def test_other_head_repository_fails(self):
        gh = FakeGitHub({("up/stream", 7): pull(head_repo="mallory/stream")})
        with self.assertRaisesRegex(up.Fail, "mallory/stream"):
            run([entry()], gh)

    def test_head_repository_gone(self):
        with self.assertRaisesRegex(up.Fail, "head repository is gone"):
            run([entry()], FakeGitHub({("up/stream", 7): pull(head_repo=None)}))
        # merged: the fork may be deleted, the commits stay
        r = run([entry()], FakeGitHub({("up/stream", 7): pull("closed", True, head_repo=None)}))
        self.assertEqual(up.outputs(r)["applied"], "up/stream#7@ccccccc..aaaaaaa")

    def test_file_count_of_the_pull_request(self):
        # sha is the head: the diff since base must have the pull request's files (retargeted?)
        gh = FakeGitHub({("up/stream", 7): pull(changed_files=3)})
        with Checkout() as c:
            with self.assertRaisesRegex(up.Fail, "1 files changed since base"):
                run([entry()], gh, c)
        # past sha the count is not comparable
        with Checkout() as c:
            run([entry()], FakeGitHub({("up/stream", 7): pull(head=NEWER, changed_files=3)}), c)
            self.assertEqual(c.read(), PATCHED)

    def test_empty_diff_fails(self):
        with Checkout() as c:
            with self.assertRaisesRegex(up.Fail, "no changes"):
                run([entry()], FakeGitHub({("up/stream", 7): pull()}, diff=""), c)

    def test_closed_unmerged_fails(self):
        gh = FakeGitHub({("up/stream", 7): pull("closed", False)})
        with Checkout() as c:
            with self.assertRaisesRegex(up.Fail, "closed without being merged"):
                run([entry()], gh, c)
            self.assertEqual(c.read(), ORIGINAL)

    def test_closed_unmerged_fails_before_applying_others(self):
        gh = FakeGitHub({("up/stream", 7): pull(), ("up/stream", 8): pull("closed", False)})
        with Checkout() as c:
            with self.assertRaises(up.Fail):
                run([entry(), entry(id="other", pr=8)], gh, c)
            self.assertEqual(c.read(), ORIGINAL)

    def test_head_moved_notice_and_pinned_applied(self):
        gh = FakeGitHub({("up/stream", 7): pull(head=NEWER)})
        with Checkout() as c:
            r = run([entry()], gh, c)
            self.assertEqual(c.read(), PATCHED)
        self.assertEqual(len(r["notices"]), 1)
        self.assertIn("bbbbbbb", r["notices"][0])
        self.assertIn(("diff", f"{BASE}...{PINNED}"), gh.calls)
        self.assertNotIn(("diff", f"{BASE}...{NEWER}"), gh.calls)
        self.assertEqual(up.outputs(r)["applied"], "up/stream#7@ccccccc..aaaaaaa")

    def test_conflict_fails(self):
        gh = FakeGitHub({("up/stream", 7): pull()})
        with Checkout("one\nTWO, changed by the release\nthree\n") as c:
            with self.assertRaisesRegex(up.Fail, "does not apply"):
                run([entry()], gh, c)

    def test_already_in_the_sources_is_obsolete(self):
        # e.g. cherry-picked to the release branch: the merge commit is not in the tag
        gh = FakeGitHub({("up/stream", 7): pull("closed", True)})
        with Checkout(PATCHED) as c:
            r = run([entry()], gh, c)
            self.assertEqual(c.read(), PATCHED)
        self.assertEqual([e["id"] for e in r["obsolete"]], ["fix"])
        self.assertEqual(r["applied"], [])

    def test_plan_does_not_touch_anything(self):
        gh = FakeGitHub({("up/stream", 7): pull()})
        r = run([entry()], gh)
        self.assertEqual(up.outputs(r)["applied"], "up/stream#7@ccccccc..aaaaaaa")
        self.assertNotIn("diff", [call[0] for call in gh.calls])

    def test_other_component_ignored(self):
        gh = FakeGitHub({})
        r = run([entry(component="syncstorage-rs")], gh)
        self.assertEqual(up.outputs(r)["label"], "none")
        self.assertEqual(gh.calls, [])

    def test_base_in_label_and_key(self):
        # a correction of base alone must rebuild
        gh = FakeGitHub({("up/stream", 7): pull()}, history=HISTORY | {(OTHER, PINNED)})
        one, two = up.outputs(run([entry()], gh)), up.outputs(run([entry(base=OTHER)], gh))
        self.assertEqual(two["label"], "up/stream#7@eeeeeee..aaaaaaa")
        self.assertNotEqual(one["key"], two["key"])

    def test_port_applied(self):
        # the release has its own file: applied instead of base...sha, named in the label
        gh = FakeGitHub({("up/stream", 7): pull()})
        with Ports({"v1.2.3.diff": PORT}) as p, Checkout(MOVED) as c:
            r = run([entry(ports="ports/fix")], gh, c, root=p.path)
            self.assertEqual(c.read(), MOVED.replace("two", "2"))
            plan = run([entry(ports="ports/fix")], FakeGitHub({("up/stream", 7): pull()}), root=p.path)
        self.assertNotIn("diff", [call[0] for call in gh.calls])
        out = up.outputs(r)
        self.assertEqual(out["label"], "up/stream#7@ccccccc..aaaaaaa+v1.2.3")
        self.assertEqual(up.outputs(plan)["label"], out["label"], "the plan knows the port too")
        self.assertIn("up/stream#7@", out["label"])
        # the pull request is still checked: closed unmerged fails with a port too
        with Ports({"v1.2.3.diff": PORT}) as p, Checkout(MOVED) as c:
            with self.assertRaisesRegex(up.Fail, "closed without being merged"):
                run([entry(ports="ports/fix")], FakeGitHub({("up/stream", 7): pull("closed", False)}), c, root=p.path)

    def test_port_that_does_not_apply_fails(self):
        with Ports({"v1.2.3.diff": PORT}) as p, Checkout() as c:
            with self.assertRaisesRegex(up.Fail, "port ports/fix/v1.2.3.diff does not apply"):
                run([entry(ports="ports/fix")], FakeGitHub({("up/stream", 7): pull()}), c, root=p.path)
            self.assertEqual(c.read(), ORIGINAL)

    def test_missing_port_and_pull_request_not_applying_fails(self):
        # a new release without a port: base...sha, which does not apply: the build fails
        with Ports({}) as p, Checkout(MOVED) as c:
            with self.assertRaisesRegex(up.Fail, r"does not apply to the release(.|\n)*add a port for it \(ports/fix/<release-tag>.diff\)"):
                run([entry(ports="ports/fix")], FakeGitHub({("up/stream", 7): pull()}), c, root=p.path)
            self.assertEqual(c.read(), MOVED)

    def test_port_of_another_release_ignored(self):
        # v1.0.0's port is not for v1.2.3 (it would not even apply): base...sha as always
        gh = FakeGitHub({("up/stream", 7): pull()})
        with Ports({"v1.0.0.diff": PORT, "v1.2.3.diff.orig": PORT}) as p, Checkout() as c:
            r = run([entry(ports="ports/fix")], gh, c, root=p.path)
            self.assertEqual(c.read(), PATCHED)
        self.assertIn(("diff", f"{BASE}...{PINNED}"), gh.calls)
        self.assertEqual(up.outputs(r)["label"], "up/stream#7@ccccccc..aaaaaaa")

    def test_newest_older_port_when_the_pull_request_does_not_apply(self):
        # a new release without its port, base...sha does not apply: the newest port of an
        # older release, by version (v1.2.2 > v1.1.9; v1.2.10 is newer than v1.2.3, not used)
        gh = FakeGitHub({("up/stream", 7): pull()})
        broken = PORT.replace("zero", "nothing like it")
        with Ports({"v1.1.9.diff": broken, "v1.2.2.diff": PORT, "v1.2.10.diff": broken}) as p, Checkout(MOVED) as c:
            r = run([entry(ports="ports/fix")], gh, c, root=p.path)
            self.assertEqual(c.read(), MOVED.replace("two", "2"))
            plan = run([entry(ports="ports/fix")], FakeGitHub({("up/stream", 7): pull()}), root=p.path)
        self.assertIn(("diff", f"{BASE}...{PINNED}"), gh.calls, "base...sha first")
        out = up.outputs(r)
        self.assertEqual(out["label"], "up/stream#7@ccccccc..aaaaaaa+v1.2.2", "the port used")
        self.assertEqual(len(r["warnings"]), 1)
        self.assertIn("ports/fix/v1.2.2.diff", r["warnings"][0])
        self.assertIn("add ports/fix/v1.2.3.diff", r["warnings"][0])
        self.assertIn("ports/fix/v1.2.2.diff", up.summary(r, "fxa-mono", "v1.2.3"))
        # plan has no sources to try it on: base...sha, as the build would first
        self.assertEqual(up.outputs(plan)["label"], "up/stream#7@ccccccc..aaaaaaa")
        self.assertEqual(plan["warnings"], [])

    def test_older_port_unused_when_the_pull_request_applies(self):
        gh = FakeGitHub({("up/stream", 7): pull()})
        with Ports({"v1.2.2.diff": PORT}) as p, Checkout() as c:
            r = run([entry(ports="ports/fix")], gh, c, root=p.path)
            self.assertEqual(c.read(), PATCHED)
        self.assertEqual(up.outputs(r)["label"], "up/stream#7@ccccccc..aaaaaaa")
        self.assertEqual(r["warnings"], [])

    def test_neither_the_pull_request_nor_the_older_port_applies_fails(self):
        with Ports({"v1.2.2.diff": PORT}) as p, Checkout("one\nTWO, changed by the release\nthree\n") as c:
            with self.assertRaisesRegex(up.Fail, r"does not apply to the release(.|\n)*nor does the newest port, ports/fix/v1.2.2.diff"):
                run([entry(ports="ports/fix")], FakeGitHub({("up/stream", 7): pull()}), c, root=p.path)
            self.assertEqual(c.read(), "one\nTWO, changed by the release\nthree\n")

    def test_older_port_already_in_the_sources_is_obsolete(self):
        with Ports({"v1.2.2.diff": PORT}) as p, Checkout(MOVED.replace("two", "2")) as c:
            r = run([entry(ports="ports/fix")], FakeGitHub({("up/stream", 7): pull()}), c, root=p.path)
            self.assertEqual(c.read(), MOVED.replace("two", "2"))
        self.assertEqual(r["applied"], [])
        self.assertEqual([e["id"] for e in r["obsolete"]], ["fix"])
        self.assertEqual(r["warnings"], [])

    def test_fallback_port_choice(self):
        with Ports({"v1.2.2.diff": PORT, "v1.3.0.diff": PORT, "notes.txt": "", "latest.diff": PORT}) as p:
            e = entry(ports="ports/fix")
            self.assertEqual(up.fallback_port(e, "v1.2.3", p.path)["port_tag"], "v1.2.2")
            self.assertEqual(up.fallback_port(e, "v1.4.0", p.path)["port_tag"], "v1.3.0")
            self.assertIsNone(up.fallback_port(e, "v1.2.2", p.path), "only older releases")
            self.assertIsNone(up.fallback_port(e, "main", p.path), "not a version")
            self.assertIsNone(up.fallback_port(entry(), "v1.2.3", p.path), "no ports")
            # the release's own port is not a fallback
            self.assertIsNone(up.fallback_port(up.with_port(e, "v1.2.2", p.path), "v1.2.2", p.path))

    def test_warning_printed(self):
        with Ports({"v1.2.2.diff": PORT}) as p, Checkout(MOVED) as c:
            patches = os.path.join(p.path, "upstream-patches.yml")
            with open(patches, "w") as f:
                f.write("- id: fix\n  repo: up/stream\n  pr: 7\n  head_repo: me/stream\n  base: " + BASE + "\n  sha: " + PINNED +
                        "\n  component: fxa-mono\n  ports: ports/fix\n  why: w\n  when_released: x\n")
            old_gh, old_env = up.GitHub, os.environ.get("UPSTREAM_PATCHES_FILE")
            up.GitHub = lambda: FakeGitHub({("up/stream", 7): pull()})
            os.environ["UPSTREAM_PATCHES_FILE"] = patches
            try:
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(up.main(["apply", "fxa-mono", "v1.2.3", c.path]), 0)
            finally:
                up.GitHub = old_gh
                os.environ.pop("UPSTREAM_PATCHES_FILE") if old_env is None else os.environ.__setitem__("UPSTREAM_PATCHES_FILE", old_env)
        self.assertRegex(out.getvalue(), r"::warning title=upstream-patches.yml::up/stream#7@ccccccc..aaaaaaa\+v1.2.2 .*add ports/fix/v1.2.3.diff")
        self.assertIn("label=up/stream#7@ccccccc..aaaaaaa+v1.2.2\n", out.getvalue())

    def test_key_follows_label(self):
        gh = FakeGitHub({("up/stream", 7): pull()})
        self.assertNotEqual(up.outputs(run([entry()], gh))["key"], up.outputs(run([], gh))["key"])


class Parse(unittest.TestCase):
    def test_file_of_this_repository(self):
        with open(os.path.join(ROOT, "upstream-patches.yml")) as f:
            entries = up.parse(f.read())
        self.assertTrue(entries)
        for e in entries:
            self.assertIn(e["component"], up.COMPONENTS)
            self.assertNotIn("\n", e["why"] + e["when_released"])
            if e.get("ports"):
                ports = os.path.join(ROOT, e["ports"])
                self.assertTrue(os.path.isdir(ports), ports)
                for name in os.listdir(ports):
                    self.assertRegex(name, r"^v[0-9]+\.[0-9]+\.[0-9]+\.diff$", f"{e['ports']}/{name}: <release-tag>.diff")

    def test_folded_and_quoted(self):
        e = up.parse("# c\n- id: a\n  repo: o/r\n  pr: 1\n  head_repo: me/r\n  base: " + BASE + "\n  sha: " + PINNED + "\n  component: 'fxa-mono'\n"
                     "  why: >-\n    first\n    second\n  when_released: \"x # y\"\n")
        self.assertEqual(e, [entry(id="a", repo="o/r", pr=1, head_repo="me/r", why="first second", when_released="x # y")])

    def test_ports_optional(self):
        good = "- id: a\n  repo: o/r\n  pr: 1\n  head_repo: me/r\n  base: " + BASE + "\n  sha: " + PINNED + "\n  component: fxa-mono\n  why: w\n  when_released: x\n"
        self.assertNotIn("ports", up.parse(good)[0])
        self.assertEqual(up.parse(good + "  ports: upstream-patches/a\n")[0]["ports"], "upstream-patches/a")

    def test_errors(self):
        good = "- id: a\n  repo: o/r\n  pr: 1\n  head_repo: me/r\n  base: " + BASE + "\n  sha: " + PINNED + "\n  component: fxa-mono\n  why: w\n  when_released: x\n"
        for bad, message in ((good.replace("  why: w\n", ""), "missing why"),
                             (good.replace("fxa-mono", "other"), "component"),
                             (good.replace(PINNED, "abc1234"), "sha must be a full commit"),
                             (good.replace(BASE, "abc1234"), "base must be a full commit"),
                             (good.replace("head_repo: me/r", "head_repo: me"), "head_repo must be owner/name"),
                             (good.replace("pr: 1", "pr: x"), "number"),
                             (good + "  extra: 1\n", "unknown extra"),
                             (good + good, "unique"),
                             (good.replace("why: w", "why: [w]"), "plain or quoted"),
                             (good + "  ports: ../elsewhere\n", "ports must be a relative directory"),
                             (good + "  ports: /abs\n", "ports must be a relative directory")):
            with self.assertRaisesRegex(ValueError, message):
                up.parse(bad)


class StubGitHub(up.GitHub):
    """The real methods, gh replaced by answers per path."""

    def __init__(self, answers):
        self.answers, self.paths = answers, []

    def _api(self, path, accept=None):
        self.paths.append((path, accept))
        # the same compare path answers the status (JSON) or the diff
        answer = self.answers[(path, accept) if accept else path]
        if isinstance(answer, Exception):
            raise answer
        return answer


class RealGitHub(unittest.TestCase):
    def test_contains_by_compare_status(self):
        for status, contained in (("identical", True), ("ahead", True), ("behind", False), ("diverged", False)):
            gh = StubGitHub({"repos/o/r/compare/x...v1": json.dumps({"status": status})})
            self.assertIs(gh.contains("o/r", "x", "v1"), contained, status)

    def test_gh_failure(self):
        class Failed:
            returncode, stdout, stderr = 1, "", "HTTP 404: Not Found"
        old = up.subprocess.run
        up.subprocess.run = lambda *a, **kw: Failed()
        try:
            with self.assertRaisesRegex(up.Fail, "gh api repos/o/r/pulls/1: HTTP 404"):
                up.GitHub().pull("o/r", 1)
        finally:
            up.subprocess.run = old

    def test_diff_asks_for_a_diff(self):
        gh = StubGitHub({(f"repos/o/r/compare/{BASE}...{PINNED}", "application/vnd.github.diff"): DIFF})
        self.assertEqual(gh.diff("o/r", BASE, PINNED), DIFF)
        self.assertEqual(gh.paths, [(f"repos/o/r/compare/{BASE}...{PINNED}", "application/vnd.github.diff")])

    def test_empty_diff_from_github_fails(self):
        gh = StubGitHub({"repos/up/stream/pulls/7": json.dumps(pull()),
                         (f"repos/up/stream/compare/{BASE}...{PINNED}", "application/vnd.github.diff"): ""})
        gh.answers.update({f"repos/up/stream/compare/{a}...{b}": json.dumps({"status": "ahead"}) for a, b in HISTORY})
        with Checkout() as c:
            with self.assertRaisesRegex(up.Fail, "no changes"):
                run([entry()], gh, c)


class Main(unittest.TestCase):
    def test_usage(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(up.main([]), 2)
            self.assertEqual(up.main(["apply", "fxa-mono", "v1"]), 2)
            self.assertEqual(up.main(["plan", "other", "v1"]), 2)

    def test_outputs_and_summary_files(self):
        with tempfile.TemporaryDirectory() as d:
            patches = os.path.join(d, "p.yml")
            with open(patches, "w") as f:
                f.write("")
            env = {"UPSTREAM_PATCHES_FILE": patches, "GITHUB_OUTPUT": os.path.join(d, "out"), "GITHUB_STEP_SUMMARY": os.path.join(d, "sum")}
            old = {k: os.environ.get(k) for k in env}
            os.environ.update(env)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(up.main(["plan", "fxa-mono", "v1"]), 0)
            finally:
                for k, v in old.items():
                    os.environ.pop(k) if v is None else os.environ.__setitem__(k, v)
            with open(env["GITHUB_OUTPUT"]) as f:
                self.assertIn("label=none\n", f.read())
            with open(env["GITHUB_STEP_SUMMARY"]) as f:
                self.assertIn("None in upstream-patches.yml", f.read())


if __name__ == "__main__":
    unittest.main()
