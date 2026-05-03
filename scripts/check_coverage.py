#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def numeric(value):
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.rstrip("%"))
        except ValueError:
            return None
    return None


def coverage_from_json(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    percent = numeric(data.get("percent_covered"))
    covered = numeric(data.get("covered_lines"))
    total = numeric(data.get("total_lines"))

    if percent is None and covered is not None and total and total > 0:
        percent = covered * 100.0 / total

    if percent is None:
        raise ValueError(f"{path} does not contain total coverage")

    return percent, int(total or 0), path


def main():
    if len(sys.argv) != 3:
        print("usage: check_coverage.py <coverage-dir> <minimum-percent>", file=sys.stderr)
        return 2

    root = Path(sys.argv[1])
    minimum = float(sys.argv[2])
    reports = []

    for path in root.rglob("coverage.json"):
        reports.append(coverage_from_json(path))

    if not reports:
        print(f"no coverage.json found under {root}", file=sys.stderr)
        return 1

    percent, _, path = max(reports, key=lambda item: item[1])
    print(f"coverage: {percent:.2f}% from {path}")
    if percent + 1e-9 < minimum:
        print(f"coverage below required {minimum:.2f}%", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
