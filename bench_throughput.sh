export VLLM_ROCM_USE_AITER=1
export VLLM_LOGGING_LEVEL=DEBUG
export VLLM_RPC_TIMEOUT=1800000
export VLLM_ROCM_USE_AITER_MHA=1

########## For the Accuracy Issue ###########
export VLLM_ROCM_USE_TRITON_ROPE=1
#############################################

export VLLM_TORCH_PROFILER_DIR=prof 

NUM_PROMPTS=10
MODEL=$1

vllm bench throughput --model $MODEL  \
                      --input-len=128 \
                      --output-len=128 \
                      --num-prompts=$NUM_PROMPTS \
                      --tensor_parallel_size=8 \
                      --max_model_len=32768  \
                      --gpu-memory-utilization 0.9 \
                      --enforce-eager \
                      --enable-expert-parallel \
                      --dtype bfloat16
                      #--profile
