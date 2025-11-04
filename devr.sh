#/usr/bin/env bash

# NOTE: Script assumes there is a $HOME/git directory to map to.

USER=$(whoami)

IMAGE=${USER}_dev
CONTAINER=${IMAGE}_container

BUILD_OR_CREATE=$1

if [[ -n $BUILD_OR_CREATE ]]; then
  if [[ $BUILD_OR_CREATE = "build" ]]; then
    echo "Building container: $CONTAINER ..."
    docker build -f Dockerfile.dev -t $IMAGE \
                    --build-arg UID=$(id -g) \
                    --build-arg GID=$(id -u) \
                    --build-arg USER=$USER  .
    exit
  fi
else
  echo "Attempting to run container $CONTAINER..."
fi

if docker ps -a | grep -q $CONTAINER; then
  read -p "Container ($CONTAINER) already exists, delete it? " YES_OR_NO
  if [[ $YES_OR_NO = 'y' ]]; then
    echo "Deleting container: $CONTAINER ..."
    docker rm -f $CONTAINER
  else
    echo "Container already exists and did not read 'y', so exiting."
    exit
  fi
fi

sudo docker run -it --ipc=host --device=/dev/kfd \
    --detach-keys "ctrl-\,q" \
    --device=/dev/dri --shm-size=64G --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --ulimit core=0:0 \
    -v $HOME/source:/source \
    -v $HOME/git:/git \
    -w /git --name=$CONTAINER $IMAGE
