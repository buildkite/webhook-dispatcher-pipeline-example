#!/usr/bin/env python3
"""
generate-trigger-steps.py

Reads .buildkite/routes.yml, figures out which downstream pipelines are
affected by the current build's changes, and prints a Buildkite pipeline
YAML document (to stdout) containing a `trigger` step for each affected
pipeline.

Intended usage (see .buildkite/pipeline.yml):

    generate-trigger-steps.py | buildkite-agent pipeline upload

This script is the "engine". The thing you'll actually edit most often
is .buildkite/routes.yml — read that file's comments first.
"""

import fnmatch
import os
import subprocess
import sys

import yaml

REPO_ROOT = subprocess.run(
    ["git", "rev-parse", "--show-toplevel"],
    check=True, capture_output=True, text=True,
).stdout.strip()

ROUTES_FILE = os.path.join(REPO_ROOT, ".buildkite", "routes.yml")


def sh(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def load_routes() -> dict:
    with open(ROUTES_FILE) as f:
        data = yaml.safe_load(f) or {}
    data.setdefault("routes", [])
    data.setdefault("always_trigger", [])
    data.setdefault("full_rebuild_branches", [])
    return data


def changed_files() -> list[str]:
    """
    Return the list of file paths changed in this build.

    - For pull request builds, diff against the PR's base branch.
    - For pushes, diff against the previous commit on the branch. If that
      commit isn't available (e.g. first build on a new branch, shallow
      clone), fall back to the full tree of the current commit so nothing
      is silently skipped.
    """
    pr_base = os.environ.get("BUILDKITE_PULL_REQUEST_BASE_BRANCH")
    commit = os.environ.get("BUILDKITE_COMMIT", "HEAD")

    if pr_base and pr_base != "false":
        base_ref = f"origin/{pr_base}"
        try:
            sh("git", "fetch", "--quiet", "origin", pr_base)
            merge_base = sh("git", "merge-base", base_ref, commit)
            diff = sh("git", "diff", "--name-only", merge_base, commit)
            return [line for line in diff.splitlines() if line]
        except subprocess.CalledProcessError:
            pass  # fall through to previous-commit diff below

    prev_commit = os.environ.get("BUILDKITE_COMMIT") and _previous_commit(commit)
    if prev_commit:
        diff = sh("git", "diff", "--name-only", prev_commit, commit)
        return [line for line in diff.splitlines() if line]

    # Last resort: treat every file in the repo as "changed" so a route
    # match is at least possible instead of silently triggering nothing.
    all_files = sh("git", "ls-tree", "-r", "--name-only", commit)
    return [line for line in all_files.splitlines() if line]


def _previous_commit(commit: str) -> str | None:
    try:
        return sh("git", "rev-parse", f"{commit}^")
    except subprocess.CalledProcessError:
        return None


def current_branch() -> str:
    return os.environ.get("BUILDKITE_BRANCH", "")


def matches_any_prefix(path: str, prefixes: list[str]) -> bool:
    return any(path.startswith(prefix) for prefix in prefixes)


def branch_matches_any(branch: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(branch, pattern) for pattern in patterns)


def determine_pipelines() -> tuple[list[str], str]:
    """Returns (pipeline_slugs, reason) for logging/annotation purposes."""
    config = load_routes()
    branch = current_branch()

    if branch_matches_any(branch, config["full_rebuild_branches"]):
        all_pipelines = sorted({route["pipeline"] for route in config["routes"]})
        pipelines = sorted(set(all_pipelines) | set(config["always_trigger"]))
        return pipelines, f"branch '{branch}' matches a full_rebuild_branches pattern"

    files = changed_files()
    matched = set(config["always_trigger"])
    for route in config["routes"]:
        if any(matches_any_prefix(f, route["paths"]) for f in files):
            matched.add(route["pipeline"])

    reason = f"{len(files)} changed file(s) matched against routes.yml"
    return sorted(matched), reason


def build_pipeline_yaml(pipelines: list[str]) -> dict:
    branch = os.environ.get("BUILDKITE_BRANCH")
    commit = os.environ.get("BUILDKITE_COMMIT")
    message = os.environ.get("BUILDKITE_MESSAGE")

    if not pipelines:
        return {
            "steps": [
                {
                    "label": ":information_source: No downstream pipelines matched",
                    "command": (
                        "echo 'No routes in .buildkite/routes.yml matched the "
                        "changed files for this build. Nothing to trigger.'"
                    ),
                }
            ]
        }

    steps = []
    for slug in pipelines:
        steps.append(
            {
                "trigger": slug,
                "label": f":rocket: Trigger {slug}",
                "async": False,  # set True if the dispatcher shouldn't wait on downstream results
                "build": {
                    "branch": branch,
                    "commit": commit,
                    "message": f"[dispatched] {message}" if message else "[dispatched]",
                    # Forward whatever the downstream pipeline needs to know
                    # about the triggering build. Add more keys as needed.
                    "env": {
                        "DISPATCHED_FROM_BUILD": os.environ.get("BUILDKITE_BUILD_URL", ""),
                    },
                },
            }
        )

    return {"steps": steps}


def main() -> None:
    pipelines, reason = determine_pipelines()
    print(f"# routing decision: {reason}", file=sys.stderr)
    print(f"# pipelines to trigger: {pipelines or '(none)'}", file=sys.stderr)

    pipeline_yaml = build_pipeline_yaml(pipelines)
    yaml.dump(pipeline_yaml, sys.stdout, sort_keys=False, default_flow_style=False)


if __name__ == "__main__":
    main()