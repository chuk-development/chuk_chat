#!/usr/bin/env python3
"""Generate changelog-only release notes for a tag from the git history.

The notes list the commits between the previous release tag and the given tag,
grouped by conventional-commit type. Merge commits are left out on purpose:
"Merge remote-tracking branch 'origin/master'" tells a reader nothing, and the
work it merges is already in the list. The notes contain no download or
install instructions — the GitHub asset list already shows the files.

Usage:
    scripts/release_notes.py v1.0.110              # previous tag detected
    scripts/release_notes.py v1.0.110 --from v1.0.109
    scripts/release_notes.py v1.0.110 --repo chuk-development/chuk_chat
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys

DEFAULT_REPO = "chuk-development/chuk_chat"

# Conventional-commit type -> section heading, in output order.
SECTIONS: list[tuple[str, tuple[str, ...]]] = [
    ("New Features", ("feat",)),
    ("Bug Fixes", ("fix",)),
    ("Performance", ("perf",)),
    ("Refactors", ("refactor",)),
    ("Documentation", ("docs",)),
    ("Tests", ("test",)),
    ("Dependencies", ("deps", "dep")),
    ("Build & CI", ("build", "ci")),
    ("Maintenance", ("chore",)),
    ("Other", ()),
]

COMMIT_RE = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?"
    r"(?P<breaking>!)?:\s*(?P<subject>.+)$"
)
MERGE_RE = re.compile(r"^Merge (branch|remote-tracking branch|pull request)\b")


def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def tag_exists(tag: str) -> bool:
    return subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"],
                          capture_output=True).returncode == 0


def version_key(tag: str) -> tuple[int, int, int, int, int, str]:
    """Sort key for `v1.2.3` and `v1.2.3-pre.4` tags.

    The pre-release number is compared as an integer, so `-pre.10` sorts after
    `-pre.9` instead of before it.
    """
    # Only the two shapes the release workflow can produce count as version
    # tags. Anything else — an old experiment, someone's `-rc.1` — must not be
    # picked as a predecessor, or the changelog starts at the wrong commit.
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-pre\.(\d+))?", tag)
    if not match:
        # -1 major marks "not a version tag", so a real v0.x.y tag still sorts
        # as a version and finds its predecessor.
        return (-1, 0, 0, 0, 0, "")
    major, minor, patch, pre_number = match.groups()
    # A release sorts after all of its own pre-releases.
    if pre_number is None:
        return (int(major), int(minor), int(patch), 1, 0, "")
    return (int(major), int(minor), int(patch), 0, int(pre_number), "")


def previous_tag(tag: str) -> str | None:
    """The release tag the changelog starts from.

    A stable release compares against the previous stable release, so the notes
    cover every commit of the version. A pre-release compares against whatever
    tag came directly before it, so consecutive `-pre.N` notes do not repeat.
    """
    tags = [t for t in run("git", "tag", "-l", "v*").splitlines()
            if version_key(t)[0] >= 0]
    earlier = [t for t in tags if version_key(t) < version_key(tag)]
    if "-" not in tag:
        earlier = [t for t in earlier if "-" not in t]
    if not earlier:
        return None
    return max(earlier, key=version_key)


def commit_of(tag: str) -> str:
    """The short commit a tag points at, or "" when it cannot be resolved."""
    result = subprocess.run(
        ["git", "rev-parse", "--short", f"{tag}^{{commit}}"],
        capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def collect(rev_range: str) -> list[tuple[str, str]]:
    """Every non-merge commit in the range, oldest first."""
    log = run("git", "log", "--no-merges", "--reverse", "--format=%H%x1f%s", rev_range)
    commits: list[tuple[str, str]] = []
    for line in log.splitlines():
        if not line:
            continue
        sha, subject = line.split("\x1f", 1)
        if MERGE_RE.match(subject):
            continue
        commits.append((sha, subject))
    return commits


def section_for(subject: str) -> tuple[str, str]:
    """Return (section title, cleaned subject) for one commit subject."""
    match = COMMIT_RE.match(subject)
    if not match:
        return "Other", subject
    ctype = match.group("type")
    scope = match.group("scope")
    text = match.group("subject").strip()
    # `feat!:` and `feat(scope)!:` mark a breaking change. A reader must see
    # that before the subject, not have it swallowed by the parser.
    prefix = "**Breaking:** " if match.group("breaking") else ""
    # `build(deps): bump x` is a dependency bump, whatever its type says.
    if scope and (scope == "deps" or scope.startswith("deps-")):
        return "Dependencies", prefix + text
    for title, types in SECTIONS:
        if ctype in types:
            body = f"**{scope}:** {text}" if scope else text
            return title, prefix + body
    return "Other", prefix + subject


def render(tag: str, prev: str | None, repo: str) -> str:
    rev_range = f"{prev}..{tag}" if prev else tag
    commits = collect(rev_range)

    grouped: dict[str, list[str]] = {}
    for sha, subject in commits:
        title, text = section_for(subject)
        link = f"[`{sha[:7]}`](https://github.com/{repo}/commit/{sha})"
        grouped.setdefault(title, []).append(f"- {text} {link}")

    out: list[str] = ["## What's New", ""]
    if commits:
        for title, _ in SECTIONS:
            if title in grouped:
                out.append(f"### {title}")
                out.extend(grouped[title])
                out.append("")
    else:
        # Two tags can point at the same commit — a re-cut pre-release, for
        # example. The release still gets a body and the compare link.
        out.append(f"No code changes since `{prev}`." if prev else "No commits.")
        out.append("")

    if prev:
        out.append(
            f"**Full changelog:** [`{prev}...{tag}`]"
            f"(https://github.com/{repo}/compare/{prev}...{tag})"
        )
        # The tags can move; the commit range cannot. Both belong in the body.
        prev_sha = commit_of(prev)
        tag_sha = commit_of(tag)
        if prev_sha and tag_sha:
            out.append("")
            out.append(f"Commit range: `{prev_sha}..{tag_sha}`")
    return "\n".join(out).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="release tag to write notes for, e.g. v1.0.110")
    parser.add_argument("--from", dest="from_tag", help="previous tag (default: detected)")
    parser.add_argument("--repo", default=DEFAULT_REPO, help="owner/name for commit links")
    args = parser.parse_args()

    if not tag_exists(args.tag):
        print(f"error: tag {args.tag} does not exist locally", file=sys.stderr)
        return 1
    prev = args.from_tag or previous_tag(args.tag)
    if prev and not tag_exists(prev):
        print(f"error: tag {prev} does not exist locally", file=sys.stderr)
        return 1

    sys.stdout.write(render(args.tag, prev, args.repo))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
