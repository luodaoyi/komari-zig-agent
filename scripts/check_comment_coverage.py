#!/usr/bin/env python3
import sys
from pathlib import Path


def has_doc_comment(path: Path) -> bool:
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.lstrip()
        if stripped.startswith("//!") or stripped.startswith("///"):
            return True
    return False


def iter_source_files(root: Path):
    for path in sorted(root.rglob("*.zig")):
        if path.name.endswith("_test.zig"):
            continue
        yield path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: check_comment_coverage.py <source-dir> <minimum-percent>", file=sys.stderr)
        return 2

    root = Path(sys.argv[1])
    minimum = float(sys.argv[2])
    files = list(iter_source_files(root))
    if not files:
        print(f"no source files found under {root}", file=sys.stderr)
        return 1

    covered = [path for path in files if has_doc_comment(path)]
    percent = len(covered) * 100.0 / len(files)
    print(f"comment coverage: {percent:.2f}% ({len(covered)}/{len(files)})")

    if percent + 1e-9 < minimum:
        missing = [str(path) for path in files if path not in covered]
        print("missing doc comments:", file=sys.stderr)
        for path in missing:
            print(path, file=sys.stderr)
        print(f"comment coverage below required {minimum:.2f}%", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
