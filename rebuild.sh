#!/usr/bin/env bash

if [[ -n "$1" ]]; then
	export PYTORCH_ROCM_ARCH=$1
	echo "Using arch $1"
fi

python setup.py clean --all
find . -name *.so -delete
rm -Rf build
python setup.py develop
