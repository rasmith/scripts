#!/usr/bin/env python3
"""Filter test-amd.yaml to only contain selected test groups.

Preserves original YAML formatting (comments, quoting, indentation, section
headers) so the Jinja template (test-template-amd.j2) continues to work.
Never uses yaml.dump().

Usage:
    # Interactive — prints all groups, lets you pick by number:
    ./filter_test_groups.py ~/.cache/therock-nightly/vllm/.buildkite/test-amd.yaml

    # Specify groups on the command line (pool:label):
    ./filter_test_groups.py test-amd.yaml \\
        "mi300_1:Basic Models Tests (Other)" \\
        "mi355_1:V1 Core + KV + Metrics"

    # Dry run — show what would be kept without writing:
    ./filter_test_groups.py test-amd.yaml \\
        "mi300_1:LM Eval Small Models" --dry-run

    # Filter by label only (keeps all pools with that label):
    ./filter_test_groups.py test-amd.yaml --by-label \\
        "V1 Core + KV + Metrics" \\
        "LM Eval Small Models"
"""

import argparse
import sys
import yaml
from pathlib import Path


def parse_steps(yaml_path):
    """Parse the YAML and find line ranges for each step.

    Returns (lines, steps_line, steps, step_blocks) where each step_block is
    a tuple (comment_start, step_start, end):
      - comment_start..step_start-1 = leading comments/blanks for this step
      - step_start..end-1 = the step's actual YAML content
    """
    text = yaml_path.read_text()
    lines = text.split('\n')

    with open(yaml_path) as f:
        data = yaml.safe_load(f)

    steps = data.get('steps', [])

    # Find the "steps:" line
    steps_line = None
    for i, line in enumerate(lines):
        if line.strip() == 'steps:':
            steps_line = i
            break

    if steps_line is None:
        print("ERROR: Could not find 'steps:' line", file=sys.stderr)
        sys.exit(1)

    # Find start of each step (lines starting with "- label:")
    step_starts = []
    for i in range(steps_line + 1, len(lines)):
        stripped = lines[i].strip()
        if stripped.startswith('- label:'):
            step_starts.append(i)

    # Build blocks: for each step, find leading comments/blanks that belong to it.
    # Comments and blank lines before a "- label:" line are section headers for
    # that step, not trailing content of the previous step.
    step_blocks = []
    for idx, start in enumerate(step_starts):
        end = step_starts[idx + 1] if idx + 1 < len(step_starts) else len(lines)

        # Walk backward from start to find where leading comments begin.
        # Leading comments = contiguous block of comment lines (#...) and blank
        # lines immediately above the "- label:" line, stopping at the previous
        # step's content or the steps_line.
        boundary = step_starts[idx - 1] if idx > 0 else steps_line + 1
        comment_start = start
        for j in range(start - 1, boundary - 1, -1):
            stripped = lines[j].strip()
            if stripped == '' or stripped.startswith('#'):
                comment_start = j
            else:
                break

        step_blocks.append((comment_start, start, end))

    if len(step_blocks) != len(steps):
        print(f"WARNING: found {len(step_blocks)} line ranges but {len(steps)} parsed steps",
              file=sys.stderr)

    return lines, steps_line, steps, step_blocks


def format_group(step):
    pool = step.get('agent_pool', '?')
    label = step.get('label', '?')
    return pool, label


def interactive_select(steps):
    """Show all groups and let user pick by number."""
    print(f"\nFound {len(steps)} test groups:\n")
    for i, step in enumerate(steps):
        pool, label = format_group(step)
        print(f"  {i:3d}  {pool}: {label}")

    print(f"\nEnter group numbers to KEEP (comma/space separated, or ranges like 5-10).")
    print(f"Example: 0,3,5-8,12\n")
    raw = input("Groups to keep: ").strip()

    selected = set()
    for part in raw.replace(',', ' ').split():
        if '-' in part:
            a, b = part.split('-', 1)
            for n in range(int(a), int(b) + 1):
                selected.add(n)
        else:
            selected.add(int(part))

    return selected


def match_groups(steps, specs, by_label=False):
    """Match specs against steps, return set of indices to keep."""
    selected = set()
    for spec in specs:
        found = False
        for i, step in enumerate(steps):
            pool, label = format_group(step)
            pool_prefix = pool.split('_')[0]
            if by_label:
                if label == spec:
                    selected.add(i)
                    found = True
            else:
                # spec format: "pool:label" or "pool_N:label"
                if ':' not in spec:
                    print(f"ERROR: spec must be 'pool:label', got: {spec}", file=sys.stderr)
                    sys.exit(1)
                s_pool, s_label = spec.split(':', 1)
                if (pool == s_pool or pool_prefix == s_pool) and label == s_label:
                    selected.add(i)
                    found = True
        if not found:
            print(f"WARNING: no match for: {spec}", file=sys.stderr)

    return selected


def write_filtered(yaml_path, lines, steps_line, steps, step_blocks, selected):
    """Write filtered YAML preserving original formatting and section headers."""
    # Everything before "steps:" + the "steps:" line itself
    output_lines = lines[:steps_line + 1]

    # Lines between "steps:" and the first step's leading comments (if any)
    if step_blocks:
        first_comment_start = step_blocks[0][0]
        gap = lines[steps_line + 1:first_comment_start]
        output_lines.extend(gap)

    for i, (comment_start, step_start, end) in enumerate(step_blocks):
        if i in selected:
            # Include leading comments/section headers + step content
            output_lines.extend(lines[comment_start:end])

    # Preserve trailing content after the last step (trailing newlines, etc.)
    if step_blocks:
        last_end = step_blocks[-1][2]
        if last_end < len(lines):
            output_lines.extend(lines[last_end:])

    yaml_path.write_text('\n'.join(output_lines))


def main():
    parser = argparse.ArgumentParser(
        description='Filter test-amd.yaml to selected groups (preserves formatting).',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument('yaml_file', help='Path to test-amd.yaml')
    parser.add_argument('groups', nargs='*',
                        help='Groups to keep: "pool:label" or just "label" with --by-label')
    parser.add_argument('--by-label', action='store_true',
                        help='Match by label only (ignore pool)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would be kept without writing')
    parser.add_argument('--list', action='store_true',
                        help='Just list all groups and exit')
    args = parser.parse_args()

    yaml_path = Path(args.yaml_file)
    if not yaml_path.exists():
        print(f"ERROR: {yaml_path} not found", file=sys.stderr)
        sys.exit(1)

    lines, steps_line, steps, step_blocks = parse_steps(yaml_path)

    if args.list:
        for i, step in enumerate(steps):
            pool, label = format_group(step)
            print(f"{i:3d}  {pool}: {label}")
        return

    if args.groups:
        selected = match_groups(steps, args.groups, by_label=args.by_label)
    else:
        selected = interactive_select(steps)

    if not selected:
        print("ERROR: no groups selected", file=sys.stderr)
        sys.exit(1)

    print(f"\nKeeping {len(selected)} of {len(steps)} groups:")
    for i in sorted(selected):
        pool, label = format_group(steps[i])
        print(f"  {pool}: {label}")

    if args.dry_run:
        print("\n(dry run — file not modified)")
    else:
        write_filtered(yaml_path, lines, steps_line, steps, step_blocks, selected)
        print(f"\nWrote filtered yaml to {yaml_path}")


if __name__ == '__main__':
    main()
