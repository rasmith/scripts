#/usr/bin/env bash

# NOTE: Script assumes there is a $HOME/git directory to map to.

USER_NAME=$(whoami)

CONTAINER=ransmith_dev_container

if docker ps -a | grep -q $CONTAINER; then
  read -p "Container ($CONTAINER) already exists, delete it? " YESNO
  if [[ $YESNO = 'y' ]]; then
    echo "Deleting container: $CONTAINER."
    docker rm -f $CONTAINER
  else
    echo "Container already exists and did not read 'y', so exiting."
    exit
  fi
fi

sudo docker run -it --ipc=host --device=/dev/kfd \
    --device=/dev/dri --shm-size=64G --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --ulimit core=0:0 \
    -v $HOME/source:/source \
    -v $HOME/git:/git \
    -w /git --name=ransmith_dev_container ransmith_dev
