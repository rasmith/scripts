#!/usr/bin/env bash

MODEL=$1

if [[ -z $MODEL ]]; then
  echo "Empty model, expect non-empty first argument to be model."
fi

export VLLM_USE_V1=1
export SAFETENSORS_FAST_GPU=1
export VLLM_ROCM_USE_AITER=1
export VLLM_ROCM_USE_AITER_MOE=1
#export VLLM_USE_TRITON_FLASH_ATTN=0
export NCCL_DEBUG=WARN
export VLLM_LOGGING_LEVEL=DEBUG
export VLLM_RPC_TIMEOUT=1800000
export VLLM_ROCM_USE_AITER_ASMMOE=1
export VLLM_ROCM_USE_AITER_MHA=1

########## For the Accuracy Issue ###########
export VLLM_ROCM_USE_TRITON_ROPE=1
#############################################

vllm serve --model $MODEL \
  --tensor-parallel-size 8 \
  --max-num-batched-tokens 32768 \
  --trust-remote-code \
  --no-enable-prefix-caching \
  --disable-log-requests \
  --enable-expert-parallel \
  --kv-cache-dtype bfloat16 \
  --gpu_memory_utilization 0.9 \
  --enforce-eager \
  --block-size 1

