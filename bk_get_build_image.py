#!/usr/bin/env python3
"""Print the CI image built by a Buildkite build."""

import argparse
import os
import re
import sys

from bk_utils import fetch_build, fetch_ci_image


def load_token(token_file: str) -> str:
    path = os.path.expanduser(token_file)
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError as e:
        print(f"Error: Could not read Buildkite token file {path}: {e}",
              file=sys.stderr)
        sys.exit(1)


def match_rocm_ci_image(log_content: str) -> str | None:
    m = re.search(r'rocm/vllm-ci:(build-[0-9a-f-]{36})', log_content)
    if not m:
        m = re.search(r'rocm/vllm-ci:([0-9a-f]{20,})', log_content)
    return f"rocm/vllm-ci:{m.group(1)}" if m else None


def parse_build_input(input_str: str, pipeline: str,
                      org: str) -> tuple[str, str, str]:
    m = re.search(r"buildkite\.com/([^/]+)/([^/]+)/builds/(\d+)", input_str)
    if m:
        return m.group(1), m.group(2), m.group(3)
    if input_str.strip().isdigit():
        return org, pipeline, input_str.strip()
    print(
        f"Error: Could not parse '{input_str}'. Provide a Buildkite URL or build number.",
        file=sys.stderr)
    sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Print the CI image built by a Buildkite build")
    parser.add_argument("build", help="Buildkite build URL or build number")
    parser.add_argument("--pipeline",
                        default="amd-ci",
                        help="Pipeline slug (default: amd-ci)")
    parser.add_argument("--org",
                        default="vllm",
                        help="Organization slug (default: vllm)")
    parser.add_argument("--bk_token",
                        required=True,
                        help="Path to Buildkite token file")
    args = parser.parse_args()

    token = load_token(args.bk_token)
    org, pipeline, build_num = parse_build_input(args.build, args.pipeline,
                                                 args.org)
    build_data = fetch_build(token, org, pipeline, build_num)
    image = fetch_ci_image(token, org, pipeline, build_data,
                           match_rocm_ci_image)

    if not image:
        print(f"Error: No CI image found for build #{build_num}",
              file=sys.stderr)
        sys.exit(1)
    print(image)


if __name__ == "__main__":
    main()
