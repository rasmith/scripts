#!/usr/bin/env bash

if [[ -n "$1" ]]; then
	export PYTORCH_ROCM_ARCH=$1
	echo "Using arch $1"
fi

git config --global --add safe.directory $(realpath $(pwd))

python3 setup.py clean --all
find . -name *.so -delete
rm -Rf build
MAX_JOBS=128 python3 setup.py develop
