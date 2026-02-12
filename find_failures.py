import argparse
import numpy as np

SHORT_TEST_SUMMARY_INFO_LINE = "=========================== short test summary info ============================"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", type=str, default="", required=True)
    args = parser.parse_args()
    filename = args.file
    failures = []
    with open(filename, "r") as f:
        lines = f.read().splitlines()
        numpy_lines = np.array(lines)
        summary_info_line_locations = np.where(
            numpy_lines == SHORT_TEST_SUMMARY_INFO_LINE)[0]
        for location in summary_info_line_locations:
            i = location + 1
            while lines[i].startswith("FAILED"):
                failures.append(lines[i])
                i = i + 1
        print("-" * 10 + " FAILURES " + "-" * 10)
        failures = sorted(failures)
        for failure in failures:
            print(failure)
    files = sorted(
        list(set((map(lambda x: x.split()[1].split("::")[0], failures)))))
    print("-" * 10 + " FILES " + "-" * 10)
    for f in files:
        print(f)


if __name__ == "__main__":
    main()
