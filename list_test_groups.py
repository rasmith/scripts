#!/usr/bin/env python3
"""List all test groups in a test-amd.yaml file.

Usage:
    ./list_test_groups.py                          # uses default path
    ./list_test_groups.py path/to/test-amd.yaml
    ./list_test_groups.py --pool mi300             # filter by pool prefix
    ./list_test_groups.py --pool mi355 --count     # just show count
"""

import argparse
import yaml
from pathlib import Path

DEFAULT_YAML = Path.home() / ".cache/therock-nightly/vllm/.buildkite/test-amd.yaml"


def main():
    parser = argparse.ArgumentParser(description="List test groups in test-amd.yaml")
    parser.add_argument('yaml_file', nargs='?', default=str(DEFAULT_YAML),
                        help=f'Path to test-amd.yaml (default: {DEFAULT_YAML})')
    parser.add_argument('--pool', help='Filter by pool prefix (e.g. mi300, mi355)')
    parser.add_argument('--count', action='store_true', help='Just show count per pool')
    args = parser.parse_args()

    with open(args.yaml_file) as f:
        data = yaml.safe_load(f)

    steps = data.get('steps', [])

    if args.count:
        counts = {}
        for step in steps:
            pool = step.get('agent_pool', '?')
            prefix = pool.split('_')[0]
            counts[prefix] = counts.get(prefix, 0) + 1
        for prefix in sorted(counts):
            if args.pool and prefix != args.pool:
                continue
            print(f"  {prefix}: {counts[prefix]} groups")
        print(f"  total: {sum(counts.values())}")
        return

    for i, step in enumerate(steps):
        pool = step.get('agent_pool', '?')
        prefix = pool.split('_')[0]
        label = step.get('label', '?')
        if args.pool and prefix != args.pool:
            continue
        print(f"{i:3d}  {pool}: {label}")

    total = len(steps)
    if args.pool:
        filtered = sum(1 for s in steps if s.get('agent_pool', '').startswith(args.pool))
        print(f"\n{filtered} of {total} groups shown (--pool {args.pool})")
    else:
        print(f"\n{total} groups total")


if __name__ == '__main__':
    main()
