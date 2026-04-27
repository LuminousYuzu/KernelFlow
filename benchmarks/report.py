#!/usr/bin/env python3
"""
Parse benchmark_result.txt produced by bench_all and upload to wandb.

Usage (from repo root after running bench_all):
    python benchmarks/report.py [--result benchmark_result.txt] [--project kernelflow]
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path


def parse_result(path: str) -> dict:
    result = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                try:
                    result[k] = float(v)
                except ValueError:
                    result[k] = v
    return result


def git_sha() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], text=True
        ).strip()
    except Exception:
        return "unknown"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result",  default="benchmark_result.txt")
    parser.add_argument("--project", default="kernelflow")
    args = parser.parse_args()

    result_path = Path(args.result)
    if not result_path.exists():
        print(f"[report.py] Result file not found: {result_path}", file=sys.stderr)
        sys.exit(1)

    data = parse_result(str(result_path))
    sha  = git_sha()

    print(f"[report.py] Benchmark results for commit {sha}:")
    for k, v in data.items():
        print(f"  {k} = {v}")

    try:
        import wandb  # type: ignore
    except ImportError:
        print("[report.py] wandb not installed — skipping upload (pip install wandb)")
        return

    wandb_key = os.environ.get("WANDB_API_KEY", "")
    if not wandb_key:
        print("[report.py] WANDB_API_KEY not set — skipping upload")
        return

    run = wandb.init(
        project=args.project,
        name=f"bench-{sha}",
        config={k: v for k, v in data.items() if isinstance(v, str)},
    )
    run.log({k: v for k, v in data.items() if isinstance(v, float)})
    run.finish()
    print(f"[report.py] Results uploaded to wandb project '{args.project}'")


if __name__ == "__main__":
    main()
