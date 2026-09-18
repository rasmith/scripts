#!/usr/bin/env bash

# Buildkite build image:Eg:rocm/vllm-ci:build-01a0b326-f190-41c3-a6d5-45f4bd7c1cb1
# Buildkite build #: 13189
#
# Usage: setup_container_bk.sh <build# or buildkite URL> [extra dokr.sh args...]

#set -euo pipefail
set -x

BK_GET_IMAGE=$HOME/git/scripts/bk_get_build_image.py
BK_TOKEN_FILE=${BK_TOKEN_FILE:-$HOME/tokens/.bk_token}
HF_TOKEN_FILE=${HF_TOKEN_FILE:-$HOME/tokens/.hf_token}

DOKR=$HOME/git/scripts/dokr.sh
DOCKER_PULL=~/claude/docker_pull.sh

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <build# or buildkite URL> [extra dokr.sh args...]" >&2
  exit 1
fi

BUILD="$1"
shift

echo "Resolving CI image for Buildkite build $BUILD ..."
IMAGE=$("$BK_GET_IMAGE" "$BUILD" --bk_token "$BK_TOKEN_FILE")
echo "Image: $IMAGE"

while ! docker image inspect "$IMAGE" >/dev/null 2>&1; do
  $DOCKER_PULL $IMAGE
done

REPO_NAME="vllm-bk-$BUILD"
CONTAINER_NAME=$(echo $REPO_NAME | sed 's/-/_/'g)

git clone git@github.com:rasmith/vllm.git ~/git/$REPO_NAME

CONTAINER_HASH=$($DOKR -i $IMAGE -r $REPO_NAME -c $CONTAINER_NAME \
                       -e HF_TOKEN=$(cat $HF_TOKEN_FILE) | tail -1)

GFX_ARCH=$(rocm_agent_enumerator | head -1)

docker exec $CONTAINER_HASH bash -c "cd /$REPO_NAME && pip uninstall -y vllm && \
                                        /scripts/rebuild.sh $GFX_ARCH"
