#!/usr/bin/env python3
"""Find the real upstream version for manifest entries whose URL 404s.

The manifest was written from knowledge of what these projects release, so a
chunk of the versions are wrong. check-sources.sh finds them; this resolves them
by asking upstream what actually exists, then rewrites manifest.tsv.

    ./fix-versions.py            # resolve everything in logs/sources/bad
    ./fix-versions.py --dry-run  # show what it would change
    ./fix-versions.py pkg ...    # only these packages

Two strategies, picked from the URL shape:

  github.com/OWNER/REPO/...   ask the tags API and take the newest tag whose
                              shape matches the version we had
  anything else               fetch the containing directory and look for the
                              same filename with a different version in it

Anything it cannot resolve is left alone and reported, because a wrong guess is
worse than a known-bad entry.
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
TREE = os.path.dirname(HERE)
MANIFEST = os.path.join(TREE, "ports", "manifest.tsv")
BAD = "/home/apiwo/scraplinux-build/logs/sources/bad"

VER_RE = re.compile(r"\d[\d.]*\d|\d")


def curl(url, timeout=25):
    try:
        out = subprocess.run(
            ["curl", "-sL", "--max-time", str(timeout), url],
            capture_output=True, timeout=timeout + 5)
        return out.stdout.decode("utf-8", "replace")
    except Exception:
        return ""


def version_key(v):
    """Sort key that treats 1.10 as newer than 1.9."""
    parts = re.split(r"[.\-_]", v)
    key = []
    for p in parts:
        key.append((0, int(p)) if p.isdigit() else (1, 0))
    return key


def same_shape(a, b):
    """Both look like versions of the same scheme (same number of dot groups)."""
    return len(a.split(".")) == len(b.split("."))


def resolve_github(url, old):
    m = re.search(r"github\.com/([^/]+)/([^/]+)", url)
    if not m:
        return None
    owner, repo = m.group(1), m.group(2).removesuffix(".git")
    body = curl(f"https://api.github.com/repos/{owner}/{repo}/tags?per_page=100")
    try:
        tags = json.loads(body)
    except Exception:
        return None
    if not isinstance(tags, list):
        return None

    cands = []
    for t in tags:
        name = t.get("name", "")
        raw = name.lstrip("vV")
        # Skip pre-releases; we want something people actually run.
        if re.search(r"(rc|alpha|beta|pre|dev)", raw, re.I):
            continue
        m2 = VER_RE.fullmatch(raw)
        if not m2:
            continue
        cands.append(raw)
    if not cands:
        return None
    shaped = [c for c in cands if same_shape(c, old)] or cands
    return max(shaped, key=version_key)


def resolve_listing(url, old):
    """Fetch the containing directory and look for the same file, new version."""
    base = url.rsplit("/", 1)
    if len(base) != 2:
        return None
    directory, fname = base
    body = curl(directory + "/")
    if not body:
        return None
    # Turn the filename into a pattern with the version as a wildcard.
    if old not in fname:
        return None
    pat = re.escape(fname).replace(re.escape(old), r"([\d][\d.]*[\d])")
    found = set(re.findall(pat, body))
    found = {f for f in found if not re.search(r"(rc|alpha|beta)", f, re.I)}
    if not found:
        return None
    shaped = [c for c in found if same_shape(c, old)] or list(found)
    return max(shaped, key=version_key)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    dry = "--dry-run" in sys.argv

    if not os.path.exists(BAD):
        sys.exit(f"no report at {BAD} - run check-sources.sh first")

    todo = []
    for line in open(BAD):
        f = line.rstrip("\n").split("\t")
        if len(f) < 5:
            continue
        repo, name, ver, code, url = f[0], f[1], f[2], f[3], f[4]
        if args and name not in args:
            continue
        todo.append((repo, name, ver, url))

    print(f"resolving {len(todo)} package(s)\n")
    fixes, failed = {}, []
    for repo, name, ver, url in todo:
        new = resolve_github(url, ver) if "github.com" in url else resolve_listing(url, ver)

        # Guard against silent downgrades. A truncated directory listing or a
        # tags page that does not include the newest release will happily hand
        # back something years old - chromium resolved to 101 and blender to
        # 2.82 that way. Dropping a major version is treated as unresolved.
        if new and new != ver:
            try:
                if int(new.split(".")[0]) < int(ver.split(".")[0]):
                    print(f"  {name:<24} {ver:>16}  -- refusing downgrade to {new}")
                    failed.append(name)
                    continue
            except (ValueError, IndexError):
                pass

        if new and new != ver:
            fixes[name] = (ver, new)
            print(f"  {name:<24} {ver:>16}  ->  {new}")
        else:
            failed.append(name)

    print(f"\nresolved {len(fixes)}, still unknown {len(failed)}")
    if failed:
        print("  unresolved: " + " ".join(sorted(failed)[:24]))

    if dry or not fixes:
        return

    lines = open(MANIFEST).read().split("\n")
    out = []
    for l in lines:
        if l.startswith("#") or not l.strip():
            out.append(l); continue
        f = l.split("\t")
        if len(f) == 10 and f[1] in fixes:
            old, new = fixes[f[1]]
            if f[2] == old:
                f[2] = new
                l = "\t".join(f)
        out.append(l)
    open(MANIFEST, "w").write("\n".join(out))
    print(f"\nmanifest.tsv updated with {len(fixes)} version fix(es)")
    print("run gen-ports.py, then check-sources.sh again to confirm")


if __name__ == "__main__":
    main()
