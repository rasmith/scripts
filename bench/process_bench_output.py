import json
import os
import numpy as np
import sys
import argparse

bench_keys = [
    'backend', 'num_prompts', 'request_rate', 'burstiness', 'max_concurrency',
    'duration', 'failed', 'total_input_tokens', 'total_output_tokens',
    'request_throughput', 'request_goodput', 'output_throughput',
    'total_token_throughput', 'max_output_tokens_per_s',
    'max_concurrent_requests', 'mean_ttft_ms', 'median_ttft_ms', 'std_tpot_ms',
    'p99_tpot_ms', 'mean_itl_ms', 'median_itl_ms', 'std_itl_ms', 'p99_itl_ms'
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json-file", type=str, default="", required=True)
    parser.add_argument("--input-len", type=int, default=0, required=True)
    parser.add_argument("--output-len", type=int, default=0, required=True)
    parser.add_argument("--model", type=str, default="", required=True)
    parser.add_argument("--tensor-parallelism",
                        type=int,
                        default=0,
                        required=True)
    parser.add_argument("--print-header", action="store_true")
    args = parser.parse_args()
    with open(args.json_file, "r") as f:
        text = f.read()
        info = json.loads(text)
        if args.print_header:
            fields = ["input_len", "output_len", "tp"]
            fields.extend(bench_keys)
            print(",".join(fields))
        values = [
            str(args.input_len),
            str(args.output_len),
            str(args.tensor_parallelism)
        ]
        values.extend([str(info[k]) for k in bench_keys])
        print(",".join(values))


if __name__ == "__main__":
    main()
