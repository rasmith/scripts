import argparse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", type=str, default="", required=True)
    args = parser.parse_args()
    filename = args.file
    with open(filename, "r") as f:
        lines = f.read().splitlines()
        matches = filter(
            lambda i: (lines[i].startswith("FAILED ") or lines[i] == "FAILED"),
            range(len(lines)))
        full_matches = map(
            lambda i: (lines[i] + " " + lines[i + 1]
                       if lines[i] == "FAILED" else lines[i]), matches)
        failures = list(map(lambda m: m.split()[1], full_matches))
        print("-" * 10 + " FAILURES " + "-" * 10)
        for failure in failures:
            print(failure)

        failed_files = sorted(
            list(set(map(lambda f: f.split("::")[1].split("[")[0], failures))))

        print("=" * 50)
        for failed_file in failed_files:
            print(failed_file)


if __name__ == "__main__":
    main()
