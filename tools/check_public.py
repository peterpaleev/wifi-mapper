#!/usr/bin/env python3
"""Check staged/tracked files for common accidental private artifacts; not a full secret audit."""
import pathlib, re, subprocess, sys
paths = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
patterns = [r"gh[pousr]_[A-Za-z0-9]{30,}", r"github_pat_[A-Za-z0-9_]{30,}", r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", r"AKIA[0-9A-Z]{16}", r"/Users/[A-Za-z0-9_-]+/", r"000081[0-9A-F]{2}-[0-9A-F]{16}"]
errors = []
for name in filter(None, paths):
    p = pathlib.Path(name)
    if any(part in {".tooling", ".build", "xcuserdata", "managed_components"} for part in p.parts) or name.startswith(("docs/local/", "docs/test-results/")) or p.suffix in {".sqlite", ".p12", ".mobileprovision", ".bin"} or p.name in {".env", "Local.xcconfig"}:
        errors.append((name, "private/generated path"))
    data = subprocess.check_output(["git", "show", ":" + name])
    if len(data) > 2_000_000:
        errors.append((name, "unexpected file over 2 MB"))
    text = data.decode("utf-8", errors="replace")
    if name != "tools/check_public.py" and any(re.search(pattern, text) for pattern in patterns):
        errors.append((name, "possible credential or machine identifier"))
for name, reason in errors:
    print(f"FAIL {name}: {reason}")
print(f"Checked {len(list(filter(None, paths)))} indexed files; {len(errors)} findings.")
sys.exit(bool(errors))
