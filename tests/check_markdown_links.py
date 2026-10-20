#!/usr/bin/env python3
"""Check the links of the documentation: files, directories and #anchors.

Usage: python3 -I tests/check_markdown_links.py [--code] [--settings] [--external] [--root DIR]

- Files: the tracked *.md files (git ls-files; every *.md under DIR when it is not a git
  repository), but tests/browser.
- Links: [text](target), ![alt](target), reference definitions ([x]: target) and the
  href/src of HTML tags, outside fenced code and inline code. A target starting with / is
  resolved from the repository root, any other from the file's directory. The file or
  directory must exist.
- Anchors: GitHub's slugs of the headings outside fences, from their rendered text (link,
  image, code and emphasis syntax removed): lowercased, every character but letters, digits,
  marks, -, _ and spaces removed, each space turned into -, duplicates suffixed -1, -2...
  Also <a id="..."> and <a name="...">. Checked for #anchor and file.md#anchor.
- Absolute https://github.com/porelli/firefox-sync/blob|tree/main/<path>#anchor URLs are
  checked against the tree.
- --code: the doc references of the other tracked text files: a path under docs/ or to an
  uppercase NAME.md (README.md, an old root doc), with its #anchor, and the blob/main URLs.
  Resolved from the root, or else the file's directory. A path after a variable (${X}/x.md)
  and a line with "check-links: ignore" are skipped.
- --settings: every NAME= of .env-example (commented ones too) and every top-level key of
  charts/firefox-sync/values.yaml appears in docs/reference/settings.md.
- --external: also fetches every http(s) link of docs/ and README.md (HEAD, else GET,
  following redirects) and reports those that do not end in a 2xx. Needs the network, so
  CI does not run it: run it by hand when editing the docs' links. Only says that a page
  answers, not that it is about what the sentence says.

Prints one line per error, file:line: message, and exits 1 when there is any. Stdlib only.
"""

import argparse
import concurrent.futures
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request
from urllib.parse import unquote

REPO_URL = re.compile(r"https://github\.com/porelli/firefox-sync/(?:blob|tree)/main/([^\s)\"'<>`#]*)(#[\w-]+)?")
EXCLUDE = ("tests/browser/",)
# the checker and its fixtures name files that do not exist on purpose
CODE_EXCLUDE = ("tests/check_markdown_links.py", "tests/test_check_markdown_links.py")

FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
HEADING = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$")
HTML_ANCHOR = re.compile(r"<a\s[^>]*?\b(?:id|name)\s*=\s*[\"']([^\"']+)[\"']", re.I)
HTML_LINK = re.compile(r"<(?:a|img)\s[^>]*?\b(?:href|src)\s*=\s*[\"']([^\"']+)[\"']", re.I)
REF_DEF = re.compile(r"^ {0,3}\[[^\]]+\]:\s*<?([^\s>]+)>?")
CODE_SPAN = re.compile(r"(`+)(.+?)\1")
CODE_REF = re.compile(r"(?<![\w.-])((?:[\w.-]+/)*[\w.-]*[A-Za-z]\.md)(#[\w-]+)?(?![\w])")


def find_links(line):
    """The targets of [text](target) and ![alt](target) in a line without code spans."""
    out = []
    i = 0
    while True:
        j = line.find("](", i)
        if j < 0:
            return out
        k = j + 2
        depth = 1
        while k < len(line) and depth:
            if line[k] == "(":
                depth += 1
            elif line[k] == ")":
                depth -= 1
            k += 1
        target = line[j + 2:k - 1].strip() if depth == 0 else ""
        if target.startswith("<") and ">" in target:
            target = target[1:target.index(">")]
        else:
            target = target.split()[0] if target else ""
        if target:
            out.append(target)
        i = j + 2


def strip_code_spans(line):
    return CODE_SPAN.sub(lambda m: " " * len(m.group(0)), line)


def rendered(text):
    """The text GitHub renders for a heading's markdown."""
    parts = []
    pos = 0
    for m in CODE_SPAN.finditer(text):
        parts.append((False, text[pos:m.start()]))
        parts.append((True, m.group(2).strip()))
        pos = m.end()
    parts.append((False, text[pos:]))
    out = []
    for code, part in parts:
        if not code:
            part = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", part)
            part = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", part)
            part = re.sub(r"\[([^\]]*)\]\[[^\]]*\]", r"\1", part)
            part = re.sub(r"<[^>]+>", "", part)
            part = re.sub(r"(?<![\w])_(\S(?:.*?\S)?)_(?![\w])", r"\1", part)
            part = part.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
        out.append(part)
    return "".join(out)


def slug(text):
    keep = []
    for c in rendered(text).strip().lower():
        cat = unicodedata.category(c)
        if c in "-_ " or cat[0] in "LNM" or cat == "Pc":
            keep.append(c)
    return "".join(keep).replace(" ", "-")


class Doc:
    """A markdown file: its anchors and its links (target, line)."""

    def __init__(self, path):
        self.anchors = set()
        self.links = []
        seen = {}
        fence = None
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            m = FENCE.match(line)
            if fence:
                if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not line.strip()[len(m.group(1)):].strip():
                    fence = None
                continue
            if m:
                fence = m.group(1)
                continue
            for a in HTML_ANCHOR.findall(line):
                self.anchors.add(a)
            h = HEADING.match(line)
            if h:
                base = slug(h.group(2))
                count = seen.get(base, 0)
                seen[base] = count + 1
                self.anchors.add(base if count == 0 else f"{base}-{count}")
            plain = strip_code_spans(line)
            for t in find_links(plain):
                self.links.append((t, n))
            for t in HTML_LINK.findall(plain):
                self.links.append((t, n))
            r = REF_DEF.match(plain)
            if r:
                self.links.append((r.group(1), n))


class Checker:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.docs = {}
        self.errors = []

    def error(self, where, line, msg):
        self.errors.append(f"{where}:{line}: {msg}")

    def files(self, pattern=None):
        try:
            out = subprocess.run(["git", "-C", str(self.root), "ls-files", "-z"], check=True,
                                 capture_output=True).stdout.decode().split("\0")
            names = [f for f in out if f]
        except (subprocess.CalledProcessError, FileNotFoundError):
            names = [str(p.relative_to(self.root)) for p in self.root.rglob("*")
                     if p.is_file() and ".git" not in p.parts]
        names = [n.replace(os.sep, "/") for n in names]
        names = [n for n in names if not n.startswith(EXCLUDE) and (self.root / n).is_file()]
        if pattern == "md":
            return sorted(n for n in names if n.endswith(".md"))
        return sorted(n for n in names if not n.endswith(".md"))

    def doc(self, path):
        if path not in self.docs:
            self.docs[path] = Doc(path)
        return self.docs[path]

    def check_target(self, where, line, path, anchor, raw):
        """path: a resolved Path, or None for the same file; anchor without #, or None."""
        if path is None:
            path = self.root / where
        try:
            path.resolve().relative_to(self.root)
        except ValueError:
            self.error(where, line, f"{raw}: outside the repository")
            return
        if not path.exists():
            self.error(where, line, f"{raw}: {path.relative_to(self.root) if path.is_absolute() else path} does not exist")
            return
        if anchor and path.is_file() and path.suffix == ".md":
            if anchor not in self.doc(path).anchors:
                self.error(where, line, f"{raw}: no heading for #{anchor} in {path.resolve().relative_to(self.root)}")

    def check_url(self, where, line, url):
        m = REPO_URL.match(url)
        if not m:
            return
        path, anchor = unquote(m.group(1)).rstrip("/"), m.group(2)
        self.check_target(where, line, self.root / path if path else self.root,
                          anchor[1:] if anchor else None, url)

    def check_link(self, where, line, target):
        if target.startswith(("http://", "https://")):
            self.check_url(where, line, target)
            return
        if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I):  # mailto:, ftp:...
            return
        path, _, anchor = target.partition("#")
        path = unquote(path)
        if not path:
            self.check_target(where, line, None, anchor or None, target)
            return
        base = self.root if path.startswith("/") else (self.root / where).parent
        self.check_target(where, line, base / path.lstrip("/"), anchor or None, target)

    def check_docs(self):
        for name in self.files("md"):
            for target, line in self.doc(self.root / name).links:
                self.check_link(name, line, target)

    def check_code(self):
        for name in self.files():
            if name in CODE_EXCLUDE:
                continue
            data = (self.root / name).read_bytes()
            if b"\0" in data[:8192]:
                continue
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                continue
            for n, line in enumerate(text.splitlines(), 1):
                if "check-links: ignore" in line:
                    continue
                for m in REPO_URL.finditer(line):
                    self.check_url(name, n, m.group(0))
                scrubbed = re.sub(r"\w+://\S+", " ", line)
                for m in CODE_REF.finditer(scrubbed):
                    ref, anchor = m.group(1), m.group(2)
                    if not ("docs/" in ref or re.match(r"^[A-Z][A-Z0-9_-]*\.md$", ref.rsplit("/", 1)[-1])):
                        continue  # a lowercase file of its own (release-notes.md), not a doc
                    if scrubbed[:m.start()].endswith(("}/", "}")):
                        continue  # a path built from a variable: ${X}/README.md
                    rel = ref[2:] if ref.startswith("./") else ref.lstrip("/")
                    path = self.root / rel
                    if not path.exists() and (self.root / name).parent.joinpath(ref).exists():
                        path = (self.root / name).parent / ref
                    if name == "mkdocs.yml" and not path.exists():
                        path = self.root / "docs" / rel  # the nav names pages from docs_dir
                    self.check_target(name, n, path, anchor[1:] if anchor else None, m.group(0))

    def check_settings(self):
        settings = self.root / "docs/reference/settings.md"
        if not settings.exists():
            self.error("docs/reference/settings.md", 0, "does not exist")
            return
        text = settings.read_text(encoding="utf-8")
        env = self.root / ".env-example"
        if env.exists():
            for n, line in enumerate(env.read_text(encoding="utf-8").splitlines(), 1):
                m = re.match(r"^#? ?([A-Z][A-Z0-9_]*)=", line)
                if m and f"`{m.group(1)}" not in text:
                    self.error(".env-example", n, f"{m.group(1)} is not in docs/reference/settings.md")
        values = self.root / "charts/firefox-sync/values.yaml"
        if values.exists():
            for n, line in enumerate(values.read_text(encoding="utf-8").splitlines(), 1):
                m = re.match(r"^([A-Za-z][\w-]*):", line)
                if m and not re.search(r"`" + re.escape(m.group(1)) + r"[`.\[]", text):
                    self.error("charts/firefox-sync/values.yaml", n, f"{m.group(1)} is not in docs/reference/settings.md")

    def check_external(self, fetch=None, workers=8):
        """--external: the http(s) links of docs/ and README.md that do not answer 2xx."""
        fetch = fetch or fetch_status
        where = {}
        for name in self.files("md"):
            if not (name.startswith("docs/") or name == "README.md"):
                continue
            for target, line in self.doc(self.root / name).links:
                if target.startswith(("http://", "https://")):
                    where.setdefault(target.split("#", 1)[0], []).append((name, line))
        with concurrent.futures.ThreadPoolExecutor(workers) as pool:
            for url, status in zip(where, pool.map(fetch, where)):
                if isinstance(status, int) and 200 <= status < 300:
                    continue
                for name, line in where[url]:
                    if status in (401, 403, 429):  # often a bot wall, not a dead page
                        print(f"{name}:{line}: warning: {url}: {status}, check it in a browser", file=sys.stderr)
                    else:
                        self.error(name, line, f"{url}: {status}")
        return len(where)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None  # followed by fetch_status, 308 too (urllib before 3.11 does not)


_OPENER = urllib.request.build_opener(_NoRedirect)


def fetch_status(url, timeout=20, hops=10):
    """The final status of url after redirects (HEAD, else GET), or the error as text."""
    status = None
    for method in ("HEAD", "GET"):
        current = url
        for _ in range(hops):
            req = urllib.request.Request(current, method=method, headers={
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0",
                "Accept": "text/html,*/*"})
            try:
                with _OPENER.open(req, timeout=timeout) as r:
                    return r.status
            except urllib.error.HTTPError as e:
                status = e.code
                if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location"):
                    current = urllib.parse.urljoin(current, e.headers["Location"])
                    continue
                break  # some servers refuse HEAD (403, 405): try GET
            except (urllib.error.URLError, OSError, ValueError) as e:
                status = f"{type(e).__name__}: {getattr(e, 'reason', e)}"
                break
    return status


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--code", action="store_true", help="also check the doc references of non-markdown files")
    p.add_argument("--settings", action="store_true", help="every setting appears in docs/reference/settings.md")
    p.add_argument("--external", action="store_true", help="also fetch the http(s) links of docs/ and README.md (network)")
    p.add_argument("--root", default=Path(__file__).resolve().parent.parent, help="the repository (default: this one)")
    args = p.parse_args(argv)
    c = Checker(args.root)
    c.check_docs()
    if args.code:
        c.check_code()
    if args.settings:
        c.check_settings()
    if args.external:
        print(f"{c.check_external()} external URLs checked", file=sys.stderr)
    for e in c.errors:
        print(e)
    print(f"{len(c.errors)} error(s) in {len(c.files('md'))} markdown files", file=sys.stderr)
    return 1 if c.errors else 0


if __name__ == "__main__":
    sys.exit(main())
