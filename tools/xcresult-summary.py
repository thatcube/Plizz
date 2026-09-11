#!/usr/bin/env python3
"""Read authoritative XCTest results, including crashes hidden by restarts."""

import argparse
import json
from pathlib import Path
import re
import sys


def read_summary(path):
    summary = json.loads(Path(path).read_text())
    if not isinstance(summary, dict):
        raise ValueError("expected an xcresult summary object")
    if summary.get("result") not in {
        "Passed", "Failed", "Skipped", "Expected Failure", "unknown"
    }:
        raise ValueError("missing or invalid result")
    for field in (
        "totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"
    ):
        if type(summary.get(field)) is not int or summary[field] < 0:
            raise ValueError(f"missing or invalid {field}")
    if not isinstance(summary.get("testFailures"), list):
        raise ValueError("missing or invalid testFailures")
    for failure in summary["testFailures"]:
        target = failure.get("targetName") if isinstance(failure, dict) else None
        if not isinstance(target, str) or not re.fullmatch(r"[A-Za-z0-9_]+", target):
            raise ValueError("missing or invalid failure targetName")
    return summary


def passed(summary):
    return (
        summary["result"] == "Passed"
        and summary["failedTests"] == 0
        and summary["totalTestCount"] > 0
        and summary["passedTests"] + summary["expectedFailures"] > 0
    )


def failed_targets(summary):
    if summary["failedTests"] == 0:
        return []
    return sorted({failure["targetName"] for failure in summary["testFailures"]})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("verdict", "failed-targets"))
    parser.add_argument("summary", type=Path)
    args = parser.parse_args()
    try:
        summary = read_summary(args.summary)
    except (OSError, ValueError) as error:
        print(f"xcresult-summary: cannot verify test results: {error}", file=sys.stderr)
        return 1
    if args.operation == "failed-targets":
        for target in failed_targets(summary):
            print(target)
        return 0
    print(
        f'xcresult: {summary["result"]}; '
        f'{summary["passedTests"]}/{summary["totalTestCount"]} passed, '
        f'{summary["failedTests"]} failed, {summary["skippedTests"]} skipped, '
        f'{summary["expectedFailures"]} expected failures.'
    )
    return 0 if passed(summary) else 1


if __name__ == "__main__":
    sys.exit(main())
