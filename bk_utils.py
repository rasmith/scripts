#!/usr/bin/env python3
"""Shared helpers for talking to the Buildkite API."""

import json
import sys
import urllib.error
import urllib.request
from collections.abc import Callable
from typing import Any


def api_get(token: str, url: str, timeout: int = 60) -> bytes:
    req = urllib.request.Request(url,
                                 headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def fetch_build(token: str, org: str, pipeline: str,
                build_num: str) -> dict[str, Any]:
    url = (f"https://api.buildkite.com/v2/organizations/{org}/pipelines/"
           f"{pipeline}/builds/{build_num}")
    try:
        return json.loads(api_get(token, url))
    except urllib.error.HTTPError as e:
        print(f"Error: API returned {e.code} for {url}", file=sys.stderr)
        sys.exit(1)


def fetch_ci_image(token: str, org: str, pipeline: str,
                   build_data: dict[str, Any],
                   matcher: Callable[[str], str | None]) -> str | None:
    """Find the image-building job and run `matcher` over its log.

    `matcher` takes the job log text and returns the image name, or None.
    """
    build_number = build_data.get("number", "")
    is_image_job = lambda n: ("build" in n and "test" in n and "image" in n and
                              "artifact" in n)
    is_amd_image_job = lambda n: "build" in n and "image" in n and "amd" in n
    script_jobs = [
        j for j in build_data.get("jobs", []) if j.get("type") == "script"
    ]
    image_job = next(
        (j
         for j in script_jobs if is_image_job((j.get("name") or "").lower())),
        next((j for j in script_jobs
              if is_amd_image_job((j.get("name") or "").lower())), None))
    if not image_job:
        return None

    url = (f"https://api.buildkite.com/v2/organizations/{org}/pipelines/"
           f"{pipeline}/builds/{build_number}/jobs/{image_job['id']}/log.txt")
    try:
        log_content = api_get(token, url).decode("utf-8", errors="replace")
    except Exception as e:
        print(f"Error fetching job log: {e}", file=sys.stderr)
        return None

    return matcher(log_content)
