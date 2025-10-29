#!/usr/bin/env bash

set -x
git submodule sync && git submodule update --init --recursive
cd $HOME/git
git clone git@github.com:rasmith/config.git
cd config
./setup.sh
cd $HOME
mkdir bak source venvs tmp

