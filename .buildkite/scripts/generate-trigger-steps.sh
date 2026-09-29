#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTES_FILE="${SCRIPT_DIR}/../routes.conf"

DEFAULT_BRANCH="${BUILDKITE_PIPELINE_DEFAULT_BRANCH:-main}"
BASE_BRANCH="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-${DEFAULT_BRANCH}}"
CURRENT_BRANCH="${BUILDKITE_BRANCH:-${DEFAULT_BRANCH}}"

# Escape a value for use inside a double-quoted YAML string.
# Also doubles "$" so buildkite-agent pipeline upload doesn't interpolate it.
yaml_dq_escape() {
  local s=$1
  s=${s//\\/\\\\}    # backslashes first
  s=${s//\"/\\\"}    # double quotes
  s=${s//$'\r'/}     # drop carriage returns
  s=${s//$'\n'/\\n}  # newlines (multi-line commit messages)
  s=${s//$'\t'/\\t}  # tabs
  s=${s//\$/\$\$}    # Buildkite interpolation
  printf '%s' "$s"
}

MESSAGE_ESCAPED="$(yaml_dq_escape "${BUILDKITE_MESSAGE:-}")"

if [[ -n "${BUILDKITE_PULL_REQUEST:-}" && "${BUILDKITE_PULL_REQUEST}" != "false" ]]; then
  git fetch --quiet origin "${BASE_BRANCH}" || true
  DIFF_RANGE="origin/${BASE_BRANCH}...HEAD"
elif [[ "${CURRENT_BRANCH}" == "${DEFAULT_BRANCH}" ]]; then
  DIFF_RANGE="HEAD~1..HEAD"
else
  git fetch --quiet origin "${DEFAULT_BRANCH}" || true
  DIFF_RANGE="origin/${DEFAULT_BRANCH}...HEAD"
fi

CHANGED_FILES="$(git diff --name-only "${DIFF_RANGE}" 2>/dev/null || true)"

if [[ -z "${CHANGED_FILES}" ]]; then
  echo "# warning: could not determine changed files (range: ${DIFF_RANGE}); triggering all downstream pipelines" >&2
fi

echo "steps:"
triggered_any=false

# "|| [[ -n ... ]]" processes a final line even if routes.conf has no trailing newline.
while IFS=':' read -r watched_path pipeline_slug || [[ -n "${watched_path}" ]]; do
  [[ -z "${watched_path}" || "${watched_path}" =~ ^# ]] && continue
  pipeline_slug="${pipeline_slug%$'\r'}"   # tolerate CRLF line endings

  should_trigger=false
  if [[ -z "${CHANGED_FILES}" ]]; then
    should_trigger=true
  elif echo "${CHANGED_FILES}" | grep -qE "^${watched_path}/"; then
    should_trigger=true
  fi

  if [[ "${should_trigger}" == true ]]; then
    triggered_any=true
    cat <<STEP
  - trigger: "${pipeline_slug}"
    label: ":rocket: Trigger ${pipeline_slug} Pipeline"
    build:
      message: "${MESSAGE_ESCAPED}"
      commit: "${BUILDKITE_COMMIT:-HEAD}"
      branch: "${CURRENT_BRANCH}"
      env:
        DISPATCHED_FROM_BUILD: "${BUILDKITE_BUILD_URL:-unknown}"
    async: false
STEP
  fi
done < "${ROUTES_FILE}"

if [[ "${triggered_any}" == false ]]; then
  cat <<STEP
  - label: ":information_source: No downstream pipelines affected"
    command: echo "No changes under any watched path in ${DIFF_RANGE} — nothing to trigger."
STEP
fi
