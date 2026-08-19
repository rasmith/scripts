#!/usr/bin/env bash
#
# trigger_branch.sh — trigger a Buildkite amd-ci build.
#
# Two modes:
#   run     — trigger a build directly from an existing branch
#   overlay — create a branch by overlaying files from a target onto a source,
#             push it, and trigger a build
#
# Usage:
#   ./trigger_branch.sh run --fork <org/repo> --branch <branch> --token <token> --message <msg> [--dry-run]
#   ./trigger_branch.sh overlay --source <ref|4am> --destination <org/repo:branch> --token <token> --message <msg> [--target <org/repo:branch> --overlay-paths <files>] [--overlays <file.yaml>] [--dry-run]
#
# Examples:
#   # Direct branch run (default: triggers)
#   ./trigger_branch.sh run --fork rasmith/vllm --branch therock-nightly --token $(cat ~/claude/.bk_token) --message "Full CI"
#
#   # Direct branch run (dry run)
#   ./trigger_branch.sh run --fork rasmith/vllm --branch therock-nightly --token $(cat ~/claude/.bk_token) --message "Full CI" --dry-run
#
#   # Overlay: take 4am nightly, overlay specific files from a branch, push and trigger
#   ./trigger_branch.sh overlay --source 4am --target rasmith/vllm:rock-312-ci \
#       --destination rasmith/vllm:therock-nightly \
#       --overlay-paths "docker/Dockerfile.rocm docker/Dockerfile.rocm_base requirements/build/rocm.txt requirements/test/rocm.in requirements/test/rocm.txt" \
#       --token $(cat ~/claude/.bk_token) --message "AMD Full CI Run - TheRock 312"

set -euo pipefail

BK_ORG="vllm"
BK_PIPELINE="amd-ci"
NIGHTLY_BUILD_NAME="AMD Full CI Run - nightly"
SYNC_REPO_DIR="$HOME/.cache/trigger-branch/vllm"

# ---- Helpers ----

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

find_nightly_commit() {
    local token="$1"
    local url="https://api.buildkite.com/v2/organizations/${BK_ORG}/pipelines/${BK_PIPELINE}/builds?per_page=100"
    local tmp
    tmp="$(mktemp)"
    curl -fsSL -H "Authorization: Bearer ${token}" "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
    NIGHTLY_BUILD_NAME="$NIGHTLY_BUILD_NAME" python3 - "$tmp" <<'PY'
import json, os, sys
with open(sys.argv[1]) as fh:
    builds = json.load(fh)
name = os.environ["NIGHTLY_BUILD_NAME"]
for b in builds:
    if (b.get("message") or "").strip() == name:
        commit = b.get("commit") or ""
        if commit:
            sys.stderr.write("matched build #%s commit=%s\n" % (b.get("number"), commit[:9]))
            print(commit)
            break
PY
    rm -f "$tmp"
}

trigger_build() {
    local token="$1" commit="$2" branch_ref="$3" message="$4" dry_run="$5"

    local body
    body=$(python3 -c "
import json
print(json.dumps({
    'commit': '$commit',
    'branch': '$branch_ref',
    'message': '$message',
    'ignore_pipeline_branch_filters': True,
    'env': {
        'NIGHTLY': '1',
        'AMD_MIRROR_HW': 'amdexperimental',
        'DOCS_ONLY_DISABLE': '1',
    },
}))
")

    echo "Commit:  $commit"
    echo "BK ref:  $branch_ref"
    echo "Message: $message"

    if [[ "$dry_run" == "1" ]]; then
        echo ""
        echo "DRY RUN — would POST:"
        echo "$body" | python3 -m json.tool
        echo ""
        echo "Remove --dry-run to trigger for real."
    else
        echo ""
        echo "Triggering build..."
        local resp
        resp=$(curl -fsSL -X POST \
            -H "Authorization: Bearer $token" \
            -H "Content-Type: application/json" \
            "https://api.buildkite.com/v2/organizations/${BK_ORG}/pipelines/${BK_PIPELINE}/builds" \
            --data "$body")
        echo "$resp" | python3 -c "
import json, sys
b = json.load(sys.stdin)
print(f'Build #{b[\"number\"]} -> {b[\"web_url\"]}')
"
    fi
}

ensure_clone() {
    if [[ ! -d "$SYNC_REPO_DIR/.git" ]]; then
        echo "Cloning scratch repo into $SYNC_REPO_DIR"
        mkdir -p "$(dirname "$SYNC_REPO_DIR")"
        git clone https://github.com/vllm-project/vllm.git "$SYNC_REPO_DIR"
    fi
}

ensure_remote() {
    local name="$1" url="$2"
    if git -C "$SYNC_REPO_DIR" remote get-url "$name" >/dev/null 2>&1; then
        git -C "$SYNC_REPO_DIR" remote set-url "$name" "$url"
    else
        git -C "$SYNC_REPO_DIR" remote add "$name" "$url"
    fi
}

# Parse an --overlays yaml into "org/repo:branch file file ..." lines.
#
#   overlays:
#     - repo: rasmith/vllm:rock-312-ci
#       files:
#         - docker/Dockerfile.rocm
parse_overlays_yaml() {
    local path="$1"
    python3 -c '
import sys, yaml

with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh) or {}

entries = doc.get("overlays", doc) if isinstance(doc, dict) else doc
if not isinstance(entries, list):
    sys.exit("overlays: expected a list of entries")

for i, e in enumerate(entries):
    if not isinstance(e, dict):
        sys.exit(f"overlays[{i}]: expected a mapping with repo/files")
    repo = e.get("repo")
    files = e.get("files") or []
    if not repo:
        sys.exit(f"overlays[{i}]: missing repo")
    if ":" not in repo:
        sys.exit(f"overlays[{i}]: repo must be org/repo:branch, got {repo!r}")
    if not isinstance(files, list) or not files:
        sys.exit(f"overlays[{i}] ({repo}): files must be a non-empty list")
    for f in files:
        if not isinstance(f, str) or not f.strip():
            sys.exit(f"overlays[{i}] ({repo}): bad file entry {f!r}")
        if any(c.isspace() for c in f.strip()):
            sys.exit(f"overlays[{i}] ({repo}): whitespace in path {f!r}")
    print(repo + " " + " ".join(f.strip() for f in files))
' "$path"
}

# Parse a --direct-overlays yaml into "src dest" pairs, one per line.
# Mirrors parse_overlays_yaml, but files come from the local filesystem
# instead of a git ref, so "repo" becomes "root".
#
#   direct_overlays:
#     - root: /home/ransmith/git/vllm-rock-312
#       files:
#         - docker/Dockerfile.rocm
parse_direct_overlays_yaml() {
    local path="$1"
    python3 -c '
import os, sys, yaml

with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh) or {}

entries = doc.get("direct_overlays", doc) if isinstance(doc, dict) else doc
if not isinstance(entries, list):
    sys.exit("direct_overlays: expected a list of entries")

for i, e in enumerate(entries):
    if not isinstance(e, dict):
        sys.exit(f"direct_overlays[{i}]: expected a mapping with root/files")
    root = e.get("root")
    files = e.get("files") or []
    if not root:
        sys.exit(f"direct_overlays[{i}]: missing root")
    root = os.path.expanduser(str(root))
    if not os.path.isdir(root):
        sys.exit(f"direct_overlays[{i}]: root is not a directory: {root}")
    if not isinstance(files, list) or not files:
        sys.exit(f"direct_overlays[{i}] ({root}): files must be a non-empty list")
    for f in files:
        if not isinstance(f, str) or not f.strip():
            sys.exit(f"direct_overlays[{i}] ({root}): bad file entry {f!r}")
        f = f.strip()
        if any(c.isspace() for c in f):
            sys.exit(f"direct_overlays[{i}] ({root}): whitespace in path {f!r}")
        # "src dest": dest is the repo-relative path, which is the entry itself.
        print(os.path.join(root, f) + " " + f)
' "$path"
}

# Parse org/repo:branch into parts
parse_ref() {
    local ref="$1"
    local org_repo="${ref%%:*}"
    local branch="${ref#*:}"
    echo "$org_repo" "$branch"
}

# ---- Mode: run ----

cmd_run() {
    local fork="" branch="" message="" token="" dry_run=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --fork) fork="$2"; shift 2 ;;
            --branch) branch="$2"; shift 2 ;;
            --message) message="$2"; shift 2 ;;
            --token) token="$2"; shift 2 ;;
            --dry-run) dry_run=1; shift ;;
            -h|--help) echo "Usage: $0 run --fork <org/repo> --branch <branch> --token <token> --message <msg> [--dry-run]"; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$fork" ]] || die "--fork required"
    [[ -n "$branch" ]] || die "--branch required"
    [[ -n "$token" ]] || die "--token required"
    [[ -n "$message" ]] || die "--message required"

    local fork_url="https://github.com/${fork}"
    local commit
    commit=$(git ls-remote "$fork_url" "refs/heads/$branch" | awk '{print $1}')
    [[ -n "$commit" ]] || die "branch '$branch' not found on $fork_url"

    local bk_branch="${fork_url}/tree/${branch}"

    echo "Mode:    run"
    echo "Fork:    $fork_url"
    echo "Branch:  $branch"
    trigger_build "$token" "$commit" "$bk_branch" "$message" "$dry_run"
}

# ---- Mode: overlay ----

cmd_overlay() {
    local source="" target="" destination="" message="" token="" dry_run=0 overlay_paths="" filter_groups=""
    local overlays_file="" filter_groups_file=""
    local direct_root="" direct_overlay_paths="" direct_overlays_file=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --source) source="$2"; shift 2 ;;
            --target) target="$2"; shift 2 ;;
            --destination) destination="$2"; shift 2 ;;
            --overlay-paths) overlay_paths="$2"; shift 2 ;;
            --overlays) overlays_file="$2"; shift 2 ;;
            --direct-root) direct_root="$2"; shift 2 ;;
            --direct-overlay-paths) direct_overlay_paths="$2"; shift 2 ;;
            --direct-overlays) direct_overlays_file="$2"; shift 2 ;;
            --filter-groups) filter_groups="$2"; shift 2 ;;
            --filter-groups-file) filter_groups_file="$2"; shift 2 ;;
            --message) message="$2"; shift 2 ;;
            --token) token="$2"; shift 2 ;;
            --dry-run) dry_run=1; shift ;;
            -h|--help)
                echo "Usage: $0 overlay --source <ref|4am> --destination <org/repo:branch> --token <token> --message <msg> [--target <org/repo:branch> --overlay-paths <files>] [--overlays <file.yaml>] [--direct-root <dir> --direct-overlay-paths <files>] [--direct-overlays <file.yaml>] [--filter-groups <all|none|groups>] [--dry-run]"
                echo ""
                echo "  --target/--overlay-paths  Overlay files from one branch"
                echo "  --overlays <file.yaml>    Overlay files from any number of branches,"
                echo "                            applied after --target."
                echo ""
                echo "    overlays:"
                echo "      - repo: rasmith/vllm:rock-312-ci"
                echo "        files:"
                echo "          - docker/Dockerfile.rocm"
                echo "          - docker/Dockerfile.rocm_base"
                echo "      - repo: rasmith/vllm:fix_multi_modal"
                echo "        files:"
                echo "          - vllm/v1/attention/backends/rocm_attn.py"
                echo ""
                echo "  --direct-root/--direct-overlay-paths  Copy files from a local"
                echo "                            directory instead of a git ref."
                echo "  --direct-overlays <file.yaml>  Same, from any number of roots."
                echo ""
                echo "    direct_overlays:"
                echo "      - root: ~/git/vllm-rock-312"
                echo "        files:"
                echo "          - .buildkite/test-amd.yaml"
                echo ""
                echo "  Direct overlays are applied after the git overlays, so they win"
                echo "  on any overlapping path. At least one overlay of any kind is"
                echo "  required."
                echo ""
                echo "  --filter-groups all    Keep all test groups (default)"
                echo "  --filter-groups none   Remove all test groups"
                echo "  --filter-groups 'pool:label pool:label ...'  Keep only specified groups"
                echo "  --filter-groups --by-label 'label label ...'  Keep by label (all pools)"
                echo "  --filter-groups-file <file>  Same, one group per line;"
                echo "                               blank lines and # comments ignored."
                echo "                               Mutually exclusive with --filter-groups."
                exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    [[ -n "$source" ]] || die "--source required"
    [[ -n "$destination" ]] || die "--destination required (e.g. rasmith/vllm:run_rock_10)"
    [[ -n "$token" ]] || die "--token required"
    [[ -n "$message" ]] || die "--message required"
    if [[ -n "$target" && -z "$overlay_paths" ]]; then die "--target requires --overlay-paths"; fi
    if [[ -n "$overlay_paths" && -z "$target" ]]; then die "--overlay-paths requires --target"; fi
    if [[ -n "$direct_root" && -z "$direct_overlay_paths" ]]; then
        die "--direct-root requires --direct-overlay-paths"
    fi
    if [[ -n "$direct_overlay_paths" && -z "$direct_root" ]]; then
        die "--direct-overlay-paths requires --direct-root"
    fi
    if [[ -z "$target" && -z "$overlays_file" \
          && -z "$direct_root" && -z "$direct_overlays_file" ]]; then
        die "at least one of --target/--overlay-paths, --overlays, --direct-root/--direct-overlay-paths, or --direct-overlays required"
    fi
    if [[ -n "$overlays_file" && ! -f "$overlays_file" ]]; then
        die "--overlays file not found: $overlays_file"
    fi
    if [[ -n "$direct_overlays_file" && ! -f "$direct_overlays_file" ]]; then
        die "--direct-overlays file not found: $direct_overlays_file"
    fi
    if [[ -n "$direct_root" && ! -d "$direct_root" ]]; then
        die "--direct-root is not a directory: $direct_root"
    fi
    if [[ -n "$filter_groups" && -n "$filter_groups_file" ]]; then
        die "--filter-groups and --filter-groups-file are mutually exclusive"
    fi
    # One argv entry per group. Labels contain spaces, so the file path keeps
    # line boundaries instead of collapsing to a single word-split string.
    local -a filter_group_args=()
    if [[ -n "$filter_groups_file" ]]; then
        [[ -f "$filter_groups_file" ]] \
            || die "--filter-groups-file not found: $filter_groups_file"
        # One group per line; blank lines and # comments ignored. "pool: label"
        # is normalized to "pool:label" so output copied from
        # list_test_groups.py matches the exact-label compare in the filter.
        mapfile -t filter_group_args < <(
            sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                -e 's/^\([^:]*\):[[:space:]]*/\1:/' \
                "$filter_groups_file" | grep -v '^$'
        )
        [[ ${#filter_group_args[@]} -gt 0 ]] \
            || die "--filter-groups-file has no groups: $filter_groups_file"
        # Non-empty marker for the mode checks below; the array drives the call.
        filter_groups="${filter_group_args[*]}"
        echo "Filter groups from $filter_groups_file (${#filter_group_args[@]}):"
        printf '  %s\n' "${filter_group_args[@]}"
    elif [[ -n "$filter_groups" ]]; then
        # Long-standing --filter-groups behavior: split on whitespace.
        read -r -a filter_group_args <<< "$filter_groups"
    fi

    # Build the overlay list: "org/repo:branch file file ..." per line.
    # --target comes first so --overlays entries win on any overlapping file.
    local overlay_specs=""
    if [[ -n "$target" ]]; then
        overlay_specs=$(printf '%s %s\n' "$target" "$overlay_paths")
    fi
    if [[ -n "$overlays_file" ]]; then
        local from_yaml
        from_yaml=$(parse_overlays_yaml "$overlays_file") \
            || die "Could not parse --overlays file: $overlays_file"
        [[ -n "$from_yaml" ]] || die "No overlay entries found in $overlays_file"
        overlay_specs="${overlay_specs:+$overlay_specs$'\n'}$from_yaml"
    fi

    # Build the direct overlay list: "src dest" per line, src absolute.
    # --direct-root comes first so --direct-overlays wins on overlapping paths.
    local direct_specs=""
    if [[ -n "$direct_root" ]]; then
        local dp
        for dp in $direct_overlay_paths; do
            direct_specs+="${direct_root%/}/$dp $dp"$'\n'
        done
    fi
    if [[ -n "$direct_overlays_file" ]]; then
        local direct_from_yaml
        direct_from_yaml=$(parse_direct_overlays_yaml "$direct_overlays_file") \
            || die "Could not parse --direct-overlays file: $direct_overlays_file"
        [[ -n "$direct_from_yaml" ]] \
            || die "No direct overlay entries found in $direct_overlays_file"
        direct_specs="${direct_specs}${direct_from_yaml}"$'\n'
    fi
    # Fail before any network work if a source file is missing.
    local dsrc ddest
    while read -r dsrc ddest; do
        [[ -n "$dsrc" ]] || continue
        [[ -f "$dsrc" ]] || die "Direct overlay source not found: $dsrc"
    done <<< "$direct_specs"

    # Parse destination
    read -r dest_org_repo dest_branch <<< "$(parse_ref "$destination")"
    local dest_url="git@github.com:${dest_org_repo}.git"

    ensure_clone

    # Set up remotes. The destination is set last so its SSH URL wins if an
    # overlay repo lives on the same remote (we push there, so SSH is required).
    ensure_remote origin "https://github.com/vllm-project/vllm.git"
    local ref files org_repo branch remote
    while read -r ref files; do
        [[ -n "$ref" ]] || continue
        read -r org_repo branch <<< "$(parse_ref "$ref")"
        ensure_remote "${org_repo%%/*}" "https://github.com/${org_repo}.git"
    done <<< "$overlay_specs"
    local dest_remote="${dest_org_repo%%/*}"
    ensure_remote "$dest_remote" "$dest_url"

    echo "Fetching remotes..."
    git -C "$SYNC_REPO_DIR" fetch --quiet origin || true
    while read -r ref files; do
        [[ -n "$ref" ]] || continue
        read -r org_repo branch <<< "$(parse_ref "$ref")"
        git -C "$SYNC_REPO_DIR" fetch --quiet "${org_repo%%/*}" || true
    done <<< "$overlay_specs"
    git -C "$SYNC_REPO_DIR" fetch --quiet "$dest_remote" || true

    # Resolve source commit
    local source_commit
    if [[ "$source" == "4am" ]]; then
        echo "Looking up latest 4am nightly commit..."
        source_commit=$(find_nightly_commit "$token")
        [[ -n "$source_commit" ]] || die "No nightly build found"
        echo "4am nightly commit: $source_commit"
    else
        source_commit=$(git -C "$SYNC_REPO_DIR" rev-parse "$source" 2>/dev/null) \
            || die "Cannot resolve source ref: $source"
        echo "Source commit: $source_commit"
    fi

    # Verify source commit is reachable
    git -C "$SYNC_REPO_DIR" cat-file -e "${source_commit}^{commit}" 2>/dev/null \
        || die "Source commit $source_commit not reachable"

    # Reset destination branch to source commit
    echo "Resetting $dest_branch to $source_commit"
    git -C "$SYNC_REPO_DIR" checkout -B "$dest_branch" "$source_commit" --quiet

    # Overlay files, in order -- later entries win on any overlapping path
    local f
    while read -r ref files; do
        [[ -n "$ref" ]] || continue
        read -r org_repo branch <<< "$(parse_ref "$ref")"
        remote="${org_repo%%/*}"
        echo "Overlaying files from ${remote}/${branch}:"
        for f in $files; do
            mkdir -p "$SYNC_REPO_DIR/$(dirname "$f")"
            git -C "$SYNC_REPO_DIR" show "${remote}/${branch}:${f}" > "$SYNC_REPO_DIR/$f" \
                || die "Could not read ${remote}/${branch}:${f}"
            git -C "$SYNC_REPO_DIR" add "$f"
            echo "  $f"
        done
    done <<< "$overlay_specs"

    # Direct overlays: copy from the local filesystem. Applied after the git
    # overlays so they win on any overlapping path.
    if [[ -n "${direct_specs//[[:space:]]/}" ]]; then
        echo "Applying direct overlays:"
        while read -r dsrc ddest; do
            [[ -n "$dsrc" ]] || continue
            mkdir -p "$SYNC_REPO_DIR/$(dirname "$ddest")"
            cp "$dsrc" "$SYNC_REPO_DIR/$ddest" \
                || die "Could not copy $dsrc"
            git -C "$SYNC_REPO_DIR" add "$ddest"
            echo "  $ddest <- $dsrc"
        done <<< "$direct_specs"
    fi

    # Filter test groups if requested
    local test_amd="$SYNC_REPO_DIR/.buildkite/test-amd.yaml"
    local filter_script="$HOME/claude/runs/filter_test_groups.py"
    if [[ -n "$filter_groups" && -f "$test_amd" && -f "$filter_script" ]]; then
        if [[ "$filter_groups" == "all" ]]; then
            echo "Keeping all test groups"
        elif [[ "$filter_groups" == "none" ]]; then
            echo "Removing all test groups"
            python3 "$filter_script" "$test_amd" --by-label "__MATCH_NOTHING__" 2>/dev/null || {
                # No groups matched = empty steps. Write minimal yaml.
                sed -i '/^steps:/,$d' "$test_amd"
                echo "steps: []" >> "$test_amd"
            }
            git -C "$SYNC_REPO_DIR" add .buildkite/test-amd.yaml
        else
            echo "Filtering test groups..."
            # Support --by-label prefix: "--by-label label1 label2"
            if [[ "$filter_groups" == --by-label* ]]; then
                local labels="${filter_groups#--by-label }"
                python3 "$filter_script" "$test_amd" --by-label $labels \
                    || die "filter_test_groups.py failed"
            else
                python3 "$filter_script" "$test_amd" "${filter_group_args[@]}" \
                    || die "filter_test_groups.py failed"
            fi
            git -C "$SYNC_REPO_DIR" add .buildkite/test-amd.yaml
        fi
    fi

    # Commit -- subject lists every overlay ref that contributed
    local overlay_refs=""
    while read -r ref files; do
        [[ -n "$ref" ]] || continue
        overlay_refs="${overlay_refs:+$overlay_refs, }$ref"
    done <<< "$overlay_specs"
    local direct_count=0
    while read -r dsrc ddest; do
        [[ -n "$dsrc" ]] || continue
        direct_count=$((direct_count + 1))
    done <<< "$direct_specs"
    if [[ "$direct_count" -gt 0 ]]; then
        overlay_refs="${overlay_refs:+$overlay_refs, }${direct_count} direct file(s)"
    fi
    git -C "$SYNC_REPO_DIR" \
        -c user.name="trigger-branch" -c user.email="trigger-branch@local" \
        commit --allow-empty -q -m "overlay: ${overlay_refs} on ${source_commit:0:9}"

    local derived
    derived=$(git -C "$SYNC_REPO_DIR" rev-parse HEAD)
    echo "Derived commit: $derived"

    if [[ "$dry_run" == "1" ]]; then
        echo ""
        echo "DRY RUN — would:"
        echo "  git push -f $dest_remote $dest_branch"
        echo "  trigger build for $derived"
        echo ""
        echo "Remove --dry-run to trigger for real."
    else
        echo "Force-pushing $dest_branch -> $dest_url"
        git -C "$SYNC_REPO_DIR" push -f "$dest_remote" "$dest_branch"

        local bk_branch="https://github.com/${dest_org_repo}/tree/${dest_branch}"
        trigger_build "$token" "$derived" "$bk_branch" "$message" "0"
    fi
}

# ---- Main ----

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <run|overlay> [options]"
    echo "  run      — trigger a build from an existing branch"
    echo "  overlay  — overlay files from target onto source, push, and trigger"
    echo ""
    echo "Run '$0 run --help' or '$0 overlay --help' for details."
    exit 0
fi

MODE="$1"; shift
case "$MODE" in
    run) cmd_run "$@" ;;
    overlay) cmd_overlay "$@" ;;
    *) die "Unknown mode: $MODE. Use 'run' or 'overlay'." ;;
esac
