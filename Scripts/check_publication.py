#!/usr/bin/env python3
"""Check the exact Git publication set without printing any matched secret values."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent

def git(*args):
    return subprocess.check_output(["git", "-C", str(root), *args])

tracked = set(git("ls-files", "-z").decode().split("\0")) - {""}
untracked = set(git("ls-files", "--others", "--exclude-standard", "-z").decode().split("\0")) - {""}
paths = sorted(tracked | untracked)
blocked_suffixes = (".dmg", ".zip", ".sqlite", ".sqlite3", ".db", ".p12", ".pfx", ".pem", ".key", ".log", ".ktrace", ".ips", ".crash")
blocked_parts = {".build", "dist", "Payloads", "Thumbnails", "AppBackups", "xcuserdata", ".codex", ".agents"}
patterns = [
    ("GitHub token", re.compile(r"(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}")),
    ("AWS access key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("private key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("literal credential", re.compile(r'''(?i)(?:api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*["']([A-Za-z0-9_+/=-]{24,})["']''')),
]
failures = []
for name in paths:
    relative = Path(name)
    if relative.suffix.lower() in blocked_suffixes or blocked_parts.intersection(relative.parts) or any(part.endswith((".app", ".dSYM", ".trace", ".xcresult")) for part in relative.parts) or relative.name.startswith(".env") and relative.name != ".env.example":
        failures.append(f"Forbidden publication path: {name}")
        continue
    path = root / name
    if path.is_symlink():
        failures.append(f"Review symlink before publication: {name}")
        continue
    if not path.is_file():
        continue
    data = path.read_bytes()
    if len(data) > 5 * 1024 * 1024:
        failures.append(f"Oversized source file: {name}")
    if path.suffix.lower() in {".png", ".icns"}:
        # Asset bytes are checked for accidental embedded local paths; no clipboard screenshots are approved.
        if name not in {"Resources/AppIcon.png", "Resources/AppIcon.icns"}:
            failures.append(f"Unreviewed binary image: {name}")
        if str(Path.home()).encode() in data:
            failures.append(f"Local home path in asset metadata: {name}")
        continue
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        failures.append(f"Unreviewed binary: {name}")
        continue
    for label, pattern in patterns:
        if pattern.search(text):
            failures.append(f"Possible {label}: {name} (value redacted)")
    if str(Path.home()) + "/" in text or re.search(r"/(?:Users|home)/[A-Za-z0-9._-]+/", text):
        failures.append(f"Machine-specific home path: {name}")
    if "https://github.com/" + "OWNER/" in text:
        failures.append(f"Unresolved repository placeholder: {name}")

# Inspect every reachable source blob, including files removed in older commits.
# CI checks out complete history so this also covers previously published tags.
seen = set()
commits = git("rev-list", "--all").decode().split()
for commit in commits:
    for entry in git("ls-tree", "-rz", commit).split(b"\0"):
        if not entry:
            continue
        metadata, raw_name = entry.split(b"\t", 1)
        mode, kind, oid = metadata.split()
        if kind != b"blob" or oid in seen:
            continue
        seen.add(oid)
        name = raw_name.decode("utf-8", errors="replace")
        data = git("cat-file", "blob", oid.decode())
        if mode == b"120000":
            failures.append(f"Historical symlink requires review: {name}")
        try:
            content = data.decode("utf-8")
        except UnicodeDecodeError:
            continue  # Image metadata is reviewed separately; compressed bytes are not text.
        for label, pattern in patterns:
            if pattern.search(content):
                failures.append(f"Historical {label}: {name} (value redacted)")
        if re.search(r"/(?:Users|home)/[A-Za-z0-9._-]+/", content):
            failures.append(f"Historical home path: {name}")
        for address in re.findall(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", content):
            if not address.endswith("@users.noreply.github.com") and not address.endswith("@example.com"):
                failures.append(f"Personal email requires review: {name} (value redacted)")
for identity in git("log", "--all", "--format=%ae%n%ce").decode().splitlines():
    if not identity.endswith("@users.noreply.github.com"):
        failures.append("Commit uses a non-noreply email (value redacted)")

# Ensure risky generated/local files really stay outside the publication set.
ignored_examples = [
    "dist/SwiftClip1.0.4.dmg", ".build/output", ".env", "test.sqlite", "test.sqlite-wal",
    "Payloads/private.json", "Thumbnails/private.png", "signing.p12",
    "Docs/CLEANUP.md", "Docs/BUILD_REPORT.md", "Docs/BUILD_REPORT_1.0.4.md",
    "SwiftClip.xcodeproj/xcuserdata/local.xcuserstate", ".DS_Store",
]
for name in ignored_examples:
    if subprocess.run(["git", "-C", str(root), "check-ignore", "-q", "--no-index", name]).returncode != 0:
        failures.append(f"Missing ignore protection: {name}")
if failures:
    print("\n".join(failures), file=sys.stderr)
    sys.exit(1)
print(f"Publication audit passed: {len(paths)} source files; generated/private path checks and high-confidence credential patterns passed; {len(commits)} commits / {len(seen)} historical blobs checked.")
