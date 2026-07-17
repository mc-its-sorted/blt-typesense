#!/usr/bin/env python3
"""Remove volumeMounts/volumes from a Cloud Run service export YAML."""
import re
import sys
from pathlib import Path


def strip_sections(text: str) -> str:
    lines = text.splitlines(keepends=True)
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r"^(\s*)volumeMounts:\s*$", line) or re.match(
            r"^(\s*)volumes:\s*$", line
        ):
            indent = len(re.match(r"^(\s*)", line).group(1))
            i += 1
            while i < len(lines):
                m = re.match(r"^(\s*)(\S)", lines[i])
                if not m:
                    i += 1
                    continue
                if len(m.group(1)) <= indent:
                    break
                i += 1
            continue
        out.append(line)
        i += 1
    return "".join(out)


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/service.yaml")
    original = path.read_text()
    stripped = strip_sections(original)
    path.write_text(stripped)
    removed = original != stripped
    print(f"strip_volumes: {'removed volumes' if removed else 'no volumes found'} ({path})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
