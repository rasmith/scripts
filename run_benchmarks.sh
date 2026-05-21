#!/usr/bin/env bash

INPUT_LENS=(128 1024)
OUTPUT_LENS=(128 1024)
NUM_GPUS=(2 4 8)
MODEL=/models/MiniMax-M2.5/
NUM_PROMPTS=100
DRY_RUN=1
BENCH_OUTPUT_FILE=bench_output.txt
BENCH_JSON_FILE=bench_output.json
PYTHON=$(which python)
PROCESS_BENCH_OUTPUT_SCRIPT=process_bench_output.py
FIRST_TIME=1
VLLM_SERVE_LOG=vllm_serve.log
RESULTS_FILE=results.csv
SERVER_WAIT_TIME=3600
PORT=8010
PROFILE=0

if [[ "$PROFILE"  == "1" ]]; then
  INPUT_LENS=(1024)
  OUTPUT_LENS=(1024)
  NUM_GPUS=(2)
fi

echo "======== Benchmark Results =========" > $RESULTS_FILE

for NUM_GPU in "${NUM_GPUS[@]}"
do
  for INPUT_LEN in "${INPUT_LENS[@]}"
  do
    for OUTPUT_LEN in "${OUTPUT_LENS[@]}"
    do
      # Start vllm server.
      EXTRA_VLLM_SERVE_FLAGS=
      if [[ "$NUM_GPU" == "8" ]]; then
        EXTRA_VLLM_SERVE_FLAGS="${EXTRA_VLLM_SERVE_FLAGS} --enable-expert-parallel"
      fi
      if [[ "$PROFILE" == "1" ]]; then
        EXTRA_VLLM_SERVE_FLAGS="${EXTRA_VLLM_SERVE_FLAGS} --profiler-config.profiler=torch"
        EXTRA_VLLM_SERVE_FLAGS="${EXTRA_VLLM_SERVE_FLAGS} --profiler-config.torch_profiler_dir=prof"
      fi
      VLLM_SERVE_CMD="vllm serve $MODEL \
                 --trust-remote-code -tp $NUM_GPU \
                 --port $PORT \
                 $EXTRA_VLLM_SERVE_FLAGS"  
      echo "Running with ISL=$INPUT_LEN, OSL=$OUTPUT_LEN, TP=$NUM_GPU"
      if [[ "$DRY_RUN" == "1" ]]; then
        echo "$VLLM_SERVE_CMD"
      else 
        $VLLM_SERVE_CMD 2>&1 > $VLLM_SERVE_LOG &
      fi
      # Perform the benchmark.
      EXTRA_BENCH_SERVE_FLAGS=
      if [[ "$PROFILE" == "1" ]]; then
        EXTRA_BENCH_SERVE_FLAGS="$EXTRA_BENCH_SERVE_FLAGS --profile"
      fi
      VLLM_BENCH_SERVE_CMD="vllm bench serve --model $MODEL  \
                                             --trust-remote-code \
                                             --num-prompts $NUM_PROMPTS \
                                             --input-len $INPUT_LEN \
                                             --output-len $OUTPUT_LEN \
                                             --ready-check-timeout-sec $SERVER_WAIT_TIME \
                                             --save-result \
                                             --save-detailed \
                                             --port $PORT \
                                             --result-filename $BENCH_JSON_FILE \
                                             $EXTRA_BENCH_SERVE_FLAGS"

      if [[ "$DRY_RUN" == "1" ]]; then
        echo "$VLLM_BENCH_SERVE_CMD"
        TEST_OUTPUT_COMMAND="cat bench_output.txt"
        TEST_OUTPUT=$(${TEST_OUTPUT_COMMAND})
      else
        $VLLM_BENCH_SERVE_CMD 2>&1 > $BENCH_OUTPUT_FILE
      fi
      # Process benchmark results and append to CSV.
      PRINT_HEADER_FLAG=
      if [[ "$FIRST_TIME" == "1" ]]; then
        PRINT_HEADER_FLAG="--print-header"
        FIRST_TIME=0
      fi
      PROCESS_OUTPUT_COMMAND="$PYTHON $PROCESS_BENCH_OUTPUT_SCRIPT \
                              --json-file $BENCH_JSON_FILE\
                              --model $MODEL \
                              --input-len $INPUT_LEN \
                              --output-len $OUTPUT_LEN \
                              --tensor-parallelism $NUM_GPU \
                              $PRINT_HEADER_FLAG"
      if [[ "$DRY_RUN" == "1" ]]; then
        echo $PROCESS_OUTPUT_COMMAND
      else
        $PROCESS_OUTPUT_COMMAND >> $RESULTS_FILE
      fi
      # Kill all vLLM jobs.
      if [[ "$DRY_RUN" == "0" ]]; then
        ps -a | grep -i vllm | awk '{print $1}' | xargs -I % kill -9 %
      fi
      sleep 10
    done
  done
done


