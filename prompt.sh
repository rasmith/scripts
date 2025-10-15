#!/usr/bin/env bash

MODEL=$1
PROMPT=$2
echo "model=$MODEL"
echo "prompt=$PROMPT"
curl http://localhost:8000/v1/completions \
    -H "Content-Type: application/json" \
    -d "{ 
        \"model\": \"$MODEL\",
        \"prompt\": \"$PROMPT\",
        \"max_tokens\": 7,
        \"temperature\": 0
    }"
