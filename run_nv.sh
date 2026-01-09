#!/usr/bin/env bash
docker  run -it --detach --name=ransmith_vllm_ci_ \
          --gpus all  --ipc=host --entrypoint /bin/bash  \
          -v /data/:/data -v $HOME/git/vllm:/vllm -w /vllm \
          public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo:10ef65eded8187df92c370d6ffd7fd2b8a3c1d3c
          #vllm/vllm-openai:latest
