#!/usr/bin/env python3
"""Build grouped release notes from the pull requests merged since the last tag.

Used by the Releases workflow (.github/workflows/release.yml):

    release_notes.py --tag v2.3.0 --repo OWNER/REPO [--intro TEXT] > notes.md

It lists the merge commits between the previous tag and HEAD, looks each pull
request up with `gh`, and sorts it into a section. The section comes from, in
order:

  1. a label on the pull request (see LABELS),
  2. the first word of its title ("Fix ...", "Add ..."),
  3. a few words that mark developer-only work (emulator, harness, CI ...),
  4. otherwise "Other".

Labels are optional: most pull requests here have none, so the title is the
reliable source. A pull request labelled `skip-release-notes` is left out.
"""
import argparse
import json
import re
import subprocess
import sys

# (heading, key) in the order they are printed.
SECTIONS = [
    ("✨ New", "new"),
    ("🎨 Improved", "improved"),
    ("🐛 Fixes", "fixes"),
    ("🛠 For developers", "dev"),
    ("Other", "other"),
]

LABELS = {
    "enhancement": "new",
    "feature": "new",
    "bug": "fixes",
    "fix": "fixes",
    "ui": "improved",
    "ux": "improved",
    "design": "improved",
    "dev": "dev",
    "developer": "dev",
    "ci": "dev",
    "tests": "dev",
    "chore": "dev",
}
SKIP_LABEL = "skip-release-notes"

# First word of the title, lowercased.
FIRST_WORD = {
    "fix": "fixes", "fixes": "fixes", "fixed": "fixes", "repair": "fixes",
    "correct": "fixes", "stop": "fixes", "send": "fixes", "apply": "fixes",
    "add": "new", "adds": "new", "allow": "new", "link": "new", "guess": "new",
    "save": "new", "hardcover": "new", "install": "new", "support": "new",
    "bring": "improved", "make": "improved", "move": "improved",
    "replace": "improved", "show": "improved", "use": "improved",
    "change": "improved", "improve": "improved", "polish": "improved",
    "simplify": "improved", "rework": "improved", "book": "improved",
    "run": "dev", "lint": "dev", "tests": "dev", "test": "dev",
    "verify": "dev", "hold": "dev", "emulator": "dev", "refactor": "dev",
}
DEV_WORDS = re.compile(
    r"\b(emulator|harness(es)?|ci|lint|luacheck|ratchet|fixtures?|workflow|"
    r"spec|specs|live check|nightly|developer)\b", re.I)


def classify(title, labels):
    """Return the section key for a pull request."""
    lowered = {label.lower() for label in labels}
    if SKIP_LABEL in lowered:
        return None
    for label in labels:
        key = LABELS.get(label.lower())
        if key:
            return key
    if DEV_WORDS.search(title):
        return "dev"
    words = title.split()
    first = re.sub(r"\W", "", words[0]).lower() if words else ""
    return FIRST_WORD.get(first, "other")


def pr_numbers(log):
    """Pull request numbers from `git log --format=%s` lines, oldest first, no repeats."""
    seen = []
    for subject in reversed(log.splitlines()):
        m = re.match(r"Merge pull request #(\d+)", subject) or re.search(r"\(#(\d+)\)\s*$", subject)
        if m and int(m.group(1)) not in seen:
            seen.append(int(m.group(1)))
    return seen


def render(prs, intro="", compare_url=""):
    """prs: list of {"number", "title", "labels"}. Returns Markdown."""
    groups = {key: [] for _, key in SECTIONS}
    for pr in prs:
        key = classify(pr["title"], pr.get("labels", []))
        if key:
            groups[key].append(pr)
    out = []
    if intro.strip():
        out.append(intro.strip() + "\n")
    for heading, key in SECTIONS:
        if not groups[key]:
            continue
        out.append("## " + heading)
        for pr in groups[key]:
            out.append("- %s (#%d)" % (pr["title"].rstrip("."), pr["number"]))
        out.append("")
    if not any(groups.values()):
        out.append("No pull requests were merged since the last release.\n")
    if compare_url:
        out.append("**Full changelog**: " + compare_url)
    return "\n".join(out).rstrip() + "\n"


def sh(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()


def previous_tag(tag):
    """The tag to compare against. A stable release compares with the last stable
    one, so its notes cover every beta in between; a beta with the last tag of any
    kind, so a beta lists only what is new in it."""
    cmd = ["git", "describe", "--tags", "--abbrev=0"]
    if "beta" not in tag:
        cmd.append("--exclude=*beta*")
    # HEAD may already carry the new tag when the workflow is re-run: skip it.
    cmd += ["--exclude=" + tag, "HEAD"]
    try:
        return sh(*cmd)
    except subprocess.CalledProcessError:
        return ""


def fetch_pr(repo, number):
    data = json.loads(sh("gh", "pr", "view", str(number), "--repo", repo,
                         "--json", "number,title,labels"))
    return {"number": data["number"], "title": data["title"],
            "labels": [l["name"] for l in data.get("labels", [])]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--intro", default="")
    args = ap.parse_args()

    prev = previous_tag(args.tag)
    rng = prev + "..HEAD" if prev else "HEAD"
    numbers = pr_numbers(sh("git", "log", "--format=%s", rng))
    prs = [fetch_pr(args.repo, n) for n in numbers]
    compare = "https://github.com/%s/compare/%s...%s" % (args.repo, prev, args.tag) if prev else ""
    sys.stdout.write(render(prs, args.intro, compare))


if __name__ == "__main__":
    main()
