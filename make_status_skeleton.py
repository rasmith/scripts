#!/usr/bin/env python3
"""Build a _with_status.txt skeleton of CI failures.

Two modes:

  Reference mode (default) -- convert a rock_vs_main_failures_YYYY_MM_DD.txt,
  which lists the groups that regressed between a baseline and a compare build:

      ./make_status_skeleton.py rock_vs_main_failures_314_09_09_2026.txt

  No-reference mode -- there is no baseline to diff against, so take every
  failing group in a single build straight from the Buildkite API:

      ./make_status_skeleton.py --no-reference 13642
      ./make_status_skeleton.py --no-reference https://buildkite.com/vllm/amd-ci/builds/13642
"""

import argparse
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bk_utils import fetch_build, fetch_ci_image  # noqa: E402

BK_TOKEN_PATH = Path.home() / "tokens" / ".bk_token"
GPUS = ("MI250", "MI300", "MI325", "MI355")

# "mi300_1: :amd: (MI300) MoE Kernels Shard 3" -> pool prefix is dropped, the
# ":amd: (MI300) ..." part is the test group label used in the reports.
POOL_PREFIX = re.compile(r"^\w+:\s+")
# A group with `parallelism: N` becomes N jobs named "... Shard 1", "... Shard 2".
# They are one test group, so drop the number but keep the word, matching how
# the label reads in test-amd.yaml.
SHARD_NUM = re.compile(r"\bShard\s+\d+", re.I)
# "(MI300)" and "(MI355 DPX)" both identify the GPU.
GPU_TAG = re.compile(r"\((MI\d+)[^)]*\)")
# Buildkite gives a blown time limit its own state, distinct from "failed".
FAILED_STATES = ("failed", "broken", "timed_out")


def _bk_token():
    if BK_TOKEN_PATH.is_file():
        return BK_TOKEN_PATH.read_text().strip()
    return None


def match_rocm_ci_image(log_content):
    m = re.search(r"rocm/vllm-ci:(build-[0-9a-f-]{36})", log_content)
    if not m:
        m = re.search(r"rocm/vllm-ci:([0-9a-f]{20,})", log_content)
    return f"rocm/vllm-ci:{m.group(1)}" if m else None


def parse_build_input(text):
    """Accept a build number or a full Buildkite URL."""
    m = re.search(r"buildkite\.com/[^/]+/[^/]+/builds/(\d+)", text)
    if m:
        return m.group(1)
    if text.strip().isdigit():
        return text.strip()
    print(f"Error: could not read a build number from '{text}'.", file=sys.stderr)
    sys.exit(1)


def group_label(job_name):
    """Collapse a job name to its test group label."""
    return SHARD_NUM.sub("Shard", POOL_PREFIX.sub("", job_name)).strip()


def collect_failures(build_data):
    """Map each GPU to its failing test groups, collapsing shards into one group.

    Returns {gpu: {label: [states]}} preserving first-seen group order, plus the
    list of job names that carried no recognisable GPU tag.
    """
    gpu_sections = defaultdict(dict)
    unknown = []
    for job in build_data.get("jobs", []):
        if job.get("state") not in FAILED_STATES:
            continue
        name = job.get("name") or job.get("id", "")
        tag = GPU_TAG.search(name)
        if not tag:
            unknown.append(name)
            continue
        gpu_sections[tag.group(1)].setdefault(group_label(name), []).append(
            job.get("state")
        )
    return gpu_sections, unknown


def parse_failures(text):
    """Parse a reference-mode failures file into (builds, {gpu: [labels]})."""
    lines = text.strip().splitlines()

    builds = {}
    for line in lines[:3]:
        m = re.search(r"builds\s+(\d+)\s+\(baseline\)\s+and\s+(\d+)\s+\(compare\)", line)
        if m:
            builds["baseline"] = m.group(1)
            builds["compare"] = m.group(2)
        m = re.search(r"Build\s+(\d+):\s+(\S+)", line.strip())
        if m:
            builds.setdefault("dates", {})[m.group(1)] = m.group(2)

    gpu_sections = {}
    current_gpu = None
    for line in lines:
        stripped = line.strip()
        if stripped in GPUS:
            current_gpu = stripped
            gpu_sections[current_gpu] = []
        elif stripped.startswith("-----"):
            continue
        elif stripped == "(none)" and current_gpu:
            pass
        elif (stripped and current_gpu and not stripped.startswith("Fetching")
                and not stripped.startswith("Build ")):
            gpu_sections.setdefault(current_gpu, []).append(stripped)

    return builds, gpu_sections


def write_group_entries(out, groups):
    """Write the TG/Test/Failures/Status block for each group in a GPU section.

    `groups` is either a list of labels (reference mode) or a {label: [states]}
    mapping (no-reference mode), where the states let us prefill a timed-out
    group -- there are no FAILED lines in its log to quote later.
    """
    states = groups if isinstance(groups, dict) else {}
    labels = list(groups)
    for i, tg in enumerate(labels):
        out.write(f"TG: {tg}\n")
        out.write("Test: \n")
        if "timed_out" in states.get(tg, []):
            out.write("Failures: (job timed out)\n")
        else:
            out.write("Failures:\n")
        out.write("\n")
        out.write("Status:\n")
        out.write("\n")
        if i < len(labels) - 1:
            out.write("-----------------------\n")


def write_skeleton(builds, gpu_sections, out, no_reference=False):
    out.write("===========================================================\n")

    if no_reference:
        build = builds.get("build", "???")
        out.write(f"Build {build}: {builds.get('date', '????-??-??')}\n")
        out.write(f"Link: https://buildkite.com/vllm/amd-ci/builds/{build}\n")
        if builds.get("image"):
            out.write(f"Image: {builds['image']}\n")
        out.write("\n")
        out.write("Reference:  (none -- all failures in this build)\n")
        out.write("\n")
    else:
        baseline = builds.get("baseline", "???")
        compare = builds.get("compare", "???")
        dates = builds.get("dates", {})
        out.write(f"Reference:  Build {baseline}: {dates.get(baseline, '????-??-??')}\n")
        out.write(f"Link: https://buildkite.com/vllm/amd-ci/builds/{baseline}\n")
        if builds.get("baseline_image"):
            out.write(f"Image: {builds['baseline_image']}\n")
        out.write("\n")
        out.write(f"Comparison:  Build {compare}: {dates.get(compare, '????-??-??')}\n")
        out.write(f"Link: https://buildkite.com/vllm/amd-ci/builds/{compare}\n")
        if builds.get("compare_image"):
            out.write(f"Image: {builds['compare_image']}\n")
        out.write("\n")

    counts = [len(gpu_sections.get(gpu, ())) for gpu in GPUS]
    out.write(f"Total Failures: {' + '.join(str(c) for c in counts)} = {sum(counts)}\n")
    if not no_reference:
        out.write("Checking for Python 3.14 related failures with The Rock 7.14\n")
    out.write("\n")

    for gpu in GPUS:
        groups = gpu_sections.get(gpu, ())
        out.write("\n")
        out.write("======================================================\n")
        out.write("\n")
        out.write(f"      {gpu} ({len(groups)} test group failures)\n")
        out.write("\n")
        out.write("=====================================================\n")
        if not groups:
            out.write("(none)\n")
        else:
            write_group_entries(out, groups)

    out.write("\n")
    out.write("======================================================\n")
    out.write("\n")
    out.write("      FAILURE CATEGORY SUMMARY\n")
    out.write("\n")
    out.write("=====================================================\n")
    out.write("\n")

    out.write("\n")
    out.write("======================================================\n")
    out.write("\n")
    out.write("      COMPARISON WITH PREVIOUS\n")
    out.write("\n")
    out.write("=====================================================\n")
    out.write("\n")
    out.write("FIXED SINCE PREVIOUS:\n")
    out.write("\n")
    out.write("NEW SINCE PREVIOUS:\n")
    out.write("\n")
    out.write("PERSISTING FROM PREVIOUS:\n")
    out.write("\n")


def run_no_reference(args, token):
    build_num = parse_build_input(args.input)
    if not token:
        print(f"Error: no Buildkite token at {BK_TOKEN_PATH}; "
              f"--no-reference needs API access.", file=sys.stderr)
        sys.exit(1)

    build_data = fetch_build(token, args.org, args.pipeline, build_num)
    gpu_sections, unknown = collect_failures(build_data)

    stamp = build_data.get("finished_at") or build_data.get("created_at") or ""
    builds = {
        "build": build_num,
        "date": stamp[:10] if stamp else datetime.now().strftime("%Y-%m-%d"),
    }
    if not args.no_images:
        print(f"  Fetching image for build #{build_num}...")
        image = fetch_ci_image(token, args.org, args.pipeline, build_data,
                               match_rocm_ci_image)
        builds["image"] = image
        print(f"    {image or '(not found)'}")

    if unknown:
        print(f"  Warning: {len(unknown)} failing job(s) had no (MIxxx) tag "
              f"and were skipped:", file=sys.stderr)
        for name in unknown:
            print(f"    {name}", file=sys.stderr)

    n_jobs = sum(len(v) for d in gpu_sections.values() for v in d.values())
    return builds, gpu_sections, build_num, n_jobs


def run_reference(args, token):
    inp = Path(args.input)
    builds, gpu_sections = parse_failures(inp.read_text())

    if not args.no_images:
        if token:
            for key, label in (("baseline", "Reference"), ("compare", "Comparison")):
                build_num = builds.get(key)
                if not build_num:
                    continue
                print(f"  Fetching image for {label} build #{build_num}...")
                build_data = fetch_build(token, args.org, args.pipeline, build_num)
                image = fetch_ci_image(token, args.org, args.pipeline, build_data,
                                       match_rocm_ci_image)
                if image:
                    builds[f"{key}_image"] = image
                print(f"    {image or '(not found)'}")
        else:
            print(f"  No BK token at {BK_TOKEN_PATH}, skipping image lookup")

    return builds, gpu_sections


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input",
                        help="Path to a rock_vs_main_failures_*.txt, or a build "
                             "number/URL when --no-reference is given")
    parser.add_argument("-o", "--output", help="Output path (default: derived)")
    parser.add_argument("--no-reference", action="store_true",
                        help="No baseline build to diff against: take every failing "
                             "group in the given build from the Buildkite API")
    parser.add_argument("--no-images", action="store_true",
                        help="Skip fetching Docker image tags from Buildkite")
    parser.add_argument("--pipeline", default="amd-ci",
                        help="Pipeline slug (default: amd-ci)")
    parser.add_argument("--org", default="vllm",
                        help="Organization slug (default: vllm)")
    args = parser.parse_args()

    token = _bk_token()

    if args.no_reference:
        builds, gpu_sections, build_num, n_jobs = run_no_reference(args, token)
        default_out = Path.cwd() / f"build_{build_num}_failures_with_status.txt"
    else:
        builds, gpu_sections = run_reference(args, token)
        n_jobs = None
        stem = re.sub(r"(\d{2})-(\d{2})-(\d{4})", r"\3_\1_\2", Path(args.input).stem)
        default_out = Path(args.input).parent / f"{stem}_with_status.txt"

    out_path = Path(args.output) if args.output else default_out
    with open(out_path, "w") as f:
        write_skeleton(builds, gpu_sections, f, no_reference=args.no_reference)

    print(f"Wrote skeleton to {out_path}")
    if args.no_reference:
        print(f"  Build: {builds['build']} ({builds['date']})")
    else:
        print(f"  Baseline: {builds.get('baseline')}, Compare: {builds.get('compare')}")
    total = 0
    for gpu in GPUS:
        n = len(gpu_sections.get(gpu, ()))
        total += n
        print(f"  {gpu}: {n} groups")
    if n_jobs is not None:
        print(f"  total: {total} test groups across {n_jobs} failing jobs")
    else:
        print(f"  total: {total} test groups")


if __name__ == "__main__":
    main()
