#!/usr/bin/env python3
"""Sync config files to reserved GitHub environments for the dispatch menu."""

import json
import os
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request


PREFIX = "config-file--"
API_VERSION = "2022-11-28"
repo = os.environ["GITHUB_REPOSITORY"]
token = os.environ["CONFIG_SYNC_TOKEN"]
api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")

if not token:
    raise SystemExit("Set the repository Actions secret CONFIG_SYNC_TOKEN first.")


def git(*args):
    return subprocess.check_output(["git", *args], text=True).splitlines()


def config_filenames():
    refs = git("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin")
    refs = [ref for ref in refs if ref != "origin/HEAD"]
    refs.append("HEAD")

    filenames = set()
    for ref in refs:
        for path in git("ls-tree", "-r", "--name-only", ref, "--", "configs"):
            match = re.fullmatch(r"configs/([A-Za-z0-9._-]+\.(?:yaml|yml))", path)
            if match:
                filenames.add(match.group(1))
    return filenames


def request(method, path):
    req = urllib.request.Request(
        f"{api_url}{path}",
        data=b"{}" if method == "PUT" else None,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": API_VERSION,
            "Content-Type": "application/json",
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req) as response:
            return json.load(response) if response.status != 204 else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise SystemExit(f"GitHub API {method} {path} failed: {error.code} {detail}")


def all_environments():
    result = []
    page = 1
    while True:
        data = request(
            "GET",
            f"/repos/{repo}/environments?per_page=100&page={page}",
        )
        batch = data.get("environments", [])
        result.extend(item["name"] for item in batch)
        if len(batch) < 100:
            return result
        page += 1


filenames = config_filenames()
desired = {f"{PREFIX}{filename}" for filename in filenames}
current = {name for name in all_environments() if name.startswith(PREFIX)}

for name in sorted(desired - current):
    request("PUT", f"/repos/{repo}/environments/{urllib.parse.quote(name, safe='')}")
    print(f"Added config dropdown entry: {name}")

for name in sorted(current - desired):
    request("DELETE", f"/repos/{repo}/environments/{urllib.parse.quote(name, safe='')}")
    print(f"Removed stale config dropdown entry: {name}")

if desired == current:
    print(f"Config dropdown is up to date with {len(desired)} file(s).")
