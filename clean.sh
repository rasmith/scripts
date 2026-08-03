#!/usr/bin/env bash
USER=$(whoami)
sudo chown -R $USER:$USER .
git clean -fdx
