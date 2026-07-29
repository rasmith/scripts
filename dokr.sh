#!/usr/bin/env bash

# NOTE: Script assumes there is a $HOME/git directory to map to.

USER_NAME=$(whoami)

while [[ $# -gt 0 ]]; do
  case $1 in
    -r|--repo-name)
      REPO_NAME="$2"
      shift # past argument
      shift # past value
      ;;
    -c|--container-name)
      CONTAINER_NAME="$2"
      shift # past argument
      shift # past value
      ;;
    -i|--image-name)
      IMAGE_NAME="$2"
      shift # past argument
      shift # past value
      ;;
    -m|--model-dir)
      MODEL_DIR="$2"
      shift # past argument
      shift # past value
      ;;
    -a|--atom-repo)
      ATOM_REPO_NAME="$2"
      shift # past argument
      shift # past value
      ;;
    -t|--aiter-repo)
      AITER_REPO_NAME="$2"
      shift # past argument
      shift # past value
      ;;
    -e|--env)
      ENV_VARS+=("$2")
      shift # past argument
      shift # past value
      ;;
    --dry-run)
      DRY_RUN=1
      shift # past argument
      ;;
    --which-vllm-repo)
      WHICH="$2"
      shift # past argument
      shift # past value
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

if [[ -n "$WHICH" ]]; then
  REPO_NAME=vllm-$WHICH
fi

if [[ -z "$CONTAINER_NAME" ]]; then
  CONTAINER_NAME="${USER_NAME}_vllm_${WHICH}_container"
else
  CONTAINER_NAME="${USER_NAME}_${CONTAINER_NAME}_container"
fi

if [[ -z "$IMAGE_NAME" ]]; then
  IMAGE_NAME="${USER_NAME}_vllm_${WHICH}"
fi

if [[ -z "$MODEL_DIR" ]]; then
  MODEL_DIR=/data/models
fi

REPO_PATH=$HOME/git/$REPO_NAME
ATOM_REPO_PATH=$HOME/git/$ATOM_REPO_NAME
AITER_REPO_PATH=$HOME/git/$AITER_REPO_NAME

EXTRA_REPO_MAPPINGS=""

if [[ -n "$ATOM_REPO_NAME" ]]; then
  EXTRA_REPO_MAPPINGS="$EXTRA_REPO_MAPPINGS -v $ATOM_REPO_PATH:/$ATOM_REPO_NAME"
fi

if [[ -n "$AITER_REPO_NAME" ]]; then
  EXTRA_REPO_MAPPINGS="$EXTRA_REPO_MAPPINGS -v $AITER_REPO_PATH:/$AITER_REPO_NAME"
fi


echo "USER_NAME=$USER_NAME"
echo "CONTAINER_NAME=$CONTAINER_NAME"
echo "IMAGE_NAME=$IMAGE_NAME"
echo "EXTRA_REPO_MAPPINGS=$EXTRA_REPO_MAPPINGS"
# Just map the git directory if no repo name provided.
if [[ -z $REPO_NAME ]]; then
  echo "Mapping git directory."
  REPO_NAME="git"
else
  echo "REPO_NAME=$REPO_NAME"
fi

DOCKER_CMD=(sudo docker run -it --detach --ipc=host --device=/dev/kfd \
    --device=/dev/dri --shm-size=64G --cap-add=SYS_PTRACE \
    --network host --security-opt seccomp=unconfined \
    --privileged \
    --ulimit core=0:0 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /$HOME/source:/source \
    -v /$HOME/git/scripts:/scripts \
    -v $REPO_PATH:/$REPO_NAME)

if [[ -n "$EXTRA_REPO_MAPPINGS" ]]; then
  DOCKER_CMD+=($EXTRA_REPO_MAPPINGS)
fi

for env_var in "${ENV_VARS[@]}"; do
  DOCKER_CMD+=(-e "$env_var")
done

DOCKER_CMD+=(-v $MODEL_DIR:/models \
    --entrypoint /bin/bash \
    -w /$REPO_NAME --name=$CONTAINER_NAME $IMAGE_NAME)

if [[ -n "$DRY_RUN" ]]; then
  echo "${DOCKER_CMD[@]}"
else
  "${DOCKER_CMD[@]}"
fi
