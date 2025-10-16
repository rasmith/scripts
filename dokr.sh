#/usr/bin/env bash

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

echo "USER_NAME=$USER_NAME"
echo "CONTAINER_NAME=$CONTAINER_NAME"
echo "IMAGE_NAME=$IMAGE_NAME"
# Just map the git directory if no repo name provided.
if [[ -z $REPO_NAME ]]; then
  echo "Mapping git directory."
  REPO_NAME="git"
else
  echo "REPO_NAME=$REPO_NAME"
fi

sudo docker run -it --detach --ipc=host --device=/dev/kfd \
    --device=/dev/dri --shm-size=64G --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --ulimit core=0:0 \
    -v /$HOME/source:/source \
    -v /$HOME/git/scripts:/scripts \
    -v $REPO_PATH:/$REPO_NAME \
    -v $MODEL_DIR:/models \
    -w /$REPO_NAME --name=$CONTAINER_NAME $IMAGE_NAME
