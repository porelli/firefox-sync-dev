#!/usr/bin/env python3
"""The upstream pull requests of upstream-patches.yml, for one image build.

Usage:
  upstream-patches.py plan  <component> <release-tag>
  upstream-patches.py apply <component> <release-tag> <source-checkout-dir>

component: fxa-mono or syncstorage-rs; release-tag: the upstream tag being built.

For each entry of the component, the pull request as GitHub has it now (gh api), checked
against the entry first: its head repository must be head_repo, the pinned sha must be in
its history (compare sha...head: identical or ahead) and base an ancestor of sha; else
error, exit 1. Then:
  - merged and in the release (compare merge_commit_sha...tag: identical or ahead):
    obsolete, not applied; with apply its changes must be in the sources (they apply in
    reverse), else error
  - closed without being merged: error, exit 1
  - open, or merged after the release: applied as of the pinned sha (apply), the diff
    base...sha (both pinned: the reviewed changes whatever happens to the pull request);
    a ::notice:: when its head is past sha. With apply, a patch already in the sources
    (it applies in reverse) is obsolete too; one that does not apply is an error, exit 1
plan decides only (for the reuse of images and the rebuilds), apply also patches the
checkout (git apply; a depth-1 checkout has no blobs for a 3-way merge).

Outputs (GITHUB_OUTPUT, and printed): applied (space-separated owner/repo#pr@base7..sha7),
label (applied, or "none"), key (12 hex of label's sha256, for cache keys), obsolete
(the same form), obsolete_json ([{"id", "pr", "when_released"}]). A summary for
GITHUB_STEP_SUMMARY. Environment: UPSTREAM_PATCHES_FILE (default: upstream-patches.yml at
the root of this repository), GH_TOKEN for gh.

Python 3 standard library and gh only. Tests: tests/test_upstream_patches.py.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

COMPONENTS = ("fxa-mono", "syncstorage-rs")
FIELDS = ("id", "repo", "pr", "head_repo", "base", "sha", "component", "why", "when_released")
LABEL = "org.firefox-sync.upstream-patches"


class Fail(Exception):
    """An entry that needs a decision: the build must fail."""


# --- upstream-patches.yml: a list of flat mappings of plain or folded (>-) scalars ---

def _scalar(text, where):
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    if text[:1] in ("[", "{", "&", "*", "!", "|"):
        raise ValueError(f"{where}: only plain or quoted scalars and >- blocks: {text}")
    return re.sub(r"\s+#.*$", "", text)


def parse(text):
    entries = []
    lines = text.splitlines()
    i = 0
    current = None
    while i < len(lines):
        line = lines[i]
        where = f"line {i + 1}"
        i += 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("- "):
            current = {}
            entries.append(current)
            line = "  " + line[2:]
        elif current is None or not line.startswith("  ") or line.startswith("   "):
            raise ValueError(f"{where}: expected '- key: value' or '  key: value': {line}")
        m = re.match(r"^  ([a-z_]+):(?: (.*))?$", line)
        if not m:
            raise ValueError(f"{where}: expected 'key: value': {line}")
        key, value = m.group(1), (m.group(2) or "").strip()
        if key in current:
            raise ValueError(f"{where}: {key} twice")
        if value in (">", ">-"):
            block = []
            while i < len(lines) and (lines[i].startswith("    ") or not lines[i].strip()):
                block.append(lines[i].strip())
                i += 1
            value = " ".join(b for b in block if b)
        else:
            value = _scalar(value, where)
        current[key] = value
    for n, e in enumerate(entries, 1):
        missing = [f for f in FIELDS if not e.get(f)]
        if missing:
            raise ValueError(f"entry {n} ({e.get('id', '?')}): missing {', '.join(missing)}")
        unknown = sorted(set(e) - set(FIELDS))
        if unknown:
            raise ValueError(f"entry {n} ({e['id']}): unknown {', '.join(unknown)}")
        if e["component"] not in COMPONENTS:
            raise ValueError(f"entry {n} ({e['id']}): component {e['component']}, not one of {', '.join(COMPONENTS)}")
        for field in ("sha", "base"):
            if not re.fullmatch(r"[0-9a-f]{40}", e[field]):
                raise ValueError(f"entry {n} ({e['id']}): {field} must be a full commit sha")
        for field in ("repo", "head_repo"):
            if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", e[field]):
                raise ValueError(f"entry {n} ({e['id']}): {field} must be owner/name")
        if not e["pr"].isdigit():
            raise ValueError(f"entry {n} ({e['id']}): pr must be a number")
        e["pr"] = int(e["pr"])
    ids = [e["id"] for e in entries]
    if len(ids) != len(set(ids)):
        raise ValueError("ids must be unique")
    return entries


def ref(entry):
    # base too: a correction of base alone changes what is applied, the label and the keys
    return f"{entry['repo']}#{entry['pr']}@{entry['base'][:7]}..{entry['sha'][:7]}"


# --- GitHub, through gh (replaced by a fake in the tests) ---

class GitHub:
    def _api(self, path, accept=None):
        cmd = ["gh", "api"]
        if accept:
            cmd += ["-H", f"Accept: {accept}"]
        result = subprocess.run(cmd + [path], capture_output=True, text=True)
        if result.returncode != 0:
            raise Fail(f"gh api {path}: {result.stderr.strip() or result.stdout.strip()}")
        return result.stdout

    def pull(self, repo, number):
        return json.loads(self._api(f"repos/{repo}/pulls/{number}"))

    def contains(self, repo, commit, ref):
        """Whether ref has commit in its history: compare commit...ref is identical or ahead."""
        status = json.loads(self._api(f"repos/{repo}/compare/{commit}...{ref}"))["status"]
        return status in ("identical", "ahead")

    def diff(self, repo, base, sha):
        """The changes of sha since its merge base with base (compare base...sha)."""
        return self._api(f"repos/{repo}/compare/{base}...{sha}", accept="application/vnd.github.diff")


# --- the decisions ---

def check_pin(entry, pull, gh):
    """The pull request is the one reviewed: its head repository, sha in its history, base
    an ancestor of sha. Returns the notices."""
    name = f"{ref(entry)} ({entry['id']})"
    head_repo = (pull["head"].get("repo") or {}).get("full_name")
    if head_repo is None and not pull.get("merged"):
        raise Fail(f"{name}: the pull request's head repository is gone: decide (remove the entry or pin another pull request)")
    if head_repo is not None and head_repo != entry["head_repo"]:
        raise Fail(f"{name}: the pull request's head is {head_repo}, upstream-patches.yml says {entry['head_repo']}")
    head = pull["head"]["sha"]
    notices = []
    if head != entry["sha"]:
        if not gh.contains(entry["repo"], entry["sha"], head):
            raise Fail(f"{name}: sha {entry['sha'][:7]} is not in the history of the pull request (head {head[:7]}): "
                       f"pin a commit of the pull request")
        notices.append(f"{name}: the pull request is at {head[:7]} now, still applying the reviewed "
                       f"{entry['sha'][:7]}: review the new commits and move sha in upstream-patches.yml")
    if not gh.contains(entry["repo"], entry["base"], entry["sha"]):
        raise Fail(f"{name}: base {entry['base'][:7]} is not an ancestor of sha {entry['sha'][:7]}")
    return notices


def decide(entry, pull, gh, tag):
    """apply or obsolete for one entry, and its notices; Fail for a decision to take."""
    notices = check_pin(entry, pull, gh)
    if pull.get("merged"):
        merge = pull.get("merge_commit_sha")
        if merge and gh.contains(entry["repo"], merge, tag):
            return "obsolete", f"merged ({merge[:7]}) and in {tag}", notices
        return "apply", f"merged ({(merge or '?')[:7]}), not in {tag} yet", notices
    if pull["state"] == "closed":
        raise Fail(f"{ref(entry)} ({entry['id']}) was closed without being merged: "
                   f"remove the entry (and its workaround, see when_released) or replace it")
    return "apply", "open", notices


def git(checkout, *args, stdin=None):
    return subprocess.run(["git", "-C", checkout, *args], input=stdin, capture_output=True, text=True)


def apply_patch(entry, pull, gh, checkout, released=False):
    """Applies the pinned changes; returns "applied" or "present" (already in the sources).
    released: the release has the pull request, its changes must be there."""
    name = f"{ref(entry)} ({entry['id']})"
    diff = gh.diff(entry["repo"], entry["base"], entry["sha"])
    if not diff.strip():
        raise Fail(f"{name}: no changes between {entry['base'][:7]} and {entry['sha'][:7]}")
    files = len(re.findall(r"^diff --git ", diff, re.M))
    if entry["sha"] == pull["head"]["sha"] and pull.get("changed_files") not in (None, files):
        raise Fail(f"{name}: {files} files changed since base {entry['base'][:7]}, the pull request "
                   f"changes {pull['changed_files']}: retargeted or rebased? Review it and pin base and sha again")
    with tempfile.NamedTemporaryFile("w", suffix=".diff", delete=False) as f:
        f.write(diff)
        path = f.name
    try:
        present = git(checkout, "apply", "--reverse", "--check", path).returncode == 0
        if released:
            if present:
                return "present"
            raise Fail(f"{name} is merged and in the release, but its changes are not in the sources "
                       f"(changed again since?): remove the entry and do what its when_released says")
        result = git(checkout, "apply", "--check", path)
        if result.returncode == 0:
            result = git(checkout, "apply", path)
            if result.returncode == 0:
                return "applied"
        elif present:
            return "present"
        raise Fail(f"{name} does not apply to the release: {(result.stderr or result.stdout).strip()}\n"
                   f"rebase the pull request and pin its new head (and base), or remove the entry")
    finally:
        os.unlink(path)


def run(entries, component, tag, gh, checkout=None, log=print):
    """The decisions for the entries of component, applied to checkout when given."""
    result = {"applied": [], "obsolete": [], "notices": [], "rows": []}
    chosen = [e for e in entries if e["component"] == component]
    decisions = []
    errors = []
    for entry in chosen:
        pull = gh.pull(entry["repo"], entry["pr"])
        try:
            action, state, notices = decide(entry, pull, gh, tag)
        except Fail as e:
            errors.append(str(e))
            continue
        result["notices"] += notices
        decisions.append((entry, pull, action, state))
    if errors:
        raise Fail("\n".join(errors))
    for entry, pull, action, state in decisions:
        if checkout:
            if apply_patch(entry, pull, gh, checkout, released=(action == "obsolete")) == "present" and action == "apply":
                action, state = "obsolete", f"{state}, its changes already in {tag}"
        if action == "apply":
            result["applied"].append(entry)
        else:
            result["obsolete"].append(entry)
        result["rows"].append((entry, state, action if checkout or action == "obsolete" else "to apply"))
        log(f"{ref(entry)} ({entry['id']}): {state}: {action if checkout or action == 'obsolete' else 'to apply'}")
    return result


def outputs(result):
    applied = " ".join(ref(e) for e in result["applied"])
    label = applied or "none"
    return {
        "applied": applied,
        "label": label,
        "key": hashlib.sha256(label.encode()).hexdigest()[:12],
        "obsolete": " ".join(ref(e) for e in result["obsolete"]),
        "obsolete_json": json.dumps([{"id": e["id"], "pr": ref(e), "when_released": e["when_released"]}
                                     for e in result["obsolete"]], separators=(",", ":")),
    }


def summary(result, component, tag):
    lines = [f"### Upstream patches, {component} {tag}", ""]
    if not result["rows"]:
        return "\n".join(lines + ["None in upstream-patches.yml.", ""])
    lines += ["| Pull request | | State | Image |", "| --- | --- | --- | --- |"]
    for entry, state, action in result["rows"]:
        url = f"https://github.com/{entry['repo']}/pull/{entry['pr']}"
        lines.append(f"| [{ref(entry)}]({url}) | {entry['id']} | {state} | {action} |")
    lines.append("")
    lines.append(f"Label {LABEL}: `{outputs(result)['label']}`")
    for n in result["notices"]:
        lines.append(f"- {n}")
    return "\n".join(lines + [""])


def main(argv):
    if len(argv) < 3 or argv[0] not in ("plan", "apply") or (argv[0] == "apply") != (len(argv) == 4) or len(argv) > 4:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    mode, component, tag = argv[:3]
    checkout = argv[3] if mode == "apply" else None
    if component not in COMPONENTS:
        print(f"component: one of {', '.join(COMPONENTS)}", file=sys.stderr)
        return 2
    path = os.environ.get("UPSTREAM_PATCHES_FILE") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "upstream-patches.yml")
    try:
        with open(path) as f:
            entries = parse(f.read())
        result = run(entries, component, tag, GitHub(), checkout)
    except (Fail, ValueError) as e:
        for line in str(e).splitlines():
            print(f"::error title=upstream-patches.yml::{line}")
        return 1
    for n in result["notices"]:
        print(f"::notice title=upstream-patches.yml::{n}")
    out = outputs(result)
    for k, v in out.items():
        print(f"{k}={v}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.writelines(f"{k}={v}\n" for k, v in out.items())
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(summary(result, component, tag))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
