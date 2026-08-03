#!/usr/bin/env bash
#
# trigger_branch.sh — trigger a Buildkite amd-ci build directly from a branch.
# No overlay, no nightly lookup. Just push-and-run.
#
# Usage:
#   ./trigger_branch.sh --fork <org/repo> --branch <branch> [options]
#
# Examples:
#   # Dry run (default)
#   ./trigger_branch.sh --fork rasmith/vllm --branch therock-nightly
#
#   # Real trigger
#   ./trigger_branch.sh --fork rasmith/vllm --branch therock-nightly --run
#
#   # With message
#   ./trigger_branch.sh --fork ROCm/vllm --branch my-branch --run --message "My CI run"

set -euo pipefail

# Defaults
BK_ORG="vllm"
BK_PIPELINE="amd-ci"
FORK=""
BRANCH=""
MESSAGE=""
BK_TOKEN=""
DRY_RUN=1

usage() {
    echo "Usage: $0 --fork <org/repo> --branch <branch> [options]"
    echo "  --fork FORK            GitHub fork (e.g. rasmith/vllm)"
    echo "  --branch BRANCH        Branch to build"
    echo "  --run                  Actually trigger (default is dry run)"
    echo "  --message MSG          Build message (default: auto-generated)"
    echo "  --token TOKEN          Buildkite API token (default: reads ~/claude/.bk_token)"
    echo "  -h, --help             Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --fork) FORK="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --run) DRY_RUN=0; shift ;;
        --message) MESSAGE="$2"; shift 2 ;;
        --token) BK_TOKEN="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -n "$FORK" ]] || { echo "Error: --fork required"; usage; }
[[ -n "$BRANCH" ]] || { echo "Error: --branch required"; usage; }
[[ -n "$BK_TOKEN" ]] || { echo "Error: --token required"; usage; }
[[ -n "$MESSAGE" ]] || { echo "Error: --message required"; usage; }
FORK="https://github.com/${FORK}"

# Get the branch tip commit
COMMIT=$(git ls-remote "$FORK" "refs/heads/$BRANCH" | awk '{print $1}')
[[ -n "$COMMIT" ]] || { echo "Error: branch '$BRANCH' not found on $FORK"; exit 1; }

# Build the branch ref Buildkite expects for fork builds
BK_BRANCH="${FORK}/tree/${BRANCH}"


echo "Branch:  $BRANCH"
echo "Fork:    $FORK"
echo "Commit:  $COMMIT"
echo "BK ref:  $BK_BRANCH"
echo "Message: $MESSAGE"

BODY=$(python3 -c "
import json
print(json.dumps({
    'commit': '$COMMIT',
    'branch': '$BK_BRANCH',
    'message': '$MESSAGE',
    'ignore_pipeline_branch_filters': True,
    'env': {
        'NIGHTLY': '1',
        'AMD_MIRROR_HW': 'amdexperimental',
        'DOCS_ONLY_DISABLE': '1',
    },
}))
")

if [[ "$DRY_RUN" == "1" ]]; then
    echo ""
    echo "DRY RUN — would POST:"
    echo "$BODY" | python3 -m json.tool
    echo ""
    echo "To trigger for real: $0 --run"
else
    echo ""
    echo "Triggering build..."
    RESP=$(curl -fsSL -X POST \
        -H "Authorization: Bearer $BK_TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.buildkite.com/v2/organizations/${BK_ORG}/pipelines/${BK_PIPELINE}/builds" \
        --data "$BODY")
    echo "$RESP" | python3 -c "
import json, sys
b = json.load(sys.stdin)
print(f'Build #{b[\"number\"]} -> {b[\"web_url\"]}')
"
fi
