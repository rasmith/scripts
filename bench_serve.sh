
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

num_prompts=1
model=$1
results_folder=bench_serve
qps=inf

vllm bench serve \
  --backend vllm \
  --model $model \
  --profile \
  --num-prompts $num_prompts \
  --port 8000 \
  --trust-remote-code \
  --save-result \
  --result-dir $results_folder \
  --result-filename bench_serve.json \
  --request-rate "$qps" \
  --max-concurrency 1 \

