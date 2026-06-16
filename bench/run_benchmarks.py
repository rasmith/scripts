import argparse
import json
import os
import subprocess
import sys
import time
import typing
from typing import Optional
import itertools
import psutil
import time
import _io
import uuid
from dataclasses import dataclass

bench_keys = [
    'backend', 'num_prompts', 'request_rate', 'burstiness', 'max_concurrency',
    'duration', 'failed', 'total_input_tokens', 'total_output_tokens',
    'request_throughput', 'request_goodput', 'output_throughput',
    'total_token_throughput', 'max_output_tokens_per_s',
    'max_concurrent_requests', 'mean_ttft_ms', 'median_ttft_ms', 'std_tpot_ms',
    'p99_tpot_ms', 'mean_itl_ms', 'median_itl_ms', 'std_itl_ms', 'p99_itl_ms'
]


@dataclass
class BenchmarkResult:
    model: str
    num_gpus: int
    batch_size: int
    input_len: int
    output_len: int
    command: str = None
    measurements: dict = None


def run_and_check(*args, **kwargs) -> subprocess.CompletedProcess:
    kwargs["check"] = True
    try:
        return subprocess.run(*args, **kwargs)
    except subprocess.CalledProcessError as cpe:
        print(f"cpe={cpe}")
        print(f"cpe.cmd={cpe.cmd}")
        print(f"cpe.output={cpe.output}")
        print(f"cpe.stdout={cpe.stdout}")
        print(f"cpe.stderr={cpe.stderr}")
        raise cpe

def popen_and_check(*args, **kwargs) -> subprocess.Popen:
    try:
        return subprocess.Popen(*args, **kwargs)
    except subprocess.SubprocessError as spe:
        print(f"spe={spe}")
        print(f"spe.cmd={spe.cmd}")
        print(f"spe.output={spe.output}")
        print(f"spe.stdout={spe.stdout}")
        print(f"spe.stderr={spe.stderr}")
        raise spe

def print_cmd(cmd: list[str]) -> None:
    text_cmd = " ".join(cmd)
    print(f"CMD:{text_cmd}")


def run_cmd(cmd: list[str], log_file, dry_run) -> subprocess.Popen:
    print_cmd(cmd)
    if dry_run:
        return
    return subprocess.Popen(cmd, stdout=log_file, stderr=log_file)


def run_vllm_serve(
    model: str,
    num_gpus: int,
    input_len: int,
    output_len: int,
    port: int,
    profile: bool,
    profile_output_dir: str,
    dry_run: bool,
    vllm_serve_log_handle: str,
    benchmark_result: BenchmarkResult,
) -> Optional[subprocess.Popen]:
    cmd = [
        "vllm", "serve", model, "--trust-remote-code", "-tp",
        str(num_gpus), "--port",
        str(port)
    ]
    benchmark_result.command = " ".join(cmd)
    if num_gpus == 8:
        cmd += ["--enable-expert-parallel"]
    if profile:
        cmd += [
            "--profiler-config.profiler",
            "torch",
            "--profiler-config.torch_profiler_dir",
            profile_output_dir,
        ]
    return run_cmd(cmd, vllm_serve_log_handle, dry_run)


def run_vllm_bench_serve(
    model: str,
    batch_size: int,
    input_len: int,
    output_len: int,
    server_wait_time: int,
    port: int,
    bench_json_file: str,
    profile: bool,
    dry_run: bool,
    vllm_bench_serve_log: str,
    benchmark_result: BenchmarkResult,
) -> Optional[subprocess.Popen]:
    num_prompts = batch_size * 10
    max_concurrency = batch_size
    cmd = [
        "vllm", "bench", "serve", "--model", model, "--trust-remote-code",
        "--num-prompts",
        str(num_prompts), "--max-concurrency",
        str(max_concurrency), "--input-len",
        str(input_len), "--output-len",
        str(output_len), "--ready-check-timeout-sec",
        str(server_wait_time), "--save-result", "--save-detailed", "--port",
        str(port), "--result-filename", bench_json_file
    ]
    benchmark_result.command = " ".join(cmd)
    if profile:
        cmd += ["--profile"]
    return run_cmd(cmd, vllm_bench_serve_log, dry_run)


def process_bench_output(
    model: str,
    bench_json_file: str,
    input_len: int,
    output_len: int,
    num_gpus: int,
    print_header: bool,
    dry_run: bool,
    output_file: _io.TextIOWrapper,
    benchmark_result: BenchmarkResult,
    benchmark_results: list[BenchmarkResult],
) -> None:

    with open(bench_json_file, "r") as f:
        text = f.read()
        info = json.loads(text)

        # Append this benchmark to the rest of the results.
        benchmark_result.measurements = {k: info[k] for k in bench_keys}
        benchmark_results.append(benchmark_result)

        # Write to CSV and print to stdout.
        if print_header:
            fields = ["input_len", "output_len", "tp"]
            fields.extend(bench_keys)
            print(",".join(fields))
            if output_file:
                print(",".join(fields), file=output_file)

        values = [str(input_len), str(output_len), str(num_gpus)]
        values.extend([str(info[k]) for k in bench_keys])

        if output_file:
            print(",".join(values), file=output_file)

        print(",".join(values))


def kill_process_tree(pid: int):
    try:
        parent = psutil.Process(pid)
        for child in parent.children(recursive=True):
            child.kill()
        parent.kill()
    except psutil.NoSuchProcess:
        pass


def run_benchmark(
    model: str,
    num_gpus: int,
    batch_size: int,
    input_len: int,
    output_len: int,
    server_wait_time: int,
    profile: bool,
    profile_output_dir: dir,
    port: int,
    bench_json_file: str,
    vllm_serve_log: str,
    vllm_bench_serve_log: str,
    dry_run: int,
    benchmark_result: BenchmarkResult,
) -> None:
    vllm_serve_log_handle = open(vllm_serve_log, "w")
    vllm_serve_process = run_vllm_serve(model, num_gpus, input_len, output_len,
                                        port, profile, profile_output_dir,
                                        dry_run, vllm_serve_log_handle,
                                        benchmark_result)
    vllm_bench_serve_log_handle = open(vllm_bench_serve_log, "w")
    vllm_bench_serve_process = run_vllm_bench_serve(
        model, batch_size, input_len, output_len, server_wait_time, port,
        bench_json_file, profile, dry_run, vllm_bench_serve_log_handle,
        benchmark_result)
    if not dry_run:
        vllm_bench_serve_process.communicate()
        kill_process_tree(vllm_bench_serve_process.pid)
        kill_process_tree(vllm_serve_process.pid)
        vllm_serve_log_handle.close()
        vllm_bench_serve_log_handle.close()


def run_benchmarks(
    model: str,
    num_gpus_list: list[int],
    batch_sizes: list[int],
    input_lens: list[int],
    output_lens: list[int],
    server_wait_time: int,
    port: int,
    bench_json_file: str,
    profile: bool,
    profile_output_dir: str,
    dry_run: bool,
    vllm_serve_log: str,
    vllm_bench_serve_log: str,
    output_file: _io.TextIOWrapper,
    output_json: str,
) -> None:
    first_time = True
    bench_params = itertools.product(num_gpus_list, batch_sizes, input_lens,
                                     output_lens)
    benchmark_results = []
    for num_gpus, batch_size, input_len, output_len in bench_params:
        print("=" * 50)
        print(
            f"num_gpus={num_gpus}, BS={batch_size}, ISL={input_len}, OSL={output_len}"
        )
        benchmark_result = BenchmarkResult(model, num_gpus, batch_size,
                                           input_len, output_len)
        run_benchmark(model, num_gpus, batch_size, input_len, output_len,
                      server_wait_time, profile, profile_output_dir, port,
                      bench_json_file, vllm_serve_log, vllm_bench_serve_log,
                      dry_run, benchmark_result)

        if not dry_run:
            process_bench_output(model, bench_json_file, input_len, output_len,
                                 num_gpus, first_time, dry_run, output_file,
                                 benchmark_result, benchmark_results)
            with open(output_json, "w") as f:
                obj = {k: v for k, v in benchmark_result.__dict__.items()}
                print(json.dumps(obj), file=f)
            time.sleep(10)
        first_time = False


def do_benchmarks(benchmark_config_file: str, dry_run: bool):
    with open(benchmark_config_file, "r") as f:
        config = json.load(f)
    vllm_serve_log = config["vllm_serve_log"]
    vllm_bench_serve_log = config["vllm_bench_serve_log"]
    server_wait_time = config["server_wait_time"]
    port = config["port"]
    profile = config["profile"]
    profile_output_dir = config["profile_output_dir"]
    model = config["model"]
    input_lens = config["input_lens"]
    output_lens = config["output_lens"]
    num_gpus_list = config["num_gpus"]
    batch_sizes = config["batch_sizes"]
    bench_json_file = config["bench_json_file"]
    output_csv = config.get("output_csv")
    output_json = config.get("output_json")
    output_file_handle = open(output_csv, "w") if output_csv else None
    try:
        run_benchmarks(model, num_gpus_list, batch_sizes, input_lens,
                       output_lens, server_wait_time, port, bench_json_file,
                       profile, profile_output_dir, dry_run, vllm_serve_log,
                       vllm_bench_serve_log, output_file_handle, output_json)
    finally:
        if output_file_handle:
            output_file_handle.close()


def maybe_pull_docker_image(image: str) -> bool:
    result = subprocess.run(["docker", "image", "inspect", image],
                            capture_output=True)
    already_present = result.returncode == 0
    if not already_present:
        print(f"Pulling image {image}...")
        run_and_check(["docker", "pull", image])
    else:
        print(f"Image {image} already present.")
    return already_present


def run_docker_container(image: str,
                         hf_token: str,
                         bench_dir: str,
                         model_dir: str = None) -> str:

    container_name = str(uuid.uuid4())
    bench_dir_path = os.path.expanduser(bench_dir) if bench_dir.startswith(
        "~") else bench_dir_path
    bench_dir_path = os.path.abspath(bench_dir_path)
    volumes = [
        "-v",
        "/var/run/docker.sock:/var/run/docker.sock",
        "-v",
        f"{bench_dir_path}:/bench",
    ]
    if model_dir:
        volumes += ["-v", f"{model_dir}:/models"]
    cmd = [
        "docker",
        "run",
        "-it",
        "-d",
        "-e",
        f"HF_TOKEN={hf_token}",
        "--device=/dev/dri",
        "--shm-size=64G",
        "--cap-add=SYS_PTRACE",
        "--network",
        "host",
        "--security-opt",
        "seccomp=unconfined",
        "--privileged",
        "--ulimit",
        "core=0:0",
    ] + volumes + [
        "--entrypoint",
        "/bin/bash",
        "--name",
        f"{container_name}",
        f"{image}",
    ]
    cmd_out = " ".join(cmd)
    print(f"cmd:{cmd_out}")
    result = run_and_check(cmd, capture_output=True, text=True)
    container_id = result.stdout.strip()
    print(f"Launched container {container_id[:12]} from {image}")
    return container_id


def run_benchmark_in_docker_container(container: str,
                                      benchmark_config: str) -> str:
    script_path = os.path.abspath(__file__)
    config_path = os.path.abspath(os.path.expanduser(benchmark_config))
    run_and_check(
        ["docker", "cp", script_path, f"{container}:/run_benchmarks.py"])
    run_and_check(
        ["docker", "cp", config_path, f"{container}:/benchmark_config.json"])
    process = popen_and_check([
        "docker", "exec", container, "python", "/run_benchmarks.py",
        "benchmark", "--benchmark-config", "/benchmark_config.json"
    ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1
        )
    while True:
        line = process.stdout.readline()
        if not line:
            break
        print(line)
    process.wait()
                           # capture_output=True,
                           # text=True)
    # print(result.stdout)
    return process.stdout


def remove_docker_container(container: str) -> None:
    print(f"Removing container {container[:12]}...")
    run_and_check(["docker", "rm", "-f", container])


def remove_docker_image(image: str) -> None:
    print(f"Removing image {image}...")
    run_and_check(["docker", "rmi", image])


def do_docker_runs(hf_token: str, bench_dir: str, model_dir: str,
                   images: list[str], benchmark_config: str):
    for image in images:
        already_present = maybe_pull_docker_image(image)
        container = None
        try:
            container = run_docker_container(image, hf_token, bench_dir,
                                             model_dir)
            run_benchmark_in_docker_container(container, benchmark_config)
        except subprocess.CalledProcessError as cpe:
            raise cpe
        finally:
            if not already_present:
                remove_docker_image(image)
            if container is not None:
                remove_docker_container(container)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", default="benchmark")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--benchmark-config",
                        required=False,
                        default="benchmark_config.json")
    parser.add_argument("--docker-config",
                        required=False,
                        default="docker_config.json")
    args = parser.parse_args()
    print(f"command={args.command}")
    if not args.command:
        command = "benchmark"
    if args.command not in ["benchmark", "docker"]:
        print(f"Command must be one of 'benchmark' or 'run'.")
    if args.command == "benchmark":
        do_benchmarks(args.benchmark_config, args.dry_run)
    elif args.command == "docker":
        with open(args.docker_config, "r") as f:
            docker_config = json.load(f)
        hf_token = docker_config.get("hf_token")
        if not hf_token:
            parser.error("hf_token must be set in docker config")
        bench_dir = docker_config.get("bench_dir") or os.getcwd()
        model_dir = docker_config.get("model_dir") or None
        images = docker_config.get("images", [])
        do_docker_runs(hf_token, bench_dir, model_dir, images,
                       args.benchmark_config)


if __name__ == "__main__":
    main()
